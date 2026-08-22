#!/bin/bash
# revert-desktop-to-symlinks.sh — Undo convert-symlinks-to-desktop.sh.
#
# KDE-Customization-TODO.md item #2 noted "There is no automatic reversal
# script"; this is it. Turns each ~/Desktop Type=Link .desktop entry that points
# at a local directory back into a plain symlink.
#
# Note the tradeoff you are reverting into: a symlink gets the link badge and
# the folder-colour menu natively, but Dolphin will show the symlink's own path
# (~/Desktop/Name) instead of the target. The plasma-desktop patches in patches/
# give the .desktop form all three, so prefer those unless you are deliberately
# backing the patches out.
#
# Usage: ./revert-desktop-to-symlinks.sh [--apply]      (default: dry run)

set -euo pipefail

DESKTOP="${DESKTOP_DIR:-$HOME/Desktop}"
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

count=0
shopt -s nullglob
for f in "$DESKTOP"/*.desktop; do
    grep -q '^Type=Link' "$f" || continue

    value="$(grep -m1 -E '^URL(\[\$e\])?=' "$f" | cut -d= -f2- || true)"
    [ -n "$value" ] || continue
    value="${value#file://}"; value="${value#file:}"
    # Expand $HOME / ${HOME} written by the [$e] form.
    value="${value//\$\{HOME\}/$HOME}"; value="${value//\$HOME/$HOME}"
    [ -d "$value" ] || continue

    name="$(basename "$f" .desktop)"
    echo "$name.desktop -> symlink to $value"
    count=$((count + 1))

    if [ "$APPLY" = true ]; then
        ln -sfn -- "$value" "$DESKTOP/$name.tmplink" && mv -T -- "$DESKTOP/$name.tmplink" "$DESKTOP/$name"
        rm -- "$f"
        echo "  created symlink $name"
    fi
done

echo
if [ "$count" -eq 0 ]; then
    echo "No convertible Type=Link shortcuts found."
elif [ "$APPLY" = true ]; then
    echo "Reverted $count shortcut(s) to symlinks."
else
    echo "$count shortcut(s) would be reverted. Re-run with --apply."
fi
