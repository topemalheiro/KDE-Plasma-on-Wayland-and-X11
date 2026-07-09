#!/bin/bash
# Restore the repo-managed Hubstaff launcher, KWin rule, and user service.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

HUBSTAFF_DIR="$HOME/Hubstaff"
LAUNCHER_SOURCE="$SCRIPT_DIR/hubstaff/hubstaff-launcher.sh"
SETTINGS_MANAGER_SOURCE="$SCRIPT_DIR/hubstaff/hubstaff-settings-manager.py"
LAUNCHER_DEST="$HUBSTAFF_DIR/hubstaff-launcher.sh"
SETTINGS_MANAGER_DEST="$HUBSTAFF_DIR/hubstaff-settings-manager.py"
KWIN_RULES_SOURCE="$REPO_ROOT/config/kwinrulesrc"
KWIN_RULES_DEST="$HOME/.config/kwinrulesrc"
UNIT_SOURCE="$REPO_ROOT/config/systemd/user/hubstaff.service"
UNIT_DEST="$HOME/.config/systemd/user/hubstaff.service"
DESKTOP_FILE="$HOME/.local/share/applications/netsoft-com.netsoft.hubstaff.desktop"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }

mkdir -p "$HUBSTAFF_DIR" "$(dirname "$UNIT_DEST")" "$(dirname "$KWIN_RULES_DEST")"
install -Dm755 "$LAUNCHER_SOURCE" "$LAUNCHER_DEST"
install -Dm755 "$SETTINGS_MANAGER_SOURCE" "$SETTINGS_MANAGER_DEST"
install -Dm644 "$UNIT_SOURCE" "$UNIT_DEST"

python3 - <<'PY' "$KWIN_RULES_SOURCE" "$KWIN_RULES_DEST"
from configparser import RawConfigParser
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
dest_path = Path(sys.argv[2])

source_cfg = RawConfigParser()
source_cfg.optionxform = str
source_cfg.read(source_path)

dest_cfg = RawConfigParser()
dest_cfg.optionxform = str
if dest_path.exists():
    dest_cfg.read(dest_path)

hubstaff_section = None
for section in dest_cfg.sections():
    if dest_cfg.get(section, "description", fallback="") == "Hubstaff Tray Only":
        hubstaff_section = section
        break

if hubstaff_section is None:
    used_numbers = [int(section) for section in dest_cfg.sections() if section.isdigit()]
    hubstaff_section = str(max(used_numbers, default=0) + 1)

if not dest_cfg.has_section(hubstaff_section):
    dest_cfg.add_section(hubstaff_section)

for key, value in source_cfg.items("1"):
    dest_cfg.set(hubstaff_section, key, value)

rules = []
if dest_cfg.has_section("General"):
    rules = [item for item in dest_cfg.get("General", "rules", fallback="").split(",") if item]
else:
    dest_cfg.add_section("General")

if hubstaff_section not in rules:
    rules.append(hubstaff_section)

numeric_sections = [int(section) for section in dest_cfg.sections() if section.isdigit()]
dest_cfg.set("General", "count", str(max(numeric_sections, default=int(hubstaff_section))))
dest_cfg.set("General", "rules", ",".join(rules))

with dest_path.open("w") as handle:
    dest_cfg.write(handle, space_around_delimiters=False)
PY

if [ -f "$DESKTOP_FILE" ]; then
    python3 - <<'PY' "$DESKTOP_FILE" "$LAUNCHER_DEST"
from pathlib import Path
import sys

desktop_path = Path(sys.argv[1])
launcher_path = sys.argv[2]
lines = desktop_path.read_text().splitlines()
updated = []

for line in lines:
    if line.startswith("Exec="):
        updated.append(f'Exec="{launcher_path}" %u')
    else:
        updated.append(line)

desktop_path.write_text("\n".join(updated) + "\n")
PY
else
    log_warn "Hubstaff desktop file not found at $DESKTOP_FILE; leaving launcher registration alone."
fi

systemctl --user daemon-reload >/dev/null 2>&1 || log_warn "Unable to reload user systemd."
systemctl --user enable hubstaff.service >/dev/null 2>&1 || log_warn "Unable to enable hubstaff.service."
if systemctl --user is-active --quiet hubstaff.service; then
    systemctl --user restart --no-block hubstaff.service >/dev/null 2>&1 || log_warn "Unable to restart hubstaff.service."
fi

qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || log_warn "Unable to request live KWin reconfigure."

log_info "Hubstaff integration is restored."
