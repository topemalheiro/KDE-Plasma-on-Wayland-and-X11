# Insightful / Workpuls on KDE Plasma 6

Desktop integration for the Insightful (Workpuls) time-tracking agent on Arch +
KDE Plasma 6. Same idea as the Hubstaff tray integration elsewhere in this repo,
but Insightful needs more work because its tray icon is partly broken.

Works on **both Wayland and X11**. Wayland is the better choice — see
[Wayland vs X11](#wayland-vs-x11) at the bottom.

## Re-setup after a reinstall

```bash
sudo pacman -S python-pyqt6 python-dbus
./insightful-setup.sh
```

Then drop `Workpuls.AppImage` in `~/Downloads` (or set `WORKPULS_APPIMAGE` to
point elsewhere) and `chmod +x` it. The script is idempotent — re-running it is
safe.

## What's broken out of the box, and what fixes it

### 1. The AppImage silently does nothing when launched from a terminal

Exits 0, no window, no error. VS Code sets `ELECTRON_RUN_AS_NODE=1` in its
integrated terminal for its own tooling, and that variable makes *any* Electron
binary run as plain Node. The giveaway is that `--no-sandbox` gets rejected in
Node's error format rather than Chromium's.

`insightful-start.sh` unsets it before exec'ing. That is the entire script's
reason to exist.

### 2. The tray icon vanishes a second after appearing

Not a bug in the app — Plasma had it in `hiddenItems`, which collapses it behind
the tray's expand chevron. Managed per-panel in
`~/.config/plasma-org.kde.plasma.desktop-appletsrc`, and there is one entry per
panel, so all of them need changing.

### 3. Left-clicking the tray icon does nothing

The agent's StatusNotifierItem does not implement `Activate`:

```console
$ dbus-send --session --print-reply --dest=:1.xxx \
    /org/ayatana/NotificationItem/workpuls_agent1 \
    org.kde.StatusNotifierItem.Activate int32:0 int32:0
Error org.freedesktop.DBus.Error.UnknownMethod: No such method "Activate"
```

Per the SNI spec a host calls `Activate` on left-click. Plasma does, gets
`UnknownMethod`, and nothing happens. **No configuration can fix this** — the
method is simply absent from the closed-source binary.

`insightful-tray-proxy.py` works around it: a second tray icon that *does*
implement `Activate` (Qt provides it), forwarding every action to the agent's own
DBusMenu. Left-click triggers the agent's own "Show Insightful" entry; the
context menu mirrors whatever the agent currently offers, re-read every 15s so
the live "Start break (Time left: …)" label stays accurate. The agent's own icon
goes into `hiddenItems`, so only one icon is visible.

Nothing is reimplemented — the proxy only presses the agent's own buttons.

### 4. Minimizing leaves a dead entry in the taskbar

`insightful-kwin-script/` hooks `minimizedChanged` and sets
`skipTaskbar`/`skipPager` to match. Minimize → gone from the taskbar, tray icon
remains. Restore → back in the taskbar.

## Gotchas

**Closing the window quits the app.** It uses client-side decorations, so there
is no `WM_DELETE_WINDOW` for the window manager to intercept — kdocker and
KWin scripts alike are powerless here. **Minimize, never close.** kdocker was
tried for this and does not work; it only adds a second, dead icon.

**Never set `skipSwitcher`.** With the window hidden from the taskbar, Alt+Tab is
the only fallback if the tray icon fails. Setting it leaves the window
unreachable.

**`workspace.windows` does not exist in KWin 6.** It throws
`Cannot read property 'length' of undefined`. Use `workspace.stackingOrder`.
Scripts that enumerate existing windows this way appear to work only because
`windowAdded` is connected before the throw.

**`dbus.Variant` does not exist in python-dbus.** Variants are ordinary values
with `variant_level=1`. Getting this wrong inside a PyQt6 slot does not print a
traceback — PyQt6 turns unhandled slot exceptions into `abort()`, so the process
dies with SIGABRT. Every slot in the proxy is wrapped for that reason.

**Match the window by class, not caption.** `resourceClass` is `workpuls-agent`.
Matching on the caption "Insightful" also matches a browser tab titled
"Insightful | Employees".

## Verification

1. Tray icon visible without expanding the chevron, and stays.
2. Left-click opens the window.
3. Right-click lists Show Insightful / Start break / Open dashboard.
4. Minimize → gone from taskbar, icon remains; Alt+Tab still reaches it.
5. `pgrep kdocker` returns nothing.
6. Reboot and confirm all of the above.

## Wayland vs X11

The agent runs fine on Wayland. It is an Electron app, so it goes through
XWayland automatically, and the timer is just a clock plus HTTP calls — no screen
access needed.

What differs is **window attribution**: under Wayland an X11 client only sees
other XWayland clients, so Wayland-native apps are invisible to it and their time
is reported as unclassified ("Neutral") rather than named. Apps forced to
XWayland (`--ozone-platform=x11` for Electron/Chromium, `QT_QPA_PLATFORM=xcb` for
Qt) are tracked normally, browsers included.

Screen capture would be the real blocker, since a rootless XWayland root window
cannot be screenshotted — but that only matters if the deployment has screenshots
enabled. Check before assuming, and verify against the dashboard rather than
guessing.

Check what is visible from inside a Wayland session with:

```bash
xprop -root _NET_CLIENT_LIST | tr ',' '\n' | grep -oE '0x[0-9a-f]+' | \
  while read w; do xprop -id $w WM_CLASS WM_NAME 2>/dev/null | paste -sd' '; done
```

Anything absent from that list is invisible to the agent.
