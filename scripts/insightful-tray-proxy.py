#!/usr/bin/env python3
"""
Proxy system tray icon for the Insightful (Workpuls) agent.

WHY THIS EXISTS
---------------
The agent registers an Ayatana StatusNotifierItem ("workpuls-agent1") that does
NOT implement the Activate method:

    $ dbus-send ... org.kde.StatusNotifierItem.Activate
    Error org.freedesktop.DBus.Error.UnknownMethod: No such method "Activate"

Per the StatusNotifierItem spec a host calls Activate on left-click. Plasma does,
gets UnknownMethod, and nothing happens -- which is why left-clicking the agent's
own icon appears dead. No configuration can fix that; the method is simply absent.

This proxy registers its own tray icon (Qt implements Activate properly) and
forwards every action to the real item's DBusMenu, so no behaviour is
reimplemented: left-click triggers the agent's own "Show Insightful" entry, and
the context menu mirrors whatever the agent currently offers. The agent's own
icon is hidden via Plasma's hiddenItems so only one icon is visible.

IMPLEMENTATION NOTES
--------------------
* python-dbus has no dbus.Variant type. Variants are ordinary values carrying
  variant_level=1, e.g. dbus.String("", variant_level=1). Using a non-existent
  dbus.Variant raises AttributeError, and PyQt6 converts any unhandled exception
  inside a slot into an abort() -- the process dies with SIGABRT rather than
  printing a traceback. Every slot below is therefore wrapped.
* The agent's bus name and menu item ids both change when it restarts, so they
  are re-resolved on every use and never cached.
* Qt registers the icon with the tray once, on show(), and never retries. At
  login this proxy can start before Plasma's tray (StatusNotifierWatcher) is up
  -- Plasma 6 launches autostart entries through systemd and ignores
  X-KDE-autostart-after=panel -- and the icon then silently never appears. So a
  timer keeps checking that our icon is actually registered, and re-shows it if
  it is not (tray started late, or plasmashell restarted).
* The icon mirrors the agent: it is shown only while the agent's own tray item
  exists, and hidden when the agent quits. A visible icon therefore always means
  Insightful is running. (In "personal" mode the agent's red close button quits
  the whole app -- its HeaderComponent.close() calls Broker "exit" -- and an icon
  that lingered after that looked like "close sends it to the tray".)
* There is no "Quit tray icon" entry: once the agent quit, it was the only
  clickable entry left and was easy to hit by accident. The proxy has nothing to
  show when the agent is gone, so it simply hides.
* The menu is rebuilt right before it opens (aboutToShow), so its entries never
  point at an agent instance that has already quit.
"""

import os
import sys
import traceback
from pathlib import Path

import dbus
from PyQt6.QtWidgets import QApplication, QSystemTrayIcon, QMenu
from PyQt6.QtGui import QIcon, QAction
from PyQt6.QtCore import QTimer

WATCHER_NAME = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
SNI_IFACE = "org.kde.StatusNotifierItem"
MENU_IFACE = "com.canonical.dbusmenu"
ICON_PATH = str(Path.home() / ".local/share/icons/hicolor/512x512/apps/insightful.png")

# Left-click triggers the first menu entry whose label starts with one of these.
SHOW_LABELS = ("show insightful", "show", "open insightful")


def guard(func):
    """Never let an exception escape into Qt: PyQt6 aborts the process."""
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            sys.stderr.flush()
            return None
    return wrapper


def find_agent_item(bus):
    """Locate the agent's StatusNotifierItem. Its bus name changes every time the
    agent restarts, so this must be re-resolved rather than cached."""
    try:
        watcher = bus.get_object(WATCHER_NAME, WATCHER_PATH)
        props = dbus.Interface(watcher, "org.freedesktop.DBus.Properties")
        items = props.Get(WATCHER_NAME, "RegisteredStatusNotifierItems")
    except Exception:
        return None, None

    for entry in items:
        text = str(entry)
        if "workpuls" not in text.lower():
            continue
        if "/" in text:
            name, path = text.split("/", 1)
            return name, "/" + path
        return text, "/StatusNotifierItem"
    return None, None


def menu_path(bus, name, path):
    try:
        obj = bus.get_object(name, path)
        props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
        return str(props.Get(SNI_IFACE, "Menu"))
    except Exception:
        return None


def read_menu(bus, name, path):
    """Return [(id, label, enabled), ...] for the agent's top-level menu."""
    try:
        obj = bus.get_object(name, path)
        menu = dbus.Interface(obj, MENU_IFACE)
        _revision, layout = menu.GetLayout(0, -1, dbus.Array([], signature="s"))
    except Exception:
        return []

    entries = []
    for child in layout[2]:
        try:
            item_id = int(child[0])
            props = child[1]
            label = str(props.get("label", "")).replace("_", "")
            if not label:
                continue
            entries.append((item_id, label, bool(props.get("enabled", True))))
        except Exception:
            continue
    return entries


def click_menu_item(bus, name, path, item_id):
    try:
        obj = bus.get_object(name, path)
        menu = dbus.Interface(obj, MENU_IFACE)
        # NOT dbus.Variant -- that type does not exist in python-dbus.
        menu.Event(item_id, "clicked", dbus.String("", variant_level=1),
                   dbus.UInt32(0))
        return True
    except Exception:
        traceback.print_exc(file=sys.stderr)
        return False


class ProxyTray:
    def __init__(self, app):
        self.app = app
        self.bus = dbus.SessionBus()
        self.tray = QSystemTrayIcon(QIcon(ICON_PATH))
        self.tray.setToolTip("Insightful")
        self.menu = QMenu()
        self.tray.setContextMenu(self.menu)
        self.menu.aboutToShow.connect(self.rebuild_menu)
        self.tray.activated.connect(self.on_activated)

        self.rebuild_menu()
        self.sync()

        # Show/hide with the agent, and re-register if the tray was not up yet
        # or restarts later.
        self.sync_timer = QTimer()
        self.sync_timer.timeout.connect(self.sync)
        self.sync_timer.start(3000)

        # The agent's menu is dynamic ("Start break (Time left: ...)") and its
        # bus name changes across agent restarts, so refresh periodically.
        self.timer = QTimer()
        self.timer.timeout.connect(self.rebuild_menu)
        self.timer.start(15000)

    def icon_registered(self):
        watcher = self.bus.get_object(WATCHER_NAME, WATCHER_PATH)
        props = dbus.Interface(watcher, "org.freedesktop.DBus.Properties")
        items = props.Get(WATCHER_NAME, "RegisteredStatusNotifierItems")
        bus_iface = dbus.Interface(
            self.bus.get_object("org.freedesktop.DBus", "/org/freedesktop/DBus"),
            "org.freedesktop.DBus")
        for item in items:
            name = str(item).split("/", 1)[0]
            try:
                if int(bus_iface.GetConnectionUnixProcessID(name)) == os.getpid():
                    return True
            except dbus.DBusException:
                continue
        return False

    @guard
    def sync(self):
        agent_running = find_agent_item(self.bus)[0] is not None
        if not agent_running:
            if self.tray.isVisible():
                self.tray.hide()
            return
        if not self.bus.name_has_owner(WATCHER_NAME):
            return  # tray not up yet; check again on the next tick
        if not self.tray.isVisible() or not self.icon_registered():
            self.tray.hide()
            self.tray.show()

    def agent_menu(self):
        name, path = find_agent_item(self.bus)
        if not name:
            return None, None, []
        mpath = menu_path(self.bus, name, path)
        if not mpath:
            return None, None, []
        return name, mpath, read_menu(self.bus, name, mpath)

    @guard
    def rebuild_menu(self):
        name, mpath, entries = self.agent_menu()
        self.menu.clear()

        if not entries:
            unavailable = QAction("Insightful is not running", self.menu)
            unavailable.setEnabled(False)
            self.menu.addAction(unavailable)
        else:
            for item_id, label, enabled in entries:
                action = QAction(label, self.menu)
                action.setEnabled(enabled)
                action.triggered.connect(self.make_handler(name, mpath, item_id))
                self.menu.addAction(action)


    def make_handler(self, name, mpath, item_id):
        @guard
        def handler(_checked=False):
            click_menu_item(self.bus, name, mpath, item_id)
        return handler

    @guard
    def on_activated(self, reason):
        """Left-click -> trigger the agent's own 'Show Insightful' entry."""
        if reason not in (QSystemTrayIcon.ActivationReason.Trigger,
                          QSystemTrayIcon.ActivationReason.DoubleClick):
            return
        name, mpath, entries = self.agent_menu()
        if not entries:
            return
        for wanted in SHOW_LABELS:
            for item_id, label, _enabled in entries:
                if label.lower().startswith(wanted):
                    click_menu_item(self.bus, name, mpath, item_id)
                    return
        click_menu_item(self.bus, name, mpath, entries[0][0])


def main():
    # Belt and braces: PyQt6 aborts on unhandled exceptions, so log instead.
    sys.excepthook = lambda *exc: traceback.print_exception(*exc, file=sys.stderr)

    app = QApplication(sys.argv)
    app.setApplicationName("Insightful")
    app.setDesktopFileName("insightful")
    app.setQuitOnLastWindowClosed(False)
    ProxyTray(app)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
