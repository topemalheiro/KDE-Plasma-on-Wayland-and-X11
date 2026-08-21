#!/usr/bin/env python3
"""Keep each USB touchscreen bound to its own output on KDE Plasma 6 / Wayland.

Why this exists
---------------
KWin keys libinput device configuration on (vendor, product, name) only --
see Connection::applyDeviceConfig in kwin/src/backends/libinput/connection.cpp:

    device->setConfig(m_config->group("Libinput")
        .group(QString::number(device->vendor()))
        .group(QString::number(device->product()))
        .group(device->name()));

Two identical SiS controllers (0457:0819, same product string, no serial)
therefore collapse into a single group in ~/.config/kcminputrc, and both get
handed the same OutputUuid every time a device is added.

The monitors' built-in USB hubs power-cycle when the displays sleep, so the
controllers re-enumerate dozens of times a session. Each time, KWin re-creates
the device and applies that one shared mapping, sending one panel's touches to
the other panel's screen. There is no config-only fix: the evdev name is the
kernel's and cannot be overridden by udev or hwdb, and the devices carry no
serial to key on.

So this daemon re-asserts the correct outputName over D-Bus whenever KWin
(re-)adds a touch device, matching devices on persistent USB topology instead.

It never writes kcminputrc. KWin does that itself inside setOutputName(); the
resulting last-writer-wins churn in the shared group is expected and harmless.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import logging
import os
import signal
import subprocess
import sys
from pathlib import Path

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

BUS_NAME = "org.kde.KWin"
MANAGER_PATH = "/org/kde/KWin/InputDevice"
MANAGER_IFACE = "org.kde.KWin.InputDeviceManager"
DEVICE_PATH = "/org/kde/KWin/InputDevice/{}"
DEVICE_IFACE = "org.kde.KWin.InputDevice"
PROPS_IFACE = "org.freedesktop.DBus.Properties"

DEFAULT_CONFIG = (
    Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    / "touchscreen-mapping"
    / "mapping.json"
)

log = logging.getLogger("touchscreen-mapping")


# --------------------------------------------------------------------- config


class Config:
    """The USB-path -> output table, plus tunables."""

    def __init__(self, path: Path):
        self.path = path
        self.settle_ms = 300
        self.udev_retries = 5
        self.udev_retry_ms = 100
        self.reconcile_interval_s = 900
        self.panels: list[dict] = []
        self.load()

    def load(self) -> None:
        try:
            with open(self.path) as handle:
                data = json.load(handle)
        except FileNotFoundError:
            log.error("no config at %s -- nothing will be mapped", self.path)
            self.panels = []
            return
        except (OSError, ValueError) as exc:
            log.error("could not read %s: %s -- keeping previous config", self.path, exc)
            return

        opts = data.get("options") or {}
        for key in ("settle_ms", "udev_retries", "udev_retry_ms", "reconcile_interval_s"):
            if key in opts:
                try:
                    setattr(self, key, int(opts[key]))
                except (TypeError, ValueError):
                    log.error("bad options.%s in %s; keeping %s", key, self.path, getattr(self, key))

        panels = []
        for entry in data.get("panels") or []:
            output = str(entry.get("output") or "").strip()
            if not output:
                log.error("panel entry without 'output' in %s; ignoring: %r", self.path, entry)
                continue
            panels.append(
                {
                    "label": str(entry.get("label") or "").strip(),
                    "output": output,
                    "usb_path": str(entry.get("usb_path") or "").strip(),
                    "usb_port": str(entry.get("usb_port") or "").strip(),
                    "usb_revision": str(entry.get("usb_revision") or "").strip(),
                    "edid_hash": str(entry.get("edid_hash") or "").strip().lower(),
                }
            )
        self.panels = panels

        # The revision fallback is only trustworthy when it actually
        # distinguishes the panels; two panels sharing one would mis-map.
        seen: dict[str, int] = {}
        for panel in panels:
            if panel["usb_revision"]:
                seen[panel["usb_revision"]] = seen.get(panel["usb_revision"], 0) + 1
        self.unique_revisions = {rev for rev, count in seen.items() if count == 1}

        log.info("loaded %d panel(s) from %s", len(panels), self.path)


# ----------------------------------------------------------------- resolution


def sysfs_path(sysname: str) -> str:
    """Resolved /sys path, which embeds the USB port (e.g. .../1-12.1:1.0/...)."""
    try:
        return os.path.realpath(f"/sys/class/input/{sysname}")
    except OSError:
        return ""


def udev_properties(sysname: str) -> dict[str, str]:
    try:
        proc = subprocess.run(
            ["udevadm", "info", "--query=property", f"--name=/dev/input/{sysname}"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log.debug("udevadm failed for %s: %s", sysname, exc)
        return {}
    props = {}
    for line in proc.stdout.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            props[key] = value.strip()
    return props


def connected_outputs() -> dict[str, str]:
    """{edid md5: connector name} for every connected DRM output.

    Connector names renumber (this box has DP-1, DP-3, HDMI-A-1, HDMI-A-4),
    but a monitor's EDID does not change, so the hash is the stable key.
    """
    outputs = {}
    for entry in sorted(Path("/sys/class/drm").glob("card*-*")):
        try:
            if (entry / "status").read_text().strip() != "connected":
                continue
            raw = (entry / "edid").read_bytes()
        except OSError:
            continue
        if not raw:
            continue
        # "card1-DP-1" -> "DP-1", which is what KWin calls it.
        name = entry.name.split("-", 1)[1] if "-" in entry.name else entry.name
        outputs[hashlib.md5(raw).hexdigest()] = name
    return outputs


def resolve_output(panel: dict, by_edid: dict[str, str]):
    """Connector name for a panel, preferring its EDID hash over the literal name."""
    edid = panel.get("edid_hash")
    if edid and edid in by_edid:
        return by_edid[edid], "edid"
    if panel["output"]:
        return panel["output"], "name"
    return None, "unresolved"


def match_panel(cfg: Config, id_path: str, sys_path: str, revision: str):
    """Return (panel, how) or (None, reason).

    Ranked: exact ID_PATH, then port substring of ID_PATH, then port substring
    of the /sys path, then USB revision (bcdDevice) as a port-independent
    fallback so a panel keeps working if it is replugged elsewhere.
    A tie inside a rank means the config is ambiguous, so refuse rather than
    guess -- guessing here silently sends touches to the wrong screen.
    """
    ranked: list[tuple[int, str, dict]] = []
    for panel in cfg.panels:
        if id_path and panel["usb_path"] and panel["usb_path"] == id_path:
            ranked.append((0, "usb_path", panel))
        elif id_path and panel["usb_port"] and panel["usb_port"] in id_path:
            ranked.append((1, "usb_port", panel))
        elif sys_path and panel["usb_port"] and panel["usb_port"] in sys_path:
            ranked.append((2, "sys_path", panel))
        elif (
            revision
            and panel["usb_revision"]
            and panel["usb_revision"] == revision
            and revision in cfg.unique_revisions
        ):
            ranked.append((3, "usb_revision", panel))

    if not ranked:
        return None, "no matching panel in config"

    ranked.sort(key=lambda item: item[0])
    if len(ranked) > 1 and ranked[0][0] == ranked[1][0]:
        names = ", ".join(p["output"] for rank, _, p in ranked if rank == ranked[0][0])
        return None, f"ambiguous config, matches several panels ({names})"
    return ranked[0][2], ranked[0][1]


# -------------------------------------------------------------------- mapper


class Mapper:
    def __init__(self, bus, cfg: Config):
        self.bus = bus
        self.cfg = cfg
        self._armed = False
        self._warned: set[str] = set()

    def _manager(self):
        return dbus.Interface(self.bus.get_object(BUS_NAME, MANAGER_PATH), MANAGER_IFACE)

    def _props(self, sysname: str):
        return dbus.Interface(
            self.bus.get_object(BUS_NAME, DEVICE_PATH.format(sysname)), PROPS_IFACE
        )

    # -- scheduling ---------------------------------------------------------

    def schedule(self, reason: str) -> None:
        """Leading-edge-delayed coalescing.

        Both panels bounce together, so absorb a burst into one pass. Unlike a
        resetting debounce this cannot be starved by a continuous event stream:
        a pass always runs within settle_ms of the first trigger.
        """
        if self._armed:
            log.debug("coalescing trigger %r into the pending pass", reason)
            return
        self._armed = True
        GLib.timeout_add(self.cfg.settle_ms, self._fire, reason)

    def _fire(self, reason: str) -> bool:
        self._armed = False
        self.reconcile(reason)
        return GLib.SOURCE_REMOVE

    # -- work ---------------------------------------------------------------

    def survey(self) -> list[dict]:
        try:
            sysnames = [str(name) for name in self._manager().ListTouch()]
        except dbus.DBusException as exc:
            log.debug("ListTouch unavailable: %s", exc.get_dbus_name())
            return []

        by_edid = connected_outputs()
        report = []
        for sysname in sysnames:
            props = udev_properties(sysname)
            id_path = props.get("ID_PATH", "")
            revision = props.get("ID_USB_REVISION") or props.get("ID_REVISION") or ""
            sys_path = sysfs_path(sysname)
            panel, how = match_panel(self.cfg, id_path, sys_path, revision)
            wanted, viaout = resolve_output(panel, by_edid) if panel else (None, "")
            try:
                current = str(self._props(sysname).Get(DEVICE_IFACE, "outputName"))
            except dbus.DBusException:
                current = None
            report.append(
                {
                    "sysname": sysname,
                    "id_path": id_path,
                    "sys_path": sys_path,
                    "revision": revision,
                    "current": current,
                    "wanted": wanted,
                    "label": panel["label"] if panel else "",
                    "how": how,
                    "via_output": viaout,
                }
            )
        return report

    def reconcile(self, reason: str, attempt: int = 1) -> None:
        report = self.survey()
        if not report:
            return

        unresolved = 0
        for dev in report:
            if not dev["id_path"] and not dev["sys_path"]:
                # udev has not published the device yet; retry, do not guess.
                unresolved += 1
                continue
            if dev["wanted"] is None:
                key = dev["id_path"] or dev["sys_path"]
                if key not in self._warned:
                    self._warned.add(key)
                    log.warning(
                        "touch device %s (%s): %s -- edit %s",
                        dev["sysname"], key, dev["how"], self.cfg.path,
                    )
                continue
            self._apply(dev)

        if unresolved and attempt < self.cfg.udev_retries:
            log.debug("%d device(s) unresolved, scheduling retry %d", unresolved, attempt + 1)
            GLib.timeout_add(
                self.cfg.udev_retry_ms,
                lambda: (self.reconcile(reason, attempt + 1), GLib.SOURCE_REMOVE)[1],
            )

    def _apply(self, dev: dict) -> None:
        sysname, wanted = dev["sysname"], dev["wanted"]
        if dev["current"] == wanted:
            # setOutputName() early-returns on an unchanged value anyway, but
            # skipping the call keeps kcminputrc from being rewritten at all.
            log.debug("%s (%s) already on %s", sysname, dev["label"] or dev["id_path"], wanted)
            return
        try:
            self._props(sysname).Set(DEVICE_IFACE, "outputName", dbus.String(wanted))
        except dbus.DBusException as exc:
            # Usually the deleteLater() race: a re-enumeration reused this
            # sysName before KWin unregistered the old object, so the path is
            # briefly missing. The next deviceAdded fixes it; do not spin here.
            log.warning("could not map %s -> %s: %s", sysname, wanted, exc.get_dbus_name())
            return
        log.info(
            "mapped %s [%s] matched-by=%s output-by=%s: %s -> %s",
            sysname,
            dev["label"] or dev["id_path"],
            dev["how"],
            dev["via_output"],
            dev["current"] or "(unset)",
            wanted,
        )


# ------------------------------------------------------------------ plumbing


def acquire_lock():
    """Advisory single-instance lock. Returns the fd (keep it alive) or None."""
    rundir = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
    fd = os.open(os.path.join(rundir, "touchscreen-mapping.lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        os.close(fd)
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            return None
        raise
    return fd


def run_daemon(cfg: Config) -> int:
    lock = acquire_lock()
    if lock is None:
        # Not a failure; systemd must not restart-loop because someone ran it by hand.
        log.error("another touchscreen-mapping daemon already holds the lock; exiting")
        return 0

    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    mapper = Mapper(bus, cfg)
    loop = GLib.MainLoop()

    # No sender= filter, so the match keeps working after KWin restarts under a
    # new unique bus name without us having to re-subscribe.
    bus.add_signal_receiver(
        lambda sysname: mapper.schedule(f"deviceAdded:{sysname}"),
        signal_name="deviceAdded",
        dbus_interface=MANAGER_IFACE,
        path=MANAGER_PATH,
    )

    def on_owner(owner):
        if owner:
            log.info("KWin present as %s; reconciling", owner)
            mapper.schedule("kwin-appeared")
        else:
            log.info("KWin is not on the bus; waiting")

    # Fires immediately with the current owner, so this is also the start-up
    # reconcile and removes any need to poll for KWin the way the old script did.
    bus.watch_name_owner(BUS_NAME, on_owner)

    if cfg.reconcile_interval_s > 0:
        # Cheap safety net: a missed signal would otherwise mean the wrong
        # screen takes every touch for the rest of the day, silently.
        GLib.timeout_add_seconds(
            cfg.reconcile_interval_s,
            lambda: (mapper.schedule("periodic"), GLib.SOURCE_CONTINUE)[1],
        )

    def on_hup(*_):
        log.info("SIGHUP: reloading %s", cfg.path)
        cfg.load()
        mapper._warned.clear()
        mapper.schedule("reload")
        return GLib.SOURCE_CONTINUE

    def on_term(*_):
        log.info("shutting down")
        loop.quit()
        return GLib.SOURCE_REMOVE

    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGHUP, on_hup)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, on_term)
    GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, on_term)

    loop.run()
    return 0


def run_once(cfg: Config) -> int:
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    Mapper(dbus.SessionBus(), cfg).reconcile("once")
    return 0


def run_status(cfg: Config) -> int:
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    report = Mapper(dbus.SessionBus(), cfg).survey()
    if not report:
        print("No touch devices reported by KWin (is it running?)")
        return 1
    print(f"{'DEVICE':<10} {'CURRENT':<12} {'WANTED':<12} {'':<7} ID_PATH")
    bad = 0
    for dev in report:
        if dev["wanted"] is None:
            verdict, bad = "NO-RULE", bad + 1
        elif dev["current"] == dev["wanted"]:
            verdict = "ok"
        else:
            verdict, bad = "WRONG", bad + 1
        print(
            f"{dev['sysname']:<10} {str(dev['current'] or '-'):<12} "
            f"{str(dev['wanted'] or '-'):<12} {verdict:<7} {dev['id_path'] or dev['sys_path']}"
        )
    return 1 if bad else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--once", action="store_true", help="reconcile once and exit")
    parser.add_argument("--status", action="store_true", help="report mapping; exit 1 if wrong")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
        stream=sys.stderr,
    )

    cfg = Config(args.config)
    if args.status:
        return run_status(cfg)
    if args.once:
        return run_once(cfg)
    return run_daemon(cfg)


if __name__ == "__main__":
    sys.exit(main())
