#!/usr/bin/env bash
set -euo pipefail

# Installs only the system-Voxtype PTT tray integration. Package installation,
# model downloads, and service enable/start are intentionally separate steps.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PROJECTS_DIR="$(dirname -- "$REPO_ROOT")"
OS_TOOLKIT_DIR="${OS_TOOLKIT_DIR:-$PROJECTS_DIR/OS-Toolkit}"
GITHUBGRID_DIR="${GITHUBGRID_DIR:-$PROJECTS_DIR/GitHubGrid}"
TRAY_SOURCE_DIR="${VOXTYPE_PTT_SOURCE_DIR:-$OS_TOOLKIT_DIR/VoxType/voxtype-live}"
CONFIG_SOURCE="${VOXTYPE_CONFIG_SOURCE:-$GITHUBGRID_DIR/dotfiles/voxtype/config.toml}"
SHORTCUT_SOURCE="$REPO_ROOT/config/applications/voxtype-toggle.desktop"

DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/voxtype-ptt-tray"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/voxtype"
USER_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"

TRAY_SOURCE="$TRAY_SOURCE_DIR/voxtype-ptt-tray.py"
DESKTOP_SOURCE="$TRAY_SOURCE_DIR/voxtype-ptt-tray.desktop"
SERVICE_SOURCE="$TRAY_SOURCE_DIR/voxtype-ptt-tray.service"
SERVICE_PREVIEW_SOURCE="$REPO_ROOT/config/systemd/user/voxtype-ptt-tray.service.d/15-live-preview.conf"
SERVICE_GUARD_SOURCE="$REPO_ROOT/config/systemd/user/voxtype-ptt-tray.service.d/20-restart-guard.conf"
VOXTYPE_DROPIN_SOURCE="$REPO_ROOT/config/systemd/user/voxtype.service.d/10-disable-rtkit.conf"
README_SOURCE="$TRAY_SOURCE_DIR/VOXTYPE-PTT-TRAY.md"
CONFIG_DEST="$CONFIG_DIR/config.toml"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for source_file in \
    "$TRAY_SOURCE" \
    "$DESKTOP_SOURCE" \
    "$SERVICE_SOURCE" \
    "$SERVICE_PREVIEW_SOURCE" \
    "$SERVICE_GUARD_SOURCE" \
    "$VOXTYPE_DROPIN_SOURCE" \
    "$README_SOURCE" \
    "$CONFIG_SOURCE" \
    "$SHORTCUT_SOURCE"; do
    [[ -f "$source_file" ]] || die "required source file is missing: $source_file"
done

for command_name in voxtype qdbus6 xprop systemctl; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "required command is missing: $command_name"
done

missing_modules="$(/usr/bin/python3 - <<'PY'
import importlib.util

modules = ("PyQt6", "numpy", "sounddevice", "vosk")
print(" ".join(name for name in modules if importlib.util.find_spec(name) is None))
PY
)"
[[ -z "$missing_modules" ]] \
    || die "system Python modules are missing: $missing_modules"

install -Dm755 "$TRAY_SOURCE" "$DATA_DIR/voxtype-ptt-tray.py"
install -Dm644 "$README_SOURCE" "$DATA_DIR/README.md"
install -Dm644 "$DESKTOP_SOURCE" "$APP_DIR/voxtype-ptt-tray.desktop"
install -Dm644 "$SHORTCUT_SOURCE" "$APP_DIR/voxtype-toggle.desktop"
install -Dm644 "$SERVICE_SOURCE" "$USER_UNIT_DIR/voxtype-ptt-tray.service"
install -Dm644 \
    "$SERVICE_PREVIEW_SOURCE" \
    "$USER_UNIT_DIR/voxtype-ptt-tray.service.d/15-live-preview.conf"
install -Dm644 \
    "$SERVICE_GUARD_SOURCE" \
    "$USER_UNIT_DIR/voxtype-ptt-tray.service.d/20-restart-guard.conf"
install -Dm644 \
    "$VOXTYPE_DROPIN_SOURCE" \
    "$USER_UNIT_DIR/voxtype.service.d/10-disable-rtkit.conf"
install -d -m755 "$DATA_DIR/models" "$CONFIG_DIR"

# The GitHubGrid copy is the managed baseline. Preserve an existing user
# config, then enforce only the settings needed for compositor-controlled
# toggle mode and layout-independent paste output.
if [[ ! -e "$CONFIG_DEST" ]]; then
    install -m600 "$CONFIG_SOURCE" "$CONFIG_DEST"
fi

/usr/bin/python3 - "$CONFIG_DEST" <<'PY'
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)


def set_value(section, key, value):
    global lines
    header = f"[{section}]" if section else None
    if header is None:
        start = 0
    else:
        start = next(
            (index + 1 for index, line in enumerate(lines) if line.strip() == header),
            None,
        )
        if start is None:
            if lines and lines[-1].strip():
                lines.append("\n")
            lines.extend([f"{header}\n", f"{key} = {value}\n"])
            return

    end = next(
        (
            index
            for index in range(start, len(lines))
            if re.match(r"^\s*\[[^]]+\]\s*$", lines[index])
        ),
        len(lines),
    )
    key_pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for index in range(start, end):
        if key_pattern.match(lines[index]):
            lines[index] = f"{key} = {value}\n"
            return
    lines.insert(end, f"{key} = {value}\n")


set_value(None, "state_file", '"auto"')
set_value("hotkey", "mode", '"toggle"')
set_value("hotkey", "enabled", "false")
set_value("whisper", "model", '"large-v3-turbo"')
set_value("whisper", "language", '"en"')
set_value("output", "mode", '"paste"')
set_value("output", "restore_clipboard", "true")
set_value("output", "restore_clipboard_delay_ms", "300")
# The custom PTT tray owns the on-screen status/preview surface.  Disable
# Voxtype's separate built-in OSD so recording never creates a duplicate
# overlay or taskbar window.
set_value("osd", "enabled", "false")

temporary = path.with_name(f".{path.name}.tmp")
temporary.write_text("".join(lines), encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY

# systemd is the sole login-start mechanism for this tray. Remove only a stale
# duplicate autostart copy of this same desktop file; do not install or enable
# the legacy voxtype-live service or its Meta/Alt listener.
rm -f "$AUTOSTART_DIR/voxtype-ptt-tray.desktop"

systemctl --user daemon-reload
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi

printf 'Installed VoxType PTT tray files from %s.\n' "$TRAY_SOURCE_DIR"
printf 'Configuration: %s\n' "$CONFIG_DEST"
printf 'Wake model expected at: %s\n' \
    "$DATA_DIR/models/vosk-model-small-en-us-0.15"
printf '%s\n' \
    'Services were not enabled or started.' \
    'After installing models, enable only voxtype.service and voxtype-ptt-tray.service.'
