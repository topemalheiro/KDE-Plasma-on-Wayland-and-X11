# KDE Plasma Customization Tasks

## Overview

This document tracks all KDE Plasma 6 customizations applied to this system. Each entry includes:
- **Problem** — What was broken or missing
- **Method** — Exact technical steps used to fix it
- **Files Modified/Created** — Full paths for audit and reversal
- **Deactivation** — How to undo the change
- **Status** — Current state

---

## Issues & Fixes

### 1. Dolphin Single-Window Mode ✅ FIXED

**Problem:** Clicking folders/shortcuts from outside Dolphin (e.g., desktop, app launcher) opens a new Dolphin window instead of reusing the existing one.

**Method:**
Dolphin's `dolphinrc` config file (`~/.config/dolphinrc`) controls this behavior. The key `OpenExternallyCalledFolderInNewTab` defaults to `false`. Setting it to `true` causes Dolphin to open external folder requests in a new tab of an existing window rather than spawning a new process.

**Command used:**
```bash
kwriteconfig6 --file dolphinrc --group General --key OpenExternallyCalledFolderInNewTab true
```

**Files modified:**
- `~/.config/dolphinrc` — added `OpenExternallyCalledFolderInNewTab=true` under `[General]`

**Deactivation:**
```bash
kwriteconfig6 --file dolphinrc --group General --key OpenExternallyCalledFolderInNewTab false
# Or delete the line manually from ~/.config/dolphinrc
```

**Status:** Done. Folders clicked from outside Dolphin now open in a new tab of the existing window.

---

### 2. Symlink Path Display in Dolphin ✅ FIXED

**Problem:** When clicking a Desktop symlink (e.g., `Agentic Coding Evals`), Dolphin displays the symlink path (`/home/user/Desktop/Agentic Coding Evals/`) in the location bar instead of the real target path (`/home/user/Projects/Agentic Coding Evals/`).

**Method:**
KDE `.desktop` files with `Type=Link` are interpreted by Dolphin as "open this URL" rather than "navigate to this file's location." Each Desktop symlink to a directory was replaced with a `.desktop` file containing a `URL` field pointing to the target.

The conversion script (`scripts/convert-symlinks-to-desktop.sh`) automated this:
1. Iterates all symlinks in `~/Desktop`
2. Resolves each symlink with `readlink -f`
3. Deletes the symlink
4. Creates a `.desktop` file with `Type=Link` and `URL=file://<target>`
5. Sets `chmod +x` on the `.desktop` file so KDE treats it as a trusted launcher

**Files created (examples):**
- `~/Desktop/Agentic Coding Evals.desktop` → points to `~/Projects/Agentic Coding Evals`
- `~/Desktop/Training Code.desktop` → points to `~/Projects/Training Code`
- (and 7 others)

**Files modified:**
- Original symlinks in `~/Desktop/` were deleted and replaced with `.desktop` files

**Deactivation:**
There is no automatic reversal script. To undo, manually delete each `.desktop` file and recreate the original symlink:
```bash
rm ~/Desktop/"Agentic Coding Evals.desktop"
ln -s ~/Projects/"Agentic Coding Evals" ~/Desktop/
```

**Status:** Done. All Desktop directory symlinks converted. Double-clicking now opens Dolphin at the actual target path.

---

### 3. Pin Recent Places to VS Code: Taskbar Icon ✅ WORKAROUND PROVIDED

**Problem:** VS Code:'s taskbar icon shows recent folders in its right-click menu, but Plasma 6 does not allow pinning individual folders inside an application's taskbar menu.

**Method:**
Plasma 6's task manager only allows pinning `.desktop` files (applications), not individual documents or folders. The workaround creates standalone `.desktop` launcher files for each project. Each launcher is a full application entry that opens VS Code: with a specific folder. Because they are independent `.desktop` files, they can be individually pinned to the taskbar.

The launchers were created in `~/.local/share/applications/vscode-launchers/` with this structure:
```ini
[Desktop Entry]
Type=Application
Name=KDE Plasma on Wayland (VS Code:)
Exec=/usr/bin/code /home/user/Projects/KDE-Plasma-on-Wayland
Icon=visual-studio-code
```

After creation, `kbuildsycoca6 --noincremental` refreshes the application menu so they appear in search.

**Files created:**
- `~/.local/share/applications/vscode-launchers/vscode-agentic-coding.desktop`
- `~/.local/share/applications/vscode-launchers/vscode-os-toolkit.desktop`
- `~/.local/share/applications/vscode-launchers/vscode-kde.desktop`
- `~/.local/share/applications/vscode-launchers/vscode-training.desktop`

**Deactivation:**
```bash
rm -rf ~/.local/share/applications/vscode-launchers/
kbuildsycoca6 --noincremental
# Remove any pinned icons from the taskbar manually
```

**Status:** Done. Workaround available. Pinning must be done manually via taskbar right-click.

---

### 4. Top-Level "Open with VS Code:" in Dolphin Right-Click ✅ FIXED

**Problem:** "Open Folder With VS Code:" is buried inside a submenu (`Open Folder With > Visual Studio Code:`) instead of appearing directly in the top-level context menu.

**Method:**
KIO (KDE's I/O framework) supports custom context menus via **servicemenu** `.desktop` files placed in `~/.local/share/kio/servicemenus/`. These files use `X-KDE-ServiceTypes=KonqPopupMenu/Plugin` to register as context menu plugins and `MimeType=inode/directory;application/x-desktop;` to specify which file types they apply to.

The servicemenu (`open-with-code.desktop`) defines an action that invokes the `open-with-code` helper binary with the selected file paths (`%F`).

**Critical security requirement:** KDE enforces that user-owned `.desktop` files in `servicemenus/` must have the **executable bit** set. Without `chmod +x`, Dolphin logs:
```
Access to "/home/user/.local/share/kio/servicemenus/open-with-code.desktop" denied,
not owned by root and executable flag not set.
```

**Helper binary:**
The `open-with-code.c` program:
1. Checks if the input is a `.desktop` file with `Type=Link`
2. If so, extracts the `URL` field, strips `file://`/`file:` prefixes, expands `$HOME`
3. Resolves symlinks via `realpath()`
4. Verifies the target is a directory
5. Forks and execs `code <target>` for each valid directory

**Install script:** `scripts/install-servicemenu.sh`
- Compiles `open-with-code.c` → `~/.local/bin/open-with-code`
- Copies `open-with-code.desktop` → `~/.local/share/kio/servicemenus/`
- **Sets `chmod +x` on the installed `.desktop` file**
- Runs `kbuildsycoca6 --noincremental` to refresh the service cache

**Files created/modified:**
- `~/.local/share/kio/servicemenus/open-with-code.desktop` (installed by script)
- `~/.local/bin/open-with-code` (compiled by script)

**Deactivation:**
Run the uninstall script:
```bash
./scripts/uninstall-servicemenu.sh
```
Or manually:
```bash
rm ~/.local/share/kio/servicemenus/open-with-code.desktop
rm ~/.local/bin/open-with-code
kbuildsycoca6 --noincremental
killall dolphin
```

**Status:** Done. "Open with VS Code:" appears at the top level. See `scripts/install-servicemenu.sh` and `scripts/uninstall-servicemenu.sh`.

---

### 5. Desktop Right-Click "Open with VS Code:" ✅ FIXED

**Problem:** Right-clicking a folder icon on the Plasma desktop shows no "Open with VS Code:" option.

**Method:**
The Plasma desktop folder view uses the same KIO servicemenu framework as Dolphin. The fix for issue #4 automatically applies here because the servicemenu matches `inode/directory` (folder icons on the desktop have this MIME type).

**Files created:** Same as issue #4

**Deactivation:** Same as issue #4

**Status:** Done. Appears immediately after Dolphin restart or `kbuildsycoca6 --noincremental`.

---

### 6. .desktop / Shortcut Files Open Target with VS Code: ✅ FIXED

**Problem:** Right-clicking a `.desktop` shortcut (Type=Link) or symlink file on the desktop doesn't offer "Open with VS Code:" for the target folder.

**Method:**
The servicemenu matches `application/x-desktop` (MIME type of `.desktop` files). When invoked on a `.desktop` file, the `open-with-code` helper:
1. Opens the file and verifies `Type=Link`
2. Extracts the `URL` field (handles `URL[$e]=` syntax)
3. Strips `file://`, `file:/`, `file:` prefixes
4. Expands `$HOME` environment variable
5. Calls `realpath()` to resolve any remaining symlinks
6. Opens the resolved directory in VS Code:

This ensures that right-clicking a desktop shortcut opens the *target* folder, not the shortcut file itself.

**Files created:** Same as issue #4 (`open-with-code.c` / `open-with-code.sh`)

**Deactivation:** Same as issue #4

**Status:** Done. The helper handles both regular folders and symlink/link targets.

---

### 7. Hubstaff Crash-Restart Loop on Wayland ✅ FIXED

**Problem:** Hubstaff opens, stays visible for ~3 seconds, crashes with exit code 255, and its built-in watchdog immediately restarts it — creating an infinite open/close loop.

**Root Cause:** KDE Plasma's regional format settings (`~/.config/plasma-localerc`) set `LC_TIME=pt_PT.UTF-8`, but the `pt_PT.UTF-8` locale is **not generated** on the system. Hubstaff fails locale initialization and crashes. Its internal watchdog then auto-restarts the child process, causing the loop.

**Method:**
1. Changed `LC_TIME` in `~/.config/plasma-localerc` from `pt_PT.UTF-8` to `en_US.UTF-8` (the latter is generated and valid).
2. Modified the Hubstaff `.desktop` launcher to explicitly set `LC_ALL=en_US.UTF-8` in the `Exec` line, ensuring Hubstaff always launches with a valid locale regardless of session environment.

**Files modified:**
- `~/.config/plasma-localerc` — `LC_TIME=en_US.UTF-8` (was `pt_PT.UTF-8`)
- `~/.local/share/applications/netsoft-com.netsoft.hubstaff.desktop` — `Exec` now points to `hubstaff-launcher.sh`
- `~/Hubstaff/hubstaff-launcher.sh` — new wrapper script that sets `LC_ALL=en_US.UTF-8` before execing the real binary

**Deactivation:**
```bash
# Revert plasma locale setting
kwriteconfig6 --file plasma-localerc --group Formats --key LC_TIME pt_PT.UTF-8

# Revert Hubstaff desktop file
sed -i 's|Exec="/home/user/Hubstaff/hubstaff-launcher.sh"|Exec="/home/user/Hubstaff/HubstaffClient.bin.x86_64"|' ~/.local/share/applications/netsoft-com.netsoft.hubstaff.desktop

# Remove wrapper script
rm /home/user/Hubstaff/hubstaff-launcher.sh
```

**Status:** Done. Hubstaff now launches and stays running.

**Update (2026-06-09):** Fixed intermittent crash (`gtk_widget_destroy` assertion) caused by kdocker `-t` flag conflicting with the `hubstaff-tray-only` KWin script. Replaced the KWin script with a **KWin window rule** (`~/.config/kwinrulesrc`) that permanently hides ALL Hubstaff windows from taskbar/pager regardless of how they're launched. Added a **systemd user service** (`~/.config/systemd/user/hubstaff.service`) for auto-restart on crash. Disabled the old desktop autostart.

**Update (2026-06-10):** Discovered Hubstaff has **native tray-only settings** in `~/.local/share/Hubstaff/settings.json`. Reverse-engineered the binary to find `taskbar_behavior` and `main_window_close_action` preferences. Created `hubstaff-settings-manager.py` to manage these settings. Updated `hubstaff-launcher.sh` to auto-detect native tray mode and skip kdocker when configured, eliminating the duplicate tray icon.

---

## File Inventory

### Source Files (in repo)

| File | Purpose |
|------|---------|
| `scripts/install-servicemenu.sh` | One-shot install: compiles binary, installs servicemenu, sets +x, refreshes cache |
| `scripts/uninstall-servicemenu.sh` | Removes all traces of the servicemenu and helper binary |
| `scripts/open-with-code.desktop` | KIO servicemenu definition (must be `chmod +x` when installed) |
| `scripts/open-with-code.c` | Helper binary source — resolves .desktop links, opens VS Code: |
| `scripts/open-with-code.sh` | Shell equivalent of the C helper (for reference/debugging) |
| `scripts/convert-symlinks-to-desktop.sh` | Converts Desktop symlinks to `.desktop` link files |
| `make-folder-shortcut.sh` | Creates a single KDE folder shortcut `.desktop` file |

### Installed Files (on system)

| File | Purpose | Deletion Command |
|------|---------|------------------|
| `~/.local/share/kio/servicemenus/open-with-code.desktop` | Dolphin/desktop right-click menu entry | `rm ~/.local/share/kio/servicemenus/open-with-code.desktop` |
| `~/.local/bin/open-with-code` | Compiled helper binary | `rm ~/.local/bin/open-with-code` |
| `~/.local/share/applications/vscode-launchers/*.desktop` | Taskbar-pinnable VS Code: project launchers | `rm -rf ~/.local/share/applications/vscode-launchers/` |
| `~/Desktop/*.desktop` (Type=Link) | Folder shortcuts created from symlinks | Delete individually and recreate symlinks |
| `~/.local/share/applications/netsoft-com.netsoft.hubstaff.desktop` | Hubstaff launcher with locale workaround | `sed -i 's|Exec=env LC_ALL=en_US.UTF-8 |Exec=|' ~/.local/share/applications/netsoft-com.netsoft.hubstaff.desktop` |

### Modified Config Files

| File | Key Changed | Reversal Command |
|------|-------------|------------------|
| `~/.config/dolphinrc` | `OpenExternallyCalledFolderInNewTab=true` | `kwriteconfig6 --file dolphinrc --group General --key OpenExternallyCalledFolderInNewTab false` |
| `~/.config/plasma-localerc` | `LC_TIME=en_US.UTF-8` (was `pt_PT.UTF-8`) | `kwriteconfig6 --file plasma-localerc --group Formats --key LC_TIME pt_PT.UTF-8` |
| `~/.local/share/applications/netsoft-com.netsoft.hubstaff.desktop` | `Exec=env LC_ALL=en_US.UTF-8 ...` (was `Exec="/home/user/Hubstaff/HubstaffClient.bin.x86_64" %u`) | `sed -i 's|Exec=env LC_ALL=en_US.UTF-8 |Exec=|' ~/.local/share/applications/netsoft-com.netsoft.hubstaff.desktop` |

---

## Security & Deactivation Strategy

### Design Principle: User-Space Only

All customizations are confined to the user's home directory (`~/.local/`, `~/.config/`, `~/Desktop/`). **No root access, system packages, or immutable files are modified.** This means:
- Customizations can be removed entirely by deleting files in `$HOME`
- No package manager conflicts on system upgrades
- Easy to audit: `find ~/.local/share/kio ~/.local/bin ~/.local/share/applications -name "*code*" -o -name "*vscode*"`

### Quick Deactivation (All Customizations)

Run the provided uninstall scripts, then remove remaining files:

```bash
# 1. Remove the Dolphin right-click servicemenu
./scripts/uninstall-servicemenu.sh

# 2. Remove taskbar-pinnable VS Code: launchers
rm -rf ~/.local/share/applications/vscode-launchers/

# 3. Revert Dolphin single-window mode
kwriteconfig6 --file dolphinrc --group General --key OpenExternallyCalledFolderInNewTab false

# 4. Refresh KDE caches
kbuildsycoca6 --noincremental

# 5. Restart affected applications
killall dolphin
kquitapp6 plasmashell && kstart6 plasmashell
```

### Granular Deactivation (Per-Feature)

| Feature | Toggle On | Toggle Off |
|---------|-----------|------------|
| Dolphin single-window mode | `kwriteconfig6 --file dolphinrc --group General --key OpenExternallyCalledFolderInNewTab true` | `kwriteconfig6 --file dolphinrc --group General --key OpenExternallyCalledFolderInNewTab false` |
| Top-level "Open with VS Code:" | `./scripts/install-servicemenu.sh` | `./scripts/uninstall-servicemenu.sh` |
| VS Code: taskbar launchers | Create files in `~/.local/share/applications/vscode-launchers/` | `rm -rf ~/.local/share/applications/vscode-launchers/` |

### Future-Proofing

- **Keep `scripts/install-servicemenu.sh` and `scripts/uninstall-servicemenu.sh` in version control.** These are idempotent and can be re-run after system reinstalls.
- **The `open-with-code.desktop` must always be installed with `chmod +x`.** The install script handles this automatically.
- **KDE upgrades may reset `dolphinrc`.** The `OpenExternallyCalledFolderInNewTab` setting is persistent but can be re-applied with the one-liner above.
- **Plasma 6 taskbar pinning behavior may change.** The VS Code: launcher workaround is independent of VS Code: itself and will survive app updates.

---

## Remaining Tasks

- [x] Test all right-click menus after fix. — **PASSED**
- [ ] Pin desired VS Code: launchers to taskbar manually.

---

## KWin Shortcut Trick (Command-Line)

**Problem:** Setting KWin window management shortcuts via System Settings GUI is slow and buried deep in menus.

**Trick:** Use `kwriteconfig6` to directly write to `~/.config/kglobalshortcutsrc`:

```bash
# Set "Keep Window Above Others" to Shift+Alt+Q
kwriteconfig6 --file kglobalshortcutsrc --group kwin --key "Window Above Other Windows" "Shift+Alt+Q,,Keep Window Above Others"

# Example: Set "Keep Window Below Others" to Shift+Alt+A
kwriteconfig6 --file kglobalshortcutsrc --group kwin --key "Window Below Other Windows" "Shift+Alt+A,,Keep Window Below Others"
```

**Format:** `primaryShortcut,alternateShortcut,description`

**Apply:** Restart KWin (`kwin_wayland --replace &`) or relogin.

**Find available actions:**

```bash
grep -oP '^[^=]+' ~/.config/kglobalshortcutsrc | grep -i "window\|above\|below\|fullscreen\|minimize\|maximize"
```

**Why this is useful:**

- Batch-configure multiple shortcuts via script
- Replicate settings across machines
- Version-control your KDE shortcuts

---

## New Tasks

### 8. VS Code: Window Layout & Desktop Placement Persistence

**Problem:** VS Code: windows do not consistently open on their assigned virtual desktop with the correct size/position/layout. After logout/login, all VS Code: instances may pile onto the current desktop or lose their previous layout state.

**Desired Behavior:**
- Each VS Code: project window remembers which virtual desktop it belongs to
- Window size, position, and panel layout persist across sessions
- Works automatically when spawning from the taskbar jump list, Reprompty, or command line
- Survives logout/login without manual re-arrangement

**Research & Implementation Plan:**

1. **KWin Window Rules (First Line of Defense)**
   - Create window rules matching `wmclass = Code:` and `title contains <project-name>`
   - Force each rule to open on a specific virtual desktop
   - Match criteria: `Window class (application) = Code:` + `Window title = *project-folder-name*`
   - Actions: `Position = Apply initially`, `Size = Apply initially`, `Virtual Desktop = Apply initially`
   - File: `~/.config/kwinrulesrc`
   - Helper command to inspect window properties for rule creation:
     ```bash
     xprop | grep -E "WM_CLASS|WM_NAME"
     # or for Wayland:
     qdbus org.kde.KWin /KWin queryWindowInfo
     ```

2. **Reprompty Integration (Scripted Layout Engine)**
   - Reprompty already manages VS Code: layouts internally
   - Extend Reprompty's daemon to emit a `desktop-file` or D-Bus signal on window spawn
   - Signal payload: `{ projectUri, preferredDesktop, layoutProfile }`
   - A small KWin script or `kstart` wrapper listens for this signal and:
     - Moves the newly spawned VS Code: window to the requested desktop
     - Applies the saved geometry (x, y, width, height)
     - Optionally restores panel/auxiliary bar visibility state
   - Reprompty side: add `kde.desktop` field to `reprompty.json` layout profiles

3. **KWin Script (Fallback / Global Behavior)**
   - Write a KWin script (`~/.local/share/kwin/scripts/vscode-layout-manager/`) that:
     - Hooks `workspace.windowAdded`
     - Detects VS Code: windows by `window.resourceClass === "Code:"`
     - Reads a JSON map from `~/.config/vscode-layouts.json`:
       ```json
       {
         "/home/user/Projects/Aperant-MCP": { "desktop": 2, "x": 0, "y": 0, "w": 1920, "h": 1080 },
         "/home/user/Projects/KDE-Plasma-on-Wayland": { "desktop": 3, "x": 1920, "y": 0, "w": 1920, "h": 1080 }
       }
       ```
     - Parses the window title or uses `xprop`/`qdbus` to find the opened folder
     - Moves the window to the saved desktop and geometry
   - Register the script:
     ```bash
     mkdir -p ~/.local/share/kwin/scripts/vscode-layout-manager/contents/code
     # write main.js and metadata.json
     kpackagetool6 --type Kwin/Script --install ~/.local/share/kwin/scripts/vscode-layout-manager
     # or upgrade:
     kpackagetool6 --type Kwin/Script --upgrade ~/.local/share/kwin/scripts/vscode-layout-manager
     ```

4. **Session Restore Coordination**
   - KDE's session restore (`~/.config/ksmserverrc`) can restore VS Code: windows, but it doesn't know about virtual desktop assignments for individual folders
   - Ensure the KWin script runs *after* session restore completes (hook `workspace.windowAdded` covers this)
   - OR disable VS Code: from ksmserver restore and let the jump list / Reprompty re-spawn windows with correct placement

**Files to Create:**
- `~/.config/kwinrulesrc` (or `~/.config/kwinrules` — verify Plasma 6 path)
- `~/.config/vscode-layouts.json`
- `~/.local/share/kwin/scripts/vscode-layout-manager/contents/code/main.js`
- `~/.local/share/kwin/scripts/vscode-layout-manager/metadata.json`
- Reprompty extension: `VSCodeSidePanelLayout/daemon/src/kde_window_manager.hpp` (D-Bus emitter)

**Deactivation:**
```bash
# Disable KWin script
kpackagetool6 --type Kwin/Script --remove vscode-layout-manager
# Remove rules
rm ~/.config/kwinrulesrc
# Remove layout map
rm ~/.config/vscode-layouts.json
kwin_wayland --replace &
```

**Status:** TODO — Research KWin window rule format on Plasma 6 Wayland, prototype KWin script.

---

### 9. System Tray "Show" Should Bring App to Current Desktop

**Problem:** Clicking **Show** on a system tray icon (e.g., Reprompty, Spotify, Discord, Hubstaff) switches the user's view to the virtual desktop where that application is currently running. This is disruptive — the user wants the application window to teleport to the **current desktop** instead.

**Current Behavior:**
- System tray context menu → `Show <App>` → KWin calls `activateWindow()` → KWin switches to the window's current desktop

**Desired Behavior:**
- System tray context menu → `Show <App>` → KWin moves the window to the **current desktop** → then activates it
- Applies to ALL applications accessed via system tray, not just Reprompty
- Does NOT affect taskbar clicking (taskbar behavior can stay as-is or be toggled separately)

**Research & Implementation Plan:**

1. **Verify Current KWin Setting**
   - Check if Plasma already has a setting for this:
     - System Settings → Window Management → Window Behavior → Advanced
     - Look for "When activating a task, switch to its desktop" or similar
   - Check `~/.config/kwinrc` keys:
     ```ini
     [Windows]
     FocusStealingPreventionLevel=...
     ```
   - If a GUI toggle exists, document it and decide if it meets the requirement

2. **KWin Script Approach (Most Likely Needed)**
   - Write a KWin script that intercepts window activation requests originating from the system tray
   - Hook: `workspace.windowActivated` or `window.activeChanged`
   - Detect if activation came from system tray (heuristic: check if the window was on a different desktop and the mouse/keyboard focus was on the panel/system tray area)
   - Better hook: intercept the D-Bus method that Plasma's system tray uses to raise windows
   - Plasma's system tray uses `org.kde.plasma.WindowManagement` or direct `KWindowSystem::forceActiveWindow()`
   - **Alternative:** Override the `raiseWindow` behavior globally:
     ```javascript
     // In KWin script
     workspace.windowActivated.connect((window) => {
       if (window && window.desktop !== workspace.currentDesktop) {
         // Move window to current desktop before activating
         window.desktop = workspace.currentDesktop;
       }
     });
     ```
     - **Caveat:** This would affect ALL window activations (Alt-Tab, taskbar, etc.), not just system tray. Need a toggle or a more precise trigger.

3. **Per-App Whitelist / Blacklist**
   - The KWin script should read `~/.config/tray-teleport.json`:
     ```json
     {
       "enabled": true,
       "affectTaskbar": false,
       "apps": ["reprompty", "spotify", "discord", "hubstaff"],
       "excludeApps": ["firefox", "code"]
     }
     ```
   - Match by `window.resourceClass.toLowerCase()` or `window.caption`

4. **Reprompty-Specific Shortcut (Immediate Fix)**
   - If a global KWin script is too invasive, Reprompty can implement its own shortcut:
     - Register a global D-Bus service `com.reprompty.WindowControl`
     - Method `BringToCurrentDesktop()` moves the Reprompty window to the current desktop
     - The system tray menu's `Show Reprompty` action calls this D-Bus method instead of the default `activateWindow()`
   - This only fixes Reprompty, not other apps

5. **Investigate Plasma's "Activate Raises" Setting**
   - In `~/.config/kwinrc`:
     ```ini
     [Windows]
     ActivateRaises=false
     ```
   - Or check if `FocusPolicy` settings affect this behavior
   - Document findings in this TODO

**Files to Create:**
- `~/.local/share/kwin/scripts/tray-teleport/contents/code/main.js`
- `~/.local/share/kwin/scripts/tray-teleport/metadata.json`
- `~/.config/tray-teleport.json`

**Deactivation:**
```bash
kpackagetool6 --type Kwin/Script --remove tray-teleport
rm ~/.config/tray-teleport.json
kwin_wayland --replace &
```

**Status:** TODO — Research exact KWin activation flow for system tray icons on Plasma 6 Wayland. Test if existing KWin setting covers this.

---

## Updated Remaining Tasks

- [x] Test all right-click menus after fix. — **PASSED**
- [ ] Pin desired VS Code: launchers to taskbar manually.
- [ ] Implement VS Code: window layout persistence (KWin rules + script).
- [ ] Implement system tray "Show" teleport-to-current-desktop behavior.


---

### 10. Dolphin "Copy Location" Broken with Multiple Selections ✅ FIXED

**Problem:** In Dolphin, right-clicking multiple selected files/folders and choosing **Copy Location** does nothing. The action works fine with a single item but is silently disabled when more than one item is selected.

**Root Cause:** Dolphin's source code explicitly disables the `copy_location` action when `selectedItems.size() != 1` in three places:
1. `src/dolphincontextmenu.cpp:394` — `copyPathAction->setEnabled(m_selectedItems.size() == 1);`
2. `src/dolphinmainwindow.cpp:2658` — `copyLocation->setEnabled(list.length() == 1);`
3. `src/views/dolphinview.cpp:2691-2707` — `copyPathToClipboard()` only copies the first item's path.

**Method:**
1. Cloned Dolphin source (`invent.kde.org/system/dolphin`) into `dolphin/`
2. Patched all three locations to support multiple selections:
   - Context menu: enabled when `>= 1` item selected
   - Main window toolbar/menu: enabled when `>= 1` item selected
   - `copyPathToClipboard()`: iterates all selected items, joins paths with `\n`
3. Built Dolphin from source (`cmake .. && make -j$(nproc)`)
4. Installed via user-space override:
   - Wrapper script at `~/.local/bin/dolphin`
   - Desktop file override at `~/.local/share/applications/org.kde.dolphin.desktop`

**Files modified (in repo):**
- `dolphin/src/dolphincontextmenu.cpp`
- `dolphin/src/dolphinmainwindow.cpp`
- `dolphin/src/views/dolphinview.cpp`

**Files created (on system):**
- `~/.local/bin/dolphin` — wrapper script pointing to build binary
- `~/.local/share/applications/org.kde.dolphin.desktop` — override with patched binary path

**Deactivation:**
```bash
rm ~/.local/bin/dolphin
rm ~/.local/share/applications/org.kde.dolphin.desktop
kbuildsycoca6 --noincremental
```

**Status:** Done. Copy Location now works with any number of selected items, copying all paths joined by newlines.

---

### 11. Power Management — Never Auto-Suspend, Only Dim → Black Screen ✅ FIXED

**Problem:** KDE Plasma's default power management automatically suspends the system after idle time. The user wants the system to **never suspend or sleep automatically** — only dim the screen, then turn it off (black), even if idle inhibitors from VS Code: or agent frameworks aren't detected.

**Method:**
Configured Plasma 6's `powerdevil` daemon (`powerdevilrc`) for all three profiles (AC, Battery, LowBattery):

| Setting | Value | Meaning |
|---|---|---|
| `AutoSuspendAction` | `0` (`NoAction`) | Never auto-suspend |
| `PowerButtonAction` | `64` (`TurnOffScreen`) | Power button turns off screen only |
| `PowerDownAction` | `64` (`TurnOffScreen`) | Power-down action turns off screen only |
| `LidAction` | `64` (`TurnOffScreen`) | Lid close turns off screen only |
| `DimDisplayWhenIdle` | `true` | Dim screen after idle timeout |
| `TurnOffDisplayWhenIdle` | `true` | Turn off (black) screen after longer idle timeout |

**Timeouts configured:**
| Profile | Dim After | Turn Off After |
|---|---|---|
| AC | 300s (5 min) | 600s (10 min) |
| Battery | 120s (2 min) | 300s (5 min) |
| LowBattery | 60s (1 min) | 120s (2 min) |

**Files modified:**
- `~/.config/powerdevilrc` — added `[AC]`, `[Battery]`, `[LowBattery]` profile groups

**Systemd hardening (optional but recommended):**
A systemd logind drop-in was prepared at `/tmp/99-prevent-auto-suspend.conf` to prevent systemd from independently suspending on lid close or idle:
```bash
sudo mkdir -p /etc/systemd/logind.conf.d
sudo cp /tmp/99-prevent-auto-suspend.conf /etc/systemd/logind.conf.d/
sudo systemctl restart systemd-logind
```
This sets:
- `HandleLidSwitch=ignore`
- `HandleLidSwitchExternalPower=ignore`
- `IdleAction=ignore`
- `HandlePowerKey=ignore` (accidental press protection; long-press still powers off)

**Deactivation (revert powerdevil settings):**
```bash
# Remove profile settings from powerdevilrc
kwriteconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 1
kwriteconfig6 --file powerdevilrc --group Battery --group SuspendAndShutdown --key AutoSuspendAction 1
kwriteconfig6 --file powerdevilrc --group LowBattery --group SuspendAndShutdown --key AutoSuspendAction 1
systemctl --user restart plasma-powerdevil.service
```

**Status:** Done. Powerdevil was restarted and is running with the new config. System will dim, then black out the screen, but never suspend automatically.

---

## Updated Remaining Tasks

- [x] Test all right-click menus after fix. — **PASSED**
- [x] Pin desired VS Code: launchers to taskbar manually. — **N/A**
- [ ] Implement VS Code: window layout persistence (KWin rules + script).
- [ ] Implement system tray "Show" teleport-to-current-desktop behavior.
- [x] Fix Dolphin Copy Location with multiple selections.
- [x] Configure power management to never auto-suspend.


---

### 12. Desktop Folder Shortcuts — Restore Link Badge Icons & Folder Color Support

**Problem:** The `Type=Link` `.desktop` files we created on the Desktop (to replace symlinks) no longer show the **small chain/link badge overlay** in the bottom-right corner. They also lost the ability to **change folder color** via the "Assign Tags" / color-picker feature that vanilla KDE folder icons support.

**Vanilla behavior (symlinks):**
- Symlinks to folders show the target folder's icon with a chain-link badge overlay
- Right-click → "Assign Tags" allows changing the folder color

**Current behavior (`.desktop` Type=Link):**
- Shows a generic folder icon with no link badge
- Color/tag changes don't apply because the icon is rendered as a generic `.desktop` launcher, not as a folder thumbnail

**Research & Implementation Plan:**

1. **Understand how KDE renders desktop icons**
   - Plasma's folder view applet (`kde-plasma-desktop/applets/folder/`) renders desktop items
   - For symlinks, it uses `KFileItem::isLink()` and overlays the link emblem via `KIconLoader::Emblem`
   - For `.desktop` files with `Type=Link`, it treats them as "URL/desktop entry" rather than "folder icon with emblem"

2. **Option A: Patch Plasma's folder view to overlay link emblem on `.desktop` Type=Link**
   - Locate the icon rendering path in the folder view applet
   - Check if the `.desktop` file has `Type=Link` and `URL` pointing to a directory
   - If so, render the target folder's icon + link emblem instead of the generic `.desktop` icon
   - Files to investigate:
     - `kde-plasma-desktop/applets/folder/` (or `plasma-workspace/containments/desktop/`)
     - `kde-plasma-workspace/kioworkers/desktop/kio_desktop.cpp`

3. **Option B: Patch Dolphin/KIO to recognize `.desktop` Type=Link as a folder link**
   - Modify `KFileItem` or icon resolution so that `.desktop` files with `Type=Link` and `inode/directory`-like targets get the folder icon + emblem treatment
   - This might be cleaner because it fixes the behavior system-wide, not just on the desktop

4. **Folder color support**
   - KDE stores folder colors via extended attributes or `.directory` files
   - The color is applied during icon rendering based on the resolved target path
   - If we patch the icon renderer to resolve `.desktop` links before choosing the icon, color support should come for free

**Files to investigate/create:**
- `kde-plasma-desktop/applets/folder/package/contents/ui/ItemDelegate.qml` (or similar)
- `kde-plasma-workspace/kioworkers/desktop/kio_desktop.cpp`
- `kio/src/core/kfileitem.cpp` (icon resolution)

**Deactivation:**
Revert to symlink approach (loses correct path display in Dolphin) or remove the patch and rebuild affected components.

**Implementation:**

Patched `kde-plasma-desktop` folder containment plugin (`libfolderplugin.so`) and its QML delegate:

1. **`foldermodel.cpp`** (C++ model layer):
   - `IsLinkRole`: Returns `true` for `.desktop` files with `Type=Link` (in addition to symlinks)
   - `Qt::DecorationRole`: Returns the **target folder's icon name** for `.desktop` links, enabling folder color/tags to apply

2. **`FolderItemDelegate.qml`** (QML view layer):
   - Added `linkEmblem: Kirigami.Icon` overlay (`emblem-symbolic-link`) positioned bottom-right of the main icon
   - Visible when `main.isLink` is true

3. **Build & install** (user-space):
   ```bash
   cmake -B build -S . -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$HOME/.local
   cmake --build build --target folderplugin -j$(nproc)
   cmake --install build --component folderplugin
   cp build/bin/libfolderplugin.so ~/.local/lib/qt6/qml/org/kde/private/desktopcontainment/folder/
   cp containments/desktop/package/contents/ui/FolderItemDelegate.qml \
      ~/.local/share/plasma/plasmoids/org.kde.desktopcontainment/contents/ui/
   killall plasmashell && kstart6 plasmashell
   ```

**Deactivation:**
Revert to symlink approach (loses correct path display in Dolphin) or remove the patch and rebuild affected components.

**Status:** DONE (2026-08-22) — but it was silently broken for two months first.

**Regression and real fix:** the patch was only ever hand-built into `~/.local/lib/qt6/qml/...`,
which is not on Qt6's QML import path, so it looked installed while doing nothing. The
`plasma-desktop 6.7.2-1.1` rebuild of 9 Jul then overwrote the packaged copy, because
`scripts/build-patched-plasma-packages.sh` could hold only **one patch per package** and carried
just the jumplist patch. `PACKAGE_PATCHES` now takes a list and `PACKAGE_VERIFY` checks a marker
per patch, so a dropped patch fails the build instead of shipping a package quietly missing the
feature. The stale `~/.local` overrides have been moved aside.

**Three faults exposed once it actually ran** (all fixed 2026-08-22):
- `Qt::DecorationRole` returned the link *target's* icon unconditionally, discarding the entry's
  own `Icon=` — so choosing an icon in Properties appeared to do nothing. It now mirrors KIO's
  `iconFromDesktopFile()`: the entry's own icon wins, and only the placeholder `folder` derives
  from the target (which is what makes the target's colour show through).
- Real symlinks got **two** badges: KIO composites `emblem-symbolic-link` into the decoration
  itself, and the QML overlay keyed off `IsLinkRole` drew a second on top. A new
  `IsDesktopFileLinkRole` drives the overlay so only `.desktop` links get it; `IsLinkRole` still
  drives the italic label.
- Folder colour was still unreachable from a shortcut's context menu — see item #17.

---

### 13. Copy Target Path from Desktop Shortcuts via Ctrl+Shift+C

**Problem:** Pressing **Ctrl+Shift+C** (or right-click → Copy Location) on desktop `.desktop` shortcuts copies the shortcut's own path (`~/Desktop/Stuffs.desktop`) instead of the **target folder's path** (`~/Projects/Stuffs/`). This should work for both single and multiple selected shortcuts.

**Context:** We already fixed this inside Dolphin (item #10), but the Plasma desktop folder view uses a **different code path** for its context menu and keyboard shortcuts.

**Research & Implementation Plan:**

1. **Identify the desktop copy-location code path**
   - Plasma desktop folder view context menu: likely in `kde-plasma-workspace/containments/desktop/` or `applets/folder/`
   - Keyboard shortcut handler: `KStandardAction::Copy` might be overridden by the folder view
   - The `filemenu.cpp` in `kde-plasma-workspace/applets/notifications/` has a "Copy Location" action, but that's for notifications, not the desktop

2. **Find the desktop's Copy Location / Ctrl+Shift+C implementation**
   - Search for `Copy Location`, `copyPath`, `Ctrl+Shift+C`, or `KStandardAction::Copy` in:
     - `kde-plasma-desktop/applets/folder/`
     - `kde-plasma-workspace/containments/desktop/`
     - `kde-plasma-workspace/kioworkers/desktop/`
   - The desktop likely uses `KFileItemActions` or a custom QML context menu

3. **Implement target-path resolution**
   - When the selected item is a `.desktop` file with `Type=Link`:
     1. Parse the `URL` field (handle `URL[$e]=`, `file://`, `$HOME`)
     2. Resolve via `realpath()`
     3. Place the resolved directory path on the clipboard
   - For multiple selections: join all resolved paths with newlines (match Dolphin behavior)

4. **Hook into keyboard shortcut**
   - Ensure `Ctrl+Shift+C` triggers the same logic as the context menu "Copy Location"
   - The shortcut might be handled by `KDirOperator`, `DolphinView`, or a Plasma-specific component

**Files to investigate:**
- `kde-plasma-desktop/applets/folder/package/contents/ui/FolderView.qml`
- `kde-plasma-workspace/containments/desktop/plugins/folder/` (if exists)
- `kio/src/widgets/kfileitemactions.cpp` (if desktop uses KIO menus)

**Deactivation:**
Remove patch and rebuild the affected Plasma component, or revert to original files.

**Implementation:**

Patched `kde-plasma-desktop` folder containment plugin (`libfolderplugin.so`) and its QML delegate:

1. **`foldermodel.cpp`**:
   - Added `copyLocation` action to `actionCollection` with icon `edit-copy-path`
   - Implemented `copyLocation()` slot: iterates selected items, resolves `.desktop` `Type=Link` targets via `KDesktopFile::readUrl()`, joins paths with newlines, copies to clipboard
   - Added action to context menu (after "Copy")

2. **`foldermodel.h`**: Declared `Q_INVOKABLE void copyLocation();`

3. **`FolderView.qml`**: Added `Ctrl+Shift+C` keyboard handler calling `dir.copyLocation()`

**Build & install** (same as item #12):
```bash
cmake --build build --target folderplugin -j$(nproc)
cp build/bin/org/kde/private/desktopcontainment/folder/libfolderplugin.so \
   ~/.local/lib/qt6/qml/org/kde/private/desktopcontainment/folder/
cp containments/desktop/package/contents/ui/FolderView.qml \
   ~/.local/share/plasma/plasmoids/org.kde.desktopcontainment/contents/ui/
killall plasmashell && kstart6 plasmashell
```

**Deactivation:**
Remove patch and rebuild the affected Plasma component, or revert to original files.

**Status:** DONE — Both context menu "Copy Location" and `Ctrl+Shift+C` shortcut now resolve target paths for `.desktop` Type=Link files.

**Note:** lost in the same 9 Jul rebuild as item #12 and restored 2026-08-22.
`plasma-desktop-copy-location.patch` is now registered in the build pipeline with a
`PACKAGE_VERIFY` marker.

---

### 14. Taskbar Jump List — Open Projects with Reprompty Layout & Virtual Desktop

**Problem:** Clicking a project in the VS Code: taskbar jump list (e.g., "Reprompty", "Aperant-MCP") opens VS Code: with that folder, but it doesn't:
- Apply the associated **Reprompty layout preset**
- Move the window to the **correct virtual desktop**
- Restore the saved **window geometry**

The jump list currently acts as a simple "open folder" launcher. It needs to be the entry point for the full workspace restoration pipeline.

**Research & Implementation Plan:**

1. **Extend `code-jumplist-manager.py`**
   - Add a `launch` command (or modify the `Exec` line in `code.desktop`) that:
     1. Opens the folder in VS Code:
     2. Notifies Reprompty (or reads `reprompty.json`) to apply the matching layout profile
     3. Emits a D-Bus signal or writes to a known file: `{ projectUri, preferredDesktop, layoutProfile }`
   - Store the mapping in a new config file: `~/.config/vscode-jumplist/layout-map.json`
     ```json
     {
       "/home/user/Projects/Reprompty": { "desktop": 2, "layout": "side-panel" },
       "/home/user/Projects/Aperant-MCP": { "desktop": 3, "layout": "zen" }
     }
     ```

2. **Create a KWin script (`vscode-jumplist-spawner`)**
   - Hook `workspace.windowAdded`
   - Detect VS Code: windows spawned by a jump list action (heuristic: `window.resourceClass === "Code:"` + recent spawn time)
   - Read `~/.config/vscode-jumplist/layout-map.json`
   - Match by parsing the window title (e.g., "Reprompty — VS Code:")
   - Apply:
     - `window.desktop = mappedDesktop`
     - `window.frameGeometry = QRect(x, y, w, h)`
   - Register with `kpackagetool6 --type Kwin/Script --install`

3. **Alternative: Replace jump list `Exec` with a launcher script**
   - Instead of `code /path/to/project`, use a wrapper:
     ```bash
     Exec=/home/user/.local/bin/vscode-jumplist-launcher "%k"
     ```
   - The launcher:
     1. Calls `code /path/to/project`
     2. Calls Reprompty CLI to apply layout: `reprompty --layout-profile side-panel`
     3. Calls a small D-Bus helper or KWin script to move the window

4. **Reprompty integration**
   - Add a `kde.desktop` field to `reprompty.json` layout profiles
   - Reprompty daemon emits `com.reprompty.WindowControl` D-Bus signal on spawn
   - Signal payload: `{ projectUri, preferredDesktop, layoutProfile, geometry }`
   - KWin script listens for this signal and applies placement

**Files to Create:**
- `~/.config/vscode-jumplist/layout-map.json`
- `~/.local/share/kwin/scripts/vscode-jumplist-spawner/contents/code/main.js`
- `~/.local/share/kwin/scripts/vscode-jumplist-spawner/metadata.json`
- `scripts/vscode-jumplist-launcher.py` (optional wrapper approach)

**Deactivation:**
```bash
kpackagetool6 --type Kwin/Script --remove vscode-jumplist-spawner
rm ~/.config/vscode-jumplist/layout-map.json
# Revert code.desktop Exec lines to plain `code` calls
```

**Implementation:**

Created a lightweight, standalone pipeline that doesn't depend on Reprompty MCP integration:

1. **`~/.config/vscode-jumplist/layout-map.json`** — User-editable mapping of project paths to virtual desktops (1-indexed):
   ```json
   {
     "/home/user/Projects/KDE-Plasma-on-Wayland": { "desktop": 2 },
     "/home/user/Projects/Aperant-MCP": { "desktop": 3 }
   }
   ```

2. **`code-open-folder` launcher** (modified existing wrapper):
   - Reads `layout-map.json`
   - If project has a `desktop` mapping, writes `pending-placement.json` with `{ project, desktop, timestamp }`
   - Then launches `/usr/bin/code "$@"`

3. **KWin Script: `vscode-jumplist-spawner`**
   - Hooks `workspace.windowAdded`
   - Detects VS Code: windows by `resourceClass` ("code" / "code:")
   - Reads `pending-placement.json` via `QProcess`
   - If pending placement is within 15s, moves window to specified desktop via `window.desktops = [targetDesktop]`
   - Clears pending file after placement
   - Installed to `~/.local/share/kwin/scripts/vscode-jumplist-spawner/`
   - Enabled via `kwriteconfig6 --file kwinrc --group Plugins --key vscode-jumplist-spawnerEnabled true`

4. **`code-jumplist-manager.py`** extended with:
   - `set-desktop <path> <desktop>` — add/update mapping
   - `unset-desktop <path>` — remove mapping
   - `list-mappings` — show all mappings

**Deactivation:**
```bash
kpackagetool6 --type KWin/Script --remove vscode-jumplist-spawner
rm ~/.config/vscode-jumplist/layout-map.json
# Revert code.desktop Exec lines to plain `code` calls
```

**Status:** DONE — Jump list items now spawn VS Code: windows on the configured virtual desktop. KWin reloaded via `qdbus6 org.kde.KWin /KWin reconfigure`.

---

### 15. Bootloader & i2c Module Loading

**Problem:** Two hardware/boot-level issues need fixing:
1. **i2c modules not loading at boot** — Needed for hardware monitoring, display brightness (ddcutil), or fan controllers. Currently must be loaded manually or fails to initialize.
2. **Bootloader menu not appearing** — The system boots straight into the default kernel without showing a menu to choose between different installed kernels or Windows (dual-boot).

**Research & Implementation Plan:**

#### 15a. i2c Module Loading

1. **Identify which i2c modules are needed**
   ```bash
   lsmod | grep i2c
   ls /sys/bus/i2c/devices/
   dmesg | grep -i i2c
   ```
   Common modules: `i2c_dev`, `i2c_i801`, `i2c_smbus`, `i2c_algo_bit`, `ddci`

2. **Enable at boot**
   - Create a systemd-modules-load drop-in:
     ```bash
     sudo mkdir -p /etc/modules-load.d
     sudo tee /etc/modules-load.d/i2c.conf << 'EOF'
     i2c_dev
     i2c_i801
     i2c_smbus
     EOF
     ```
   - Or add to `mkinitcpio` if modules are needed in initramfs:
     ```bash
     # In /etc/mkinitcpio.conf, add to MODULES=(... i2c_dev i2c_i801 ...)
     sudo mkinitcpio -P
     ```

3. **Fix permissions (if ddcutil/i2c access is denied)**
   - Add user to `i2c` group: `sudo usermod -aG i2c tope`
   - Or create a udev rule:
     ```bash
     sudo tee /etc/udev/rules.d/50-i2c.rules << 'EOF'
     KERNEL=="i2c-[0-9]*", MODE="0666"
     EOF
     ```

#### 15b. Bootloader Menu

1. **Identify the bootloader**
   ```bash
   ls /boot/loader/entries/ 2>/dev/null && echo "systemd-boot" || echo "not systemd-boot"
   ls /boot/grub/grub.cfg 2>/dev/null && echo "GRUB" || echo "not GRUB"
   efibootmgr -v 2>/dev/null | head -10
   ```

2. **If GRUB:**
   - Edit `/etc/default/grub`:
     ```bash
     GRUB_TIMEOUT=10
     GRUB_TIMEOUT_STYLE=menu
     GRUB_DISABLE_OS_PROBER=false
     ```
   - Regenerate config:
     ```bash
     sudo grub-mkconfig -o /boot/grub/grub.cfg
     ```
   - Ensure `os-prober` is installed for Windows detection:
     ```bash
     sudo pacman -S os-prober
     ```

3. **If systemd-boot:**
   - Edit `/boot/loader/loader.conf`:
     ```ini
     timeout 10
     console-mode max
     ```
   - Ensure Windows entry exists:
     ```bash
     sudo bootctl update
     # Or manually create entry in /boot/loader/entries/
     ```

4. **If rEFInd:**
   - Edit `/boot/refind_linux.conf` or `/efi/EFI/refind/refind.conf`
   - Ensure `timeout` is set and OS detection is enabled

**Files Modified/Created (system):**
- `/etc/modules-load.d/i2c.conf`
- `/etc/udev/rules.d/50-i2c.rules` (optional)
- `/etc/default/grub` or `/boot/loader/loader.conf`
- `/boot/grub/grub.cfg` (regenerated)

**Deactivation:**
```bash
# i2c
sudo rm /etc/modules-load.d/i2c.conf
# GRUB
sudo sed -i 's/GRUB_TIMEOUT=10/GRUB_TIMEOUT=0/' /etc/default/grub
sudo grub-mkconfig -o /boot/grub/grub.cfg
# systemd-boot
sudo sed -i 's/timeout 10/timeout 0/' /boot/loader/loader.conf
```

**Diagnosis:**

- **Bootloader:** systemd-boot 260.1 (`/boot/loader/loader.conf` has `timeout 5`, `console-mode max`)
- **i2c modules:** Already loaded at boot (`i2c_i801`, `i2c_smbus`, `i2c_mux`, `i2c_dev`, `i2c_algo_bit`)
- **User groups:** `tope` is **NOT** in the `i2c` group (GID 967 exists)

**Findings:**
1. i2c modules are already loading automatically (likely via udev/modprobe). The only missing piece is **user permissions** for tools like `ddcutil`.
2. Bootloader menu timeout is 5 seconds. This should be enough, but the EFI variable or fast boot might override it.

**Actions to complete (requires `sudo`):**
```bash
# i2c permissions
sudo usermod -aG i2c tope

# Bootloader: increase timeout and ensure systemd-boot is up to date
sudo sed -i 's/^timeout .*/timeout 10/' /boot/loader/loader.conf
sudo bootctl set-timeout 10
sudo bootctl update
```

**Deactivation:**
```bash
# i2c
sudo gpasswd -d tope i2c
# Bootloader
sudo sed -i 's/^timeout .*/timeout 5/' /boot/loader/loader.conf
sudo bootctl set-timeout 5
```

**Status:** DIAGNOSED — Run the sudo commands above, then **log out and back in** for the i2c group change to take effect.

---

## Updated Remaining Tasks

- [x] Fix desktop folder shortcuts: restore link badge icon + folder color support.
- [x] Fix Ctrl+Shift+C on desktop shortcuts to copy target path(s).
- [x] Integrate taskbar jump list with Reprompty layout + virtual desktop placement.
- [x] Fix i2c module loading at boot and restore bootloader menu.
- [x] Hubstaff native tray-only mode via settings.json.

---

### 16. Hubstaff Native Tray-Only Mode ✅ FIXED

**Problem:** Even with kdocker + KWin rules, Hubstaff still appears on the taskbar when closed/minimized. The user wants true tray-only behavior (like Reprompty or Discord) where closing the window leaves only the system tray icon.

**Root Cause:** Hubstaff has built-in tray/background preferences that were never configured. The binary contains UI strings for:
- `taskbar_behavior` — "Taskbar and system tray" vs "Only in system tray"
- `main_window_close_action` — "Quit", "Minimize to taskbar", "Minimize to system tray"
- `use_helper` — "Use background helper (requires restart)"

These preferences are stored in `~/.local/share/Hubstaff/settings.json` under `client.preferences`.

**Method:**

1. **Reverse-engineered the binary** to discover the setting keys and their semantic meaning
2. **Modified `settings.json`** to set:
   - `taskbar_behavior: "1"` → Show only in system tray
   - `main_window_close_action: "2"` → Close/minimize goes to tray
3. **Created `hubstaff-settings-manager.py`** — a CLI tool to easily toggle between tray-only and default behavior:
   ```bash
   ~/Hubstaff/hubstaff-settings-manager.py tray-only   # Enable tray-only
   ~/Hubstaff/hubstaff-settings-manager.py default     # Revert to default
   ~/Hubstaff/hubstaff-settings-manager.py show        # Show current settings
   ```
4. **Updated `hubstaff-launcher.sh`** — auto-detects native tray mode and skips kdocker when configured, avoiding the duplicate tray icon

**Files created/modified:**
- `~/Hubstaff/hubstaff-settings-manager.py` — new settings manager CLI
- `~/Hubstaff/hubstaff-launcher.sh` — updated to detect native tray mode
- `~/.local/share/Hubstaff/settings.json` — added `taskbar_behavior` and `main_window_close_action`

**Deactivation:**
```bash
~/Hubstaff/hubstaff-settings-manager.py default
# Or manually edit ~/.local/share/Hubstaff/settings.json
```

**Status:** DONE — Hubstaff now uses its native tray-only settings. KWin rule remains as a safety net. Only one tray icon (native) appears when in tray-only mode.

---

### 17. Folder Colour Swatches, Symlink Paths, and Shortcut Naming ✅ FIXED

**Status:** DONE (2026-08-22)

**A — no colour picker on a shortcut.** A `Type=Link` shortcut's MIME type is
`application/x-desktop`, and KIO filters `kfileitemaction` plugins by MIME type
(`kfileitemactions.cpp:607`). Dolphin's folder-colour plugin declares `inode/directory` only, so
its swatch row was never offered on a shortcut.

`plasma-desktop-folder-color-links.patch`: when a whole selection resolves to writable local
directories, offer *that one plugin* the resolved targets, so it writes `Icon=folder-<colour>`
into the target's `.directory` — where the DecorationRole branch already reads the colour from.

Adversarial review killed the first attempt. `KFileItemActions` resolves URLs from its properties
**lazily, at trigger time**, so re-setting the shared instance retroactively retargeted the Open
With entries already inserted for the shortcut: "Open With → Kate" would have handed Kate the
target folder instead of the `.desktop` file. Fixed with a separate FolderModel-owned
`KFileItemActions`, plus `MenuActionSource::Plugins` and an allowlist, so no servicemenu — present
or installed later — can be redirected at the target folder.

**B — symlinks open at the wrong path.** `FolderModel::run()` opened `item.targetUrl()`, the
symlink's own path, so the location bar read `~/Desktop/<name>`.
`plasma-desktop-symlink-target-navigation.patch` resolves symlinks-to-directories to their
canonical target in `run()` and `cd()`. Symlinks already get the badge and colour menu natively,
so this was the only piece they lacked.

**C — new links are named after the URL.** Upstream KIO bug in
`knameandurlinputdialog.cpp:118-121`: the default name comes from `url.fileName()`, which is empty
when the path ends in `/`, so it falls back to `url.toString()`. Browsing to a *directory* always
yields a trailing slash, hence names like `file:⁄⁄⁄home⁄tope⁄Projects⁄OS-Toolkit⁄plans⁄`
(KDE substitutes U+2044 FRACTION SLASH for `/`).

`plasma-desktop-create-folder-shortcut.patch` adds a **Create Folder Shortcut…** action to the
desktop and Folder View context menus: writes a `Type=Link` `.desktop` named after the folder,
de-duplicates the filename, sets the executable bit, and refreshes via `KDirNotify`. Note the
desktop containment builds its empty-area menu from `Plasmoid.contextualActions` via
`sharedActions` in `FolderViewLayer.qml`, **not** through `FolderModel::openContextMenu()`, so the
action has to be registered in both places.

KIO itself was deliberately **not** patched. The 2-line `StripTrailingSlash` fix is correct and
worth filing upstream, but kio is a core Frameworks library that every KDE app links, and it
releases monthly — holding it would be a monthly rebuild treadmill. A previous kio patch here
(`~/build/kio/fix-symlink-to-desktop-link.patch`) was already silently wiped by an upgrade for
exactly that reason. Workaround for the stock dialog: delete the trailing `/` in the URL field and
the Name field fills in correctly.

**Files:**
- `patches/plasma-desktop-folder-color-links.patch`
- `patches/plasma-desktop-symlink-target-navigation.patch`
- `patches/plasma-desktop-create-folder-shortcut.patch`
- `scripts/repair-desktop-shortcuts.sh` — audits and fixes existing shortcuts (missing URL scheme,
  missing exec bit, URL-shaped symlink names)
- `scripts/revert-desktop-to-symlinks.sh` — the reversal item #2 said did not exist

**Deactivation:** remove the patches from `PACKAGE_PATCHES` (and their `PACKAGE_VERIFY` markers)
in `scripts/build-patched-plasma-packages.sh`, then rebuild.
