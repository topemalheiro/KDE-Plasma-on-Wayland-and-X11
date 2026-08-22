#!/bin/bash
# convert-symlinks-to-desktop.sh — Replace ~/Desktop symlinks-to-folders with
# .desktop Type=Link entries, so Dolphin opens the TARGET path rather than the
# symlink's own path (KDE-Customization-TODO.md item #2).
#
# Delegates to make-folder-shortcut.sh so there is exactly one place that knows
# the file format. The old inline heredoc here wrote a third, incompatible
# variant (URL=file://<raw path>, unencoded spaces).
#
# Reversible: scripts/revert-desktop-to-symlinks.sh restores the symlinks.
#
# Usage: ./convert-symlinks-to-desktop.sh [--apply]      (default: dry run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAKER="$REPO_ROOT/make-folder-shortcut.sh"
DESKTOP="${DESKTOP_DIR:-$HOME/Desktop}"

APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true
[ -x "$MAKER" ] || { echo "Not found: $MAKER" >&2; exit 1; }

count=0
shopt -s nullglob
for link in "$DESKTOP"/*; do
    [ -L "$link" ] || continue
    target="$(readlink -f "$link" || true)"
    [ -d "$target" ] || continue

    name="$(basename "$link")"
    echo "$name -> $target"
    count=$((count + 1))

    if [ "$APPLY" = true ]; then
        # Write the replacement BEFORE removing the symlink, so a failure here
        # cannot lose the shortcut. The old version rm'd first.
        FORCE=1 "$MAKER" "$target" "$name" >/dev/null </dev/null
        [ -f "$DESKTOP/$name.desktop" ] || { echo "  failed to create replacement; symlink left intact" >&2; continue; }
        rm -- "$link"
        echo "  created $name.desktop"
    fi
done

echo
if [ "$count" -eq 0 ]; then
    echo "No symlinks-to-folders on the desktop."
elif [ "$APPLY" = true ]; then
    echo "Converted $count symlink(s). Revert with scripts/revert-desktop-to-symlinks.sh."
else
    echo "$count symlink(s) would be converted. Re-run with --apply."
fi
