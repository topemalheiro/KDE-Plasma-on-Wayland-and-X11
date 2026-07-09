#!/bin/bash
# VS Code jump-list launcher.
# Writes pending virtual-desktop placement metadata before opening a folder.

set -euo pipefail

PROJECT_PATH="${1:-}"
LAYOUT_MAP="$HOME/.config/vscode-jumplist/layout-map.json"
PENDING_PLACEMENT="$HOME/.config/vscode-jumplist/pending-placement.json"

if [ -z "$PROJECT_PATH" ]; then
    echo "Usage: $0 <project-path> [code args...]" >&2
    exit 1
fi

mkdir -p "$(dirname "$PENDING_PLACEMENT")"

# Resolve the project path to absolute.
ABS_PATH="$(realpath "$PROJECT_PATH" 2>/dev/null || echo "$PROJECT_PATH")"

if [ -f "$LAYOUT_MAP" ]; then
    DESKTOP="$(python3 - <<'PY' "$LAYOUT_MAP" "$ABS_PATH"
import json
import sys
from pathlib import Path

layout_map_path = Path(sys.argv[1])
project_path = Path(sys.argv[2])

try:
    mapping = json.loads(layout_map_path.read_text())
except Exception:
    print("")
    raise SystemExit

current = project_path
while True:
    entry = mapping.get(str(current))
    if entry and entry.get("desktop"):
        print(entry["desktop"])
        raise SystemExit
    if current == current.parent:
        break
    current = current.parent

print("")
PY
)"

    if [ -n "$DESKTOP" ]; then
        cat > "$PENDING_PLACEMENT" <<EOF
{
  "project": "$ABS_PATH",
  "desktop": $DESKTOP,
  "timestamp": $(date +%s)000
}
EOF
    fi
fi

/usr/bin/code "$@"
