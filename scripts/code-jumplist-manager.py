#!/usr/bin/env python3
"""
code-jumplist-manager.py — Manages VS Code: taskbar jump list

Pin state is stored in VS Code:'s settings.json (kdeJumplist.pinnedFolders)
Recent state is stored in our own state.json (auto-synced from VS Code: storage.json)

Usage:
  python3 code-jumplist-manager.py add <folder-path>      # Add to recent
  python3 code-jumplist-manager.py pin <folder-path>      # Pin a place
  python3 code-jumplist-manager.py unpin <folder-path>    # Unpin a place
  python3 code-jumplist-manager.py clear-recent           # Clear recent (keep pinned)
  python3 code-jumplist-manager.py refresh                # Regenerate code.desktop
  python3 code-jumplist-manager.py restore                # Restore state from backup
  python3 code-jumplist-manager.py set-desktop <path> <desktop>   # Map project to desktop
  python3 code-jumplist-manager.py unset-desktop <path>            # Remove desktop mapping
  python3 code-jumplist-manager.py list-mappings                   # Show all desktop mappings
"""

import fcntl
import functools
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import unquote, urlparse

# Paths
STATE_DIR = Path.home() / ".config" / "vscode-jumplist"
STATE_FILE = STATE_DIR / "state.json"
BACKUP_FILE = STATE_DIR / "state.json.backup"
LOCK_FILE = STATE_DIR / ".lock"
LAYOUT_MAP_FILE = STATE_DIR / "layout-map.json"

VS_CODE_CONFIG = Path.home() / ".config" / "Code"
SETTINGS_FILE = VS_CODE_CONFIG / "User" / "settings.json"
STORAGE_FILE = VS_CODE_CONFIG / "User" / "globalStorage" / "storage.json"

DESKTOP_FILE = Path.home() / ".local" / "share" / "applications" / "code.desktop"
MAX_RECENT = 10
VENDOR_DESKTOP_FILES = (
    Path("/usr/share/applications/code.desktop"),
    Path("/usr/share/applications/visual-studio-code.desktop"),
)
VSCODE_ICON_FALLBACK = Path("/usr/share/pixmaps/vscode.png")


def init_state():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    if not STATE_FILE.exists():
        STATE_FILE.write_text('{"recent": [], "pinned": []}')


def read_state():
    init_state()
    with open(STATE_FILE, 'r') as f:
        return json.loads(f.read())


def write_state(state):
    temp_file = STATE_FILE.with_suffix('.tmp')
    with open(temp_file, 'w') as f:
        f.write(json.dumps(state, indent=2))
    os.replace(temp_file, STATE_FILE)


def backup_state():
    if STATE_FILE.exists():
        shutil.copy2(STATE_FILE, BACKUP_FILE)


def restore_state():
    if BACKUP_FILE.exists():
        shutil.copy2(BACKUP_FILE, STATE_FILE)
        refresh_desktop()
        print("✅ State restored from backup.")
    else:
        print("❌ No backup file found.")


def read_settings():
    if SETTINGS_FILE.exists():
        with open(SETTINGS_FILE, 'r') as f:
            return json.load(f)
    return {}


def write_settings(settings):
    SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
    temp = SETTINGS_FILE.with_suffix('.tmp')
    with open(temp, 'w') as f:
        json.dump(settings, f, indent=4)
    os.replace(temp, SETTINGS_FILE)


def get_pinned():
    settings = read_settings()
    return settings.get('kdeJumplist.pinnedFolders', [])


def set_pinned(pinned):
    settings = read_settings()
    settings['kdeJumplist.pinnedFolders'] = pinned
    write_settings(settings)


def file_uri_to_path(uri):
    """Convert a local file URI from VS Code storage into an absolute path."""
    if not isinstance(uri, str):
        return None

    parsed = urlparse(uri)
    if parsed.scheme != "file" or parsed.netloc not in ("", "localhost"):
        return None

    path = unquote(parsed.path)
    if not path:
        return None
    return str(Path(path).resolve())


def sync_recent_from_vscode():
    """Make recents follow VS Code's current window order.

    VS Code puts the most recently active folder in ``lastActiveWindow``.  It is
    deliberately considered before the other open and backed-up folders so an
    already-known project moves back to the front when it is reopened.
    """
    if not STORAGE_FILE.exists():
        return False

    state = read_state()
    pinned_uris = set(get_pinned())

    try:
        with open(STORAGE_FILE, 'r') as f:
            storage = json.load(f)
    except (OSError, json.JSONDecodeError) as error:
        print(f"⚠️ Could not read VS Code recent state: {error}", file=sys.stderr)
        return False

    vscode_folders = []
    seen = set()

    def remember(uri):
        path = file_uri_to_path(uri)
        if path and path not in seen and path not in pinned_uris:
            vscode_folders.append(path)
            seen.add(path)

    windows_state = storage.get('windowsState', {})

    # Priority 1: the folder VS Code most recently activated.
    remember(windows_state.get('lastActiveWindow', {}).get('folder', ''))

    # Priority 2: openedWindows
    for opened_window in windows_state.get('openedWindows', []):
        remember(opened_window.get('folder', ''))

    # Priority 3: backupWorkspaces
    for item in storage.get('backupWorkspaces', {}).get('folders', []):
        remember(item.get('folderUri', ''))

    old_recent = state.get("recent", [])
    old_by_uri = {
        item.get("uri"): item
        for item in old_recent
        if isinstance(item, dict) and item.get("uri")
    }
    now = int(time.time())
    merged = []

    # The VS Code order is authoritative for currently known folders.  Reuse
    # timestamps for stable entries; ordering, not needless timestamp churn,
    # drives the jump list.
    for path in vscode_folders:
        existing = old_by_uri.get(path, {})
        merged.append({
            "uri": path,
            "name": Path(path).name,
            "timestamp": existing.get("timestamp", now),
        })

    for item in old_recent:
        uri = item.get("uri") if isinstance(item, dict) else None
        if not uri or uri in seen or uri in pinned_uris:
            continue
        merged.append({
            "uri": uri,
            "name": item.get("name") or Path(uri).name,
            "timestamp": item.get("timestamp", now),
        })

    merged = merged[:MAX_RECENT]
    if merged == old_recent:
        return False

    state["recent"] = merged
    write_state(state)
    return True


def with_lock(func):
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        # A fresh profile has no jump-list directory yet.  Create it before
        # opening the lock file so the very first watcher/manual refresh works.
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOCK_FILE, 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                return func(*args, **kwargs)
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
    return wrapper


def resolve_path(path):
    path = str(path)
    if not path.endswith('.desktop'):
        return str(Path(path).resolve())
    try:
        desktop_type = None
        url = None
        with open(path, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('Type='):
                    desktop_type = line[5:]
                elif line.startswith('URL'):
                    url = line.split('=', 1)[1]
        if desktop_type == 'Link' and url:
            if url.startswith('file://'):
                url = url[7:]
            elif url.startswith('file:'):
                url = url[5:].lstrip('/')
            url = url.replace('$HOME', str(Path.home()))
            resolved = Path(url).resolve()
            if resolved.is_dir():
                return str(resolved)
    except Exception:
        pass
    return str(Path(path).resolve())


@with_lock
def add_recent(path):
    path = resolve_path(path)
    backup_state()
    state = read_state()
    state["recent"] = [p for p in state["recent"] if p["uri"] != path]
    if path not in set(get_pinned()):
        state["recent"].insert(0, {
            "uri": path,
            "name": Path(path).name,
            "timestamp": int(time.time())
        })
    state["recent"] = state["recent"][:MAX_RECENT]
    write_state(state)
    _regenerate_desktop(state)


@with_lock
def pin_place(path):
    path = resolve_path(path)
    pinned = get_pinned()
    if path not in pinned:
        pinned.append(path)
        set_pinned(pinned)
    # Also remove from our recent list if present
    state = read_state()
    state["recent"] = [p for p in state["recent"] if p["uri"] != path]
    write_state(state)
    _regenerate_desktop(state)


@with_lock
def unpin_place(path):
    path = resolve_path(path)
    pinned = get_pinned()
    if path in pinned:
        pinned.remove(path)
        set_pinned(pinned)
    # Add back to recent
    state = read_state()
    state["recent"] = [p for p in state["recent"] if p["uri"] != path]
    state["recent"].insert(0, {
        "uri": path,
        "name": Path(path).name,
        "timestamp": int(time.time())
    })
    state["recent"] = state["recent"][:MAX_RECENT]
    write_state(state)
    _regenerate_desktop(state)


@with_lock
def clear_recent():
    backup_state()
    state = read_state()
    state["recent"] = []
    write_state(state)
    _regenerate_desktop(state)


@with_lock
def refresh_desktop():
    sync_recent_from_vscode()
    state = read_state()
    _regenerate_desktop(state)


def _regenerate_desktop(state):
    """Generate code.desktop from the given state dict (no VS Code: sync)."""
    pinned = get_pinned()
    pinned_set = set(pinned)
    recent = [
        r for r in state.get("recent", [])
        if r["uri"] not in pinned_set
    ][:MAX_RECENT]

    actions = ["new-empty-window"]
    action_entries = []
    idx = 0

    for path in pinned:
        idx += 1
        name = Path(path).name
        safe_name = name.replace("\\", "\\\\").replace('"', '\\"').replace("&", "&&")
        safe_path = path.replace("\\", "\\\\").replace('"', '\\"').replace("&", "&&")

        # Open action (pinned — text only, icon is on the right toggle button)
        action_id = f"open-pinned-{idx}"
        actions.append(action_id)
        action_entries.append(
            f"\n[Desktop Action {action_id}]\n"
            f"Name={safe_name}\n"
            f"Exec={Path.home() / '.local' / 'bin' / 'code-open-folder'} \"{safe_path}\"\n"
        )

        # Unpin action
        action_id = f"unpin-pinned-{idx}"
        actions.append(action_id)
        action_entries.append(
            f"\n[Desktop Action {action_id}]\n"
            f"Name=Unpin {safe_name}\n"
            f"Exec=python3 {Path.home() / '.local' / 'bin' / 'code-jumplist-manager'} unpin \"{safe_path}\"\n"
            f"Icon=edit-delete\n"
        )

    for item in recent:
        idx += 1
        name = item["name"]
        uri = item["uri"]
        safe_name = name.replace("\\", "\\\\").replace('"', '\\"').replace("&", "&&")
        safe_uri = uri.replace("\\", "\\\\").replace('"', '\\"').replace("&", "&&")

        # Open action (recent — text only, icon is on the right toggle button)
        action_id = f"open-recent-{idx}"
        actions.append(action_id)
        action_entries.append(
            f"\n[Desktop Action {action_id}]\n"
            f"Name={safe_name}\n"
            f"Exec={Path.home() / '.local' / 'bin' / 'code-open-folder'} \"{safe_uri}\"\n"
        )

        # Pin action
        action_id = f"pin-recent-{idx}"
        actions.append(action_id)
        action_entries.append(
            f"\n[Desktop Action {action_id}]\n"
            f"Name=Pin {safe_name}\n"
            f"Exec=python3 {Path.home() / '.local' / 'bin' / 'code-jumplist-manager'} pin \"{safe_uri}\"\n"
            f"Icon=pin\n"
        )

    actions.extend(["clear-recent"])
    manager_path = str(Path.home() / ".local" / "bin" / "code-jumplist-manager")
    action_entries.append(f"""
[Desktop Action clear-recent]
Name=Clear Recent Places
Exec={manager_path} clear-recent
Icon=edit-clear-history
""")

    actions_str = ";".join(actions)
    icon = resolve_vscode_icon()
    desktop_content = f"""[Desktop Entry]
Name=Visual Studio Code:
Comment=Code Editing. Redefined.
GenericName=Text Editor
Exec=/usr/bin/code %F
Icon={icon}
Type=Application
StartupNotify=false
StartupWMClass=Code
Categories=TextEditor;Development;IDE;
MimeType=application/x-code-workspace;
Actions={actions_str};
Keywords=vscode;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=/usr/bin/code --new-window %F
Icon={icon}
{''.join(action_entries)}
"""
    DESKTOP_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        unchanged = DESKTOP_FILE.read_text() == desktop_content
    except OSError:
        unchanged = False

    if unchanged:
        # Keep KDE's trusted-launcher bit correct without invalidating its cache.
        if DESKTOP_FILE.stat().st_mode & 0o777 != 0o755:
            os.chmod(DESKTOP_FILE, 0o755)
        print("✅ Jump list already up to date.")
        return False

    atomic_write_desktop(desktop_content)
    refresh_kde_service_cache()
    print("✅ Jump list updated. Right-click the VS Code: taskbar icon to see changes.")
    return True


def resolve_vscode_icon(vendor_desktops=VENDOR_DESKTOP_FILES,
                        fallback=VSCODE_ICON_FALLBACK):
    """Use VS Code's resolvable vendor icon, then its packaged pixmap."""
    for desktop_file in vendor_desktops:
        try:
            in_desktop_entry = False
            for line in desktop_file.read_text().splitlines():
                stripped = line.strip()
                if stripped.startswith("[") and stripped.endswith("]"):
                    in_desktop_entry = stripped == "[Desktop Entry]"
                    continue
                if in_desktop_entry and stripped.startswith("Icon="):
                    icon = stripped.split("=", 1)[1].strip()
                    if icon_is_resolvable(icon):
                        return icon
                    break
        except OSError:
            continue

    if fallback.is_file():
        return str(fallback)
    return "vscode"


def icon_is_resolvable(icon):
    """Ask KDE to resolve a named icon, or validate an absolute icon path."""
    if not icon:
        return False
    if os.path.isabs(icon):
        return Path(icon).is_file()

    icon_finder = shutil.which("kiconfinder6")
    if not icon_finder:
        return False

    result = subprocess.run(
        [icon_finder, icon],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    resolved_path = result.stdout.strip()
    return result.returncode == 0 and bool(resolved_path) and Path(resolved_path).is_file()


def atomic_write_desktop(content):
    """Replace code.desktop atomically so Plasma never sees a partial file."""
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{DESKTOP_FILE.name}.",
        dir=DESKTOP_FILE.parent,
        text=True,
    )
    try:
        with os.fdopen(file_descriptor, "w") as temporary_file:
            temporary_file.write(content)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.chmod(temporary_name, 0o755)
        os.replace(temporary_name, DESKTOP_FILE)
    except Exception:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def refresh_kde_service_cache():
    """Synchronously reload KDE's application metadata after a real change."""
    cache_builder = shutil.which("kbuildsycoca6")
    if not cache_builder:
        print("⚠️ kbuildsycoca6 not found; KDE will refresh the launcher later.",
              file=sys.stderr)
        return

    result = subprocess.run(
        [cache_builder, "--noincremental"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        print("⚠️ KDE service-cache refresh failed; the file is installed safely.",
              file=sys.stderr)


def migrate_pins_from_state():
    """One-time migration: copy pinned items from old state.json to VS Code: settings.json."""
    state = read_state()
    old_pins = state.get("pinned", [])
    if not old_pins:
        return

    current_pins = get_pinned()
    migrated = False
    for item in old_pins:
        uri = item.get("uri", "")
        if uri and uri not in current_pins:
            current_pins.append(uri)
            migrated = True

    if migrated:
        set_pinned(current_pins)
        print(f"✅ Migrated {len(old_pins)} pinned item(s) to VS Code: settings.json")


def read_layout_map():
    if not LAYOUT_MAP_FILE.exists():
        return {}
    try:
        with open(LAYOUT_MAP_FILE, 'r') as f:
            data = json.load(f)
            # Filter out comment keys
            return {k: v for k, v in data.items() if not k.startswith('_')}
    except (json.JSONDecodeError, IOError):
        return {}


def write_layout_map(mapping):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    temp = LAYOUT_MAP_FILE.with_suffix('.tmp')
    with open(temp, 'w') as f:
        json.dump(mapping, f, indent=2)
    os.replace(temp, LAYOUT_MAP_FILE)


@with_lock
def set_desktop(path, desktop):
    path = resolve_path(path)
    mapping = read_layout_map()
    mapping[path] = {"desktop": int(desktop)}
    write_layout_map(mapping)
    print(f"✅ Mapped '{path}' to desktop {desktop}")


@with_lock
def unset_desktop(path):
    path = resolve_path(path)
    mapping = read_layout_map()
    if path in mapping:
        del mapping[path]
        write_layout_map(mapping)
        print(f"✅ Removed desktop mapping for '{path}'")
    else:
        print(f"⚠️ No desktop mapping found for '{path}'")


def list_mappings():
    mapping = read_layout_map()
    if not mapping:
        print("No desktop mappings configured.")
        return
    print("Desktop mappings:")
    for path, cfg in sorted(mapping.items()):
        desktop = cfg.get("desktop", "?")
        print(f"  Desktop {desktop}: {path}")


def main():
    if len(sys.argv) < 2:
        print("""Usage: code-jumplist-manager <command> [path]
Commands:
  add <path>        Add folder to Recent
  pin <path>        Pin a place
  unpin <path>      Unpin a place
  clear-recent      Clear Recent (Pinned untouched)
  refresh           Regenerate code.desktop from state
  restore           Restore state from backup
  migrate           Migrate old state.json pins to VS Code: settings
""")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "add":
        add_recent(sys.argv[2])
    elif cmd == "pin":
        pin_place(sys.argv[2])
    elif cmd == "unpin":
        unpin_place(sys.argv[2])
    elif cmd == "clear-recent":
        clear_recent()
    elif cmd == "refresh":
        refresh_desktop()
    elif cmd == "restore":
        restore_state()
    elif cmd == "migrate":
        migrate_pins_from_state()
    elif cmd == "set-desktop":
        if len(sys.argv) < 4:
            print("Usage: set-desktop <path> <desktop-number>")
            sys.exit(1)
        set_desktop(sys.argv[2], sys.argv[3])
    elif cmd == "unset-desktop":
        if len(sys.argv) < 3:
            print("Usage: unset-desktop <path>")
            sys.exit(1)
        unset_desktop(sys.argv[2])
    elif cmd == "list-mappings":
        list_mappings()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
