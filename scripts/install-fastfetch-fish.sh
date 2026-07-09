#!/bin/bash
# Restore the Fish-only fastfetch styling and ensure interactive shells source it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FASTFETCH_SOURCE="$REPO_ROOT/config/fish/functions/fastfetch.fish"
FASTFETCH_DEST="$HOME/.config/fish/functions/fastfetch.fish"
FISH_CONFIG="$HOME/.config/fish/config.fish"

log_info() { echo "[INFO] $1"; }

mkdir -p "$(dirname "$FASTFETCH_DEST")" "$(dirname "$FISH_CONFIG")"
install -Dm644 "$FASTFETCH_SOURCE" "$FASTFETCH_DEST"

python3 - <<'PY' "$FISH_CONFIG"
from pathlib import Path
import re
import sys

config_path = Path(sys.argv[1])
start_marker = "# >>> KDE post-repair fastfetch >>>"
end_marker = "# <<< KDE post-repair fastfetch <<<"
snippet = """# >>> KDE post-repair fastfetch >>>
if status is-interactive
    set -l managed_fastfetch "$HOME/.config/fish/functions/fastfetch.fish"
    if test -f "$managed_fastfetch"
        if functions -q fastfetch
            functions -e fastfetch
        end
        source "$managed_fastfetch"
    end
end
# <<< KDE post-repair fastfetch <<<
"""

if config_path.exists():
    content = config_path.read_text()
else:
    content = ""

pattern = re.compile(
    re.escape(start_marker) + r".*?" + re.escape(end_marker) + r"\n?",
    re.DOTALL,
)
content = re.sub(pattern, "", content)

if content and not content.endswith("\n"):
    content += "\n"

content += snippet
config_path.write_text(content)
PY

log_info "Fish fastfetch styling is restored."
