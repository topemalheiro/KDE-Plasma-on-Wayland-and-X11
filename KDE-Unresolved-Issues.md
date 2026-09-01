# KDE Plasma — Unresolved Issues Tracker

> This document tracks issues that are **not yet fixed** or require ongoing workarounds. For completed fixes, see `KDE-Customization-TODO.md`.

---

## Issue 1: Hubstaff Minimizes to Taskbar Instead of System Tray

### Status: ✅ FIXED (native settings + KWin rule fallback)

### Problem
Closing/minimizing the Hubstaff window leaves it visible in the KDE panel/taskbar. The user wants it to disappear from the taskbar entirely and live only as a system tray icon. Additionally, if Hubstaff crashes, it should auto-restart and remain tray-only.

### Discovery: Hubstaff Has Native Tray-Only Settings

Reverse-engineering the Hubstaff binary revealed built-in preferences for tray behavior:
- `taskbar_behavior` — controls where the app appears (`0` = taskbar+tray, `1` = tray only)
- `main_window_close_action` — controls what happens on close (`0` = quit, `1` = minimize to taskbar, `2` = minimize to tray)
- `use_helper` — background helper for keeping the app alive

These settings are stored in `~/.local/share/Hubstaff/settings.json` under `client.preferences`.

### Solution: Native Settings First, KWin Rule as Safety Net

**Layer 1 — Native Hubstaff Settings** (`~/.local/share/Hubstaff/settings.json`)
- `taskbar_behavior: "1"` → Show only in system tray (hide from taskbar)
- `main_window_close_action: "1" (Minimize)` → Close/minimize goes to tray, not taskbar
- Managed via `~/Hubstaff/hubstaff-settings-manager.py` for easy toggling

**Layer 2 — KWin Window Rule** (`~/.config/kwinrulesrc`)
- Permanently applies `skipTaskbar=true` and `skipPager=true` to ALL Hubstaff windows
- Works as a safety net even if native settings are reset or ignored
- More reliable than the previous KWin script which toggled on `minimizedChanged`

**Layer 3 — Systemd User Service** (`~/.config/systemd/user/hubstaff.service`)
- Auto-starts Hubstaff at login
- Restarts on crash (`Restart=on-failure`)
- Launcher auto-detects native tray mode and skips kdocker when configured
- Disabled the old desktop autostart to avoid double-launch

### Files Created/Modified

| File | Purpose |
|------|---------|
| `~/Hubstaff/hubstaff-launcher.sh` | Smart launcher: native mode when configured, kdocker fallback otherwise |
| `~/Hubstaff/hubstaff-settings-manager.py` | CLI tool to toggle native tray settings |
| `~/.local/share/Hubstaff/settings.json` | Native tray preferences (`taskbar_behavior=1`, `main_window_close_action=2`) |
| `~/.config/kwinrulesrc` | KWin window rule for permanent taskbar hiding |
| `~/.config/systemd/user/hubstaff.service` | Auto-start and auto-restart on crash |
| `~/.config/autostart/netsoft-com.netsoft.hubstaff.desktop.disabled` | Old autostart disabled |

### How to Apply / Verify

```bash
# Apply native tray settings
~/Hubstaff/hubstaff-settings-manager.py tray-only

# Or manually edit settings.json:
#   client.preferences.taskbar_behavior = "1"
#   client.preferences.main_window_close_action = "2"

# Restart Hubstaff via systemd
systemctl --user daemon-reload
systemctl --user enable hubstaff.service
systemctl --user restart hubstaff.service
qdbus org.kde.KWin /KWin reconfigure
```

**Note:** When native tray mode is active, the launcher skips kdocker entirely. Only Hubstaff's **native** tray icon will appear (no duplicate kdocker icon).

### Settings Manager Commands

```bash
# Show current settings
~/Hubstaff/hubstaff-settings-manager.py show

# Enable tray-only mode
~/Hubstaff/hubstaff-settings-manager.py tray-only

# Revert to default behavior
~/Hubstaff/hubstaff-settings-manager.py default

# Set arbitrary preference
~/Hubstaff/hubstaff-settings-manager.py set taskbar_behavior 0
```

### Deactivation

```bash
# Revert to default Hubstaff behavior
~/Hubstaff/hubstaff-settings-manager.py default

# Stop systemd service
systemctl --user disable hubstaff.service
systemctl --user stop hubstaff.service
mv ~/.config/autostart/netsoft-com.netsoft.hubstaff.desktop.disabled ~/.config/autostart/netsoft-com.netsoft.hubstaff.desktop

# Remove KWin rule via System Settings → Window Rules
```

---

## Issue 2: Pasting Images in VS Code: / Kimi Extension Fails

### Status: ✅ FIXED

### Problem
After taking a screenshot with Spectacle, pasting the image into VS Code: (specifically the Kimi extension chat panel) fails with:
> "There is not an image in the clipboard."

### Root Cause
Spectacle copies images to the **Wayland** clipboard as `image/png`. However, VS Code: on KDE Plasma Wayland usually runs under **XWayland**, which reads from the **X11** clipboard — not the Wayland clipboard. KDE's built-in clipboard sync does not reliably propagate `image/png` across the XWayland boundary, so VS Code: sees nothing.

The initial bridge script only copied to the Wayland clipboard, which is why it didn't work.

### Solution: Dual Clipboard Bridge
The `scripts/clipboard-image-bridge.sh` now copies the image to **both** the X11 clipboard (for XWayland apps like VS Code:) and the Wayland clipboard (for native Wayland apps). It also provides `text/uri-list` as a fallback.

### What It Does
1. Detects whether the image is on the Wayland or X11 clipboard
2. Saves it to a temp file
3. Re-copies `image/png` to the **X11 clipboard** via `xclip`
4. Re-copies `image/png` to the **Wayland clipboard** via `wl-copy`
5. Re-copies `text/uri-list` to Wayland as a fallback

### Usage
```bash
# One-shot fix (run this after a failed paste)
scripts/clipboard-image-bridge.sh fix

# Or start the background daemon (auto-fixes every screenshot)
scripts/clipboard-image-bridge.sh start

# Stop the daemon
scripts/clipboard-image-bridge.sh stop
```

### Reprompty Integration
Three actions are available in Reprompty under **Scripts → Clipboard Image Bridge**:
- `clipboard_image_fix` — one-shot fix
- `clipboard_image_monitor_start` — start daemon
- `clipboard_image_monitor_stop` — stop daemon

### Verification
After running `fix`, both clipboards should contain `image/png`:
```bash
# Wayland
wl-paste --list-types

# X11
xclip -selection clipboard -o -target TARGETS
```

### Deactivation
```bash
scripts/clipboard-image-bridge.sh stop
```

---

## Issue 3: Elastic Overscroll — "Scroll Out of Pages"

### Status: ✅ FIXED (app-level flags)

### Problem
Scrolling past the top/bottom of webpages and documents shows empty space with an elastic bounce-back effect.

### Root Cause
There is **no single KDE system setting** for overscroll. Each app stack implements its own elastic overscroll:
- **Chromium/Electron apps** (VS Code:, Chrome, Edge) — Chromium compositor overscroll
- **Firefox/Librewolf** — `apz.overscroll.enabled`
- **Qt 6 native apps** — Limited overscroll via Qt Wayland platform plugin

### Solution: App-Level Flags

**Google Chrome / Microsoft Edge**
> ⚠️ **Flag to remember:** `--disable-features=ElasticOverscroll`

Applied via multiple methods for redundancy:
1. **`.desktop` launcher files** (`~/.local/share/applications/`)
2. **`~/.config/chrome-flags.conf`**
3. **`~/.config/microsoft-edge-stable-flags.conf`**
4. **Terminal:** `google-chrome --disable-features=ElasticOverscroll`

The old flag `--disable-overscroll-edge-effect` was removed in Chromium 114+. The new feature name is `ElasticOverscroll`.

**Librewolf (`~/.config/librewolf/librewolf/<profile>/user.js`)**
```js
user_pref("apz.overscroll.enabled", false);
```

### What Was Not Changed
Qt 6 native KDE apps (Dolphin, Kate, etc.) were left as-is. Their overscroll is minimal compared to Chromium, and forcing them to XWayland would degrade fractional scaling and HiDPI behavior.

### How to Apply
**Restart affected apps** for the flags to take effect:
```bash
# Restart VS Code:
killall code; code &

# Restart Chrome/Edge
# (Close all windows and reopen from the app menu)

# Restart Librewolf
# (Close and reopen)
```

### Deactivation

**VS Code:** Delete `~/.config/code-flags.conf`

**Chrome/Edge:**
- Edit `.desktop` files in `~/.local/share/applications/`
- Remove `~/.config/chrome-flags.conf`
- Remove `~/.config/microsoft-edge-stable-flags.conf`

**Librewolf:** Edit `~/.config/librewolf/librewolf/<profile>/user.js` and remove the `apz.overscroll.enabled` line

---

## Issue 4: Super+Number Task-Manager Shortcuts Target Primary Display Only

### Status: ⚠️ Transient / upstream KDE bug

### Problem
On a multi-monitor Plasma 6 Wayland setup, pressing `Meta+1`..`Meta+9` (task-manager entry shortcuts) only activates items on the **primary display's** task manager, regardless of which screen has the mouse pointer or focus.

### Root Cause
A regression in Plasma's task manager QML:
```
plasmashell: ContextMenu.qml:378: TypeError:
Property 'currentDesktopByScreenGeometry' of object TaskManager::VirtualDesktopInfo(...) is not a function
```
`currentDesktopByScreenGeometry` was removed/renamed in Plasma 6.6.x, and the task manager code still calls it. When the call fails, shortcut routing falls back to the primary screen.

### Workaround
Restarting `plasmashell` temporarily restores correct behavior:
```bash
killall plasmashell && kstart6 plasmashell
```

### Files/Settings
- Task manager config: `~/.config/plasma-org.kde.plasma.desktop-appletsrc`
- Task manager shortcuts: `~/.config/kglobalshortcutsrc` (`activate task manager entry N`)

### Upstream
This needs a fix in `plasma-desktop` / `org.kde.plasma.taskmanager`. The broken function reference must be updated to the current virtual-desktop API.

---

## Issue 5: Dual Touchscreens Swap / Lose Their Display Mapping Mid-Session

### Status: ✅ FIXED (event-driven remapping daemon; upstream limitation remains)

### Problem
Two USB touchscreens (Verbatim panels on `DP-1` and `HDMI-A-1`). Some minutes
into a session one panel would stop driving its own screen and its touches
would land on the *other* screen. Re-running a login-time fix script restored
it until the next time.

### Root cause
Three things combine:

1. **The panels are indistinguishable to KDE.** Both report
   `Silicon Integrated System Co. SiS HID Touch Controller`, vendor `0x0457`,
   product `0x0819`, with an empty serial. Even `/dev/input/by-id` collapses
   them to one symlink. Only USB topology tells them apart.

2. **KWin can only remember ONE mapping for the pair.** `Connection::applyDeviceConfig`
   (`kwin/src/backends/libinput/connection.cpp:715`) keys the config group on
   vendor + product + name only:
   ```cpp
   device->setConfig(m_config->group("Libinput")
       .group(QString::number(device->vendor()))
       .group(QString::number(device->product()))
       .group(device->name()));
   ```
   Both panels therefore share one group in `~/.config/kcminputrc`, holding a
   single `OutputUuid`. Every device-add applies it to *both*.

3. **The panels re-enumerate constantly.** `TurnOffDisplayIdleTimeoutSec=600`
   means the displays sleep after 10 minutes idle; the monitors then cut their
   built-in USB hubs. Measured: ~20 hub events per boot, 68 in one 39-hour
   session. Each one hands KWin a fresh device that it maps from the shared group.

**There is no config-only fix.** A udev/hwdb rename would give KWin two distinct
groups, but the name comes from `libinput_device_get_name()`
(`device.cpp:347`) = the kernel's `EVIOCGNAME`; `/sys/class/input/*/name` is
read-only, hwdb can only set `EVDEV_ABS_*` / `ID_INPUT_*`, and the devices have
no serial. The mapping must be re-applied at runtime.

### Solution
`touchscreen-mapping.service` — a systemd user daemon subscribed to KWin's
`org.kde.KWin.InputDeviceManager.deviceAdded(sysName)` signal, which fires at
exactly the moment a mapping is lost. It matches devices by persistent udev
`ID_PATH` and resolves the target output by **EDID hash** rather than connector
name (connector names renumber; this box has `DP-1`, `DP-3`, `HDMI-A-1`,
`HDMI-A-4`).

It never writes `kcminputrc` — KWin does that itself inside `setOutputName()`,
and the last-writer-wins churn in the shared group is expected and harmless.

#### Update 2026-09-01: match on `usb_revision`, not `usb_path`

The original `mapping.json` keyed both panels on `usb_path` (`13.3` = left,
`12.1` = right). **USB port assignment on this box is not stable across boots.**
Journal evidence from two consecutive boots on 2026-09-01:

```
17:59  fix-touchscreen: Mapped event11 (pci-0000:00:14.0-usb-0:12.1:1.0) -> DP-1
18:04  daemon:          event11 ... pci-0000:00:14.0-usb-0:13.1:1.0        -> DP-1
```

Same panel (`event11`, bottom-right), two different ports. The monitors' built-in
hubs re-enumerate in whatever order they wake, so the port number is a property
of that boot, not of the panel.

This matters because `usb_path` is **rank 0** in `match_panel()`
(`touchscreen-mapping-daemon.py:203`) and therefore *beats* the `usb_revision`
fallback at rank 3. A pinned port that the *other* panel later lands on would
match at rank 0 and confidently drive the wrong screen — strictly worse than not
matching at all. Both stale paths were also simply dead: the daemon had silently
been running on the `usb_revision` fallback for both panels
(`matched-by=usb_revision` in the journal).

`usb_path` and `usb_port` are now empty for both panels. Matching runs on
`ID_USB_REVISION` (bcdDevice), a firmware property rather than a topology one:
`0600` (bottom-left) and `0200` (bottom-right), unique across the pair, which is
the uniqueness condition the loader enforces at `:123`. Re-add `usb_path` only if
the panels ever move onto a hub that keeps its numbering across a power cycle.

### Files Created/Modified
| Path | Purpose |
|------|---------|
| `scripts/touchscreen-mapping-daemon.py` | the daemon (`--once`, `--status`, `-v`) |
| `config/touchscreen-mapping/mapping.json` | USB path → output table; the only place to edit |
| `config/systemd/user/touchscreen-mapping.service` | unit, bound to `graphical-session.target` |
| `scripts/install-touchscreen-mapping.sh` | installer + migration off the old autostart entry |
| `scripts/restore-post-repair.sh`, `scripts/restore-after-archinstall.sh` | now run the installer |
| `scripts/package-baseline.sh` | added `python-dbus`, `python-gobject` |

Replaced: `~/.config/autostart/fix-touchscreen-mapping.desktop` (moved to
`~/.config/autostart-disabled/`). The old `~/.local/bin/fix-touchscreen-mapping.sh`
is still tracked in `bin.git` and can be `git rm`'d there.

> **2026-09-01:** the retired autostart entry had **reappeared** in
> `~/.config/autostart/` (byte-identical to the disabled copy, mtime 29 min after
> the installer retired it — most likely re-enabled by hand in System Settings →
> Autostart). It was running the old script at every login and racing the daemon
> with its hardcoded `12.1`/`13.3` ports: at the 17:59 boot it mapped a panel,
> at the 18:04 boot it logged `Unmatched` for both. Removed again; the copy in
> `~/.config/autostart-disabled/` is the backup. If it comes back, check
> System Settings → Autostart rather than re-running the installer.

### How to Verify
```bash
systemctl --user status touchscreen-mapping
scripts/touchscreen-mapping-daemon.py --status      # exits 1 if any panel is wrong

# Simulate a monitor standby without waiting 10 minutes.
# NB: `udevadm trigger` does NOT work -- it replays events for an existing
# device and never makes KWin emit deviceAdded.
#
# Do NOT hardcode the port here -- it changes between boots (see the
# 2026-09-01 update above). Resolve it from the panel you want to bounce:
PORT=$(udevadm info -q property -n /dev/input/event11 |
       sed -n 's/^ID_PATH=.*-usb-0:\([0-9.]*\):.*/\1/p')
echo 0 | sudo tee /sys/bus/usb/devices/1-$PORT/authorized
sleep 2
echo 1 | sudo tee /sys/bus/usb/devices/1-$PORT/authorized
journalctl --user -u touchscreen-mapping -n 5
```
Confirmed working: with the daemon stopped, one bounce leaves *both* panels on
`DP-1`; with it running, the journal shows
`mapped event11 [bottom-left Verbatim] matched-by=usb_revision output-by=edid: DP-1 -> HDMI-A-1`.

### Gotcha
Opening **System Settings → Touch Screen** rewrites the shared group and
re-collapses both panels onto one output. The daemon corrects it within ~300 ms.

### Upstream
`connection.cpp:715` should include a per-device discriminator (e.g. udev
`ID_PATH`) in the config group key when `(vendor, product, name)` is ambiguous,
so KWin can natively persist a mapping per panel. Until then a daemon is
required for any pair of identical touchscreens.

---

## Summary

| Issue | Status | What Was Done |
|-------|--------|--------------|
| Hubstaff tray minimize | ✅ Fixed | Native tray settings (`taskbar_behavior=1`, `main_window_close_action=2`) + KWin rule fallback |
| Image paste failures | ✅ Fixed | Dual clipboard bridge (X11 + Wayland) |
| Elastic overscroll | ✅ Fixed | App-level flags for VS Code:, Chrome, Edge, Librewolf |
| Super+Number task manager routing | ⚠️ Watch / upstream | Documented; workaround: restart `plasmashell` |
| Dual touchscreens lose display mapping | ✅ Fixed | `touchscreen-mapping.service` re-maps on KWin's `deviceAdded`; upstream `connection.cpp:715` limitation documented |

---

*Last updated: 2026-08-21*
