#!/bin/bash
# repair-desktop-shortcuts.sh — Audit and fix ~/Desktop Type=Link shortcuts.
#
# The shortcuts on this desktop were produced by four generations of tooling
# (make-folder-shortcut.sh, convert-symlinks-to-desktop.sh, the KDE Properties
# dialog, and hand editing), so they disagree on format. This normalises them.
#
# Fixes:
#   * a URL with no scheme at all (URL[$e]=$HOME/... -> file:$HOME/...), which
#     KIO cannot resolve
#   * missing executable bit, without which KDE refuses to trust the launcher
#   * leftover symlinks to directories, which Dolphin opens at the symlink's own
#     path instead of the target (KDE-Customization-TODO.md item #2)
#
# Usage: ./repair-desktop-shortcuts.sh [--apply]      (default: dry run)

set -euo pipefail

DESKTOP="${DESKTOP_DIR:-$HOME/Desktop}"
APPLY=false
[ "${1:-}" = "--apply" ] && APPLY=true

fixed=0
note() { printf '  %s\n' "$1"; }
act()  { if [ "$APPLY" = true ]; then "$@"; fi; fixed=$((fixed + 1)); }

echo "Scanning $DESKTOP ..."
[ "$APPLY" = true ] || echo "(dry run — pass --apply to make changes)"
echo

shopt -s nullglob
for f in "$DESKTOP"/*.desktop; do
    name="$(basename "$f")"
    issues=()

    url_line="$(grep -m1 -E '^URL(\[\$e\])?=' "$f" 2>/dev/null || true)"
    if [ -n "$url_line" ]; then
        value="${url_line#*=}"
        # A scheme-less value: no "file:" and no other "scheme:" prefix.
        if [[ "$value" != file:* && "$value" != *://* && "$value" != [a-zA-Z]*:* ]]; then
            issues+=("no URL scheme -> prefixing file:")
            act sed -i -E "s|^(URL(\[\\\$e\])?=)(.*)$|\1file:\3|" "$f"
        fi
    fi

    if [ ! -x "$f" ]; then
        issues+=("not executable -> chmod +x")
        act chmod +x "$f"
    fi

    if [ "${#issues[@]}" -gt 0 ]; then
        echo "$name"
        for i in "${issues[@]}"; do note "$i"; done
    fi
done

for l in "$DESKTOP"/*; do
    [ -L "$l" ] || continue
    target="$(readlink -f "$l" || true)"
    [ -d "$target" ] || continue

    base="$(basename "$l")"
    echo "$base"

    # KDE's "Create New -> Link to Location (URL)" names the symlink after the
    # URL you typed, substituting U+2044 FRACTION SLASH for '/'. That yields
    # names like "file:<U+2044><U+2044><U+2044>home<U+2044>tope<U+2044>...".
    # Rename those to the target's basename.
    if printf '%s' "$base" | grep -qE '^[a-zA-Z][a-zA-Z0-9+.-]*:|⁄'; then
        want="$(basename "$target")"
        if [ -n "$want" ] && [ ! -e "$DESKTOP/$want" ]; then
            note "URL-shaped name -> renaming to \"$want\""
            act mv -T -- "$l" "$DESKTOP/$want"
            l="$DESKTOP/$want"
        else
            note "URL-shaped name, but \"$want\" already exists -- rename by hand"
        fi
    fi

    note "symlink to a directory -> opens at the symlink path, not \"$target\""
    note "(fixed natively once the folder-view patches are installed)"
done

echo
if [ "$fixed" -eq 0 ]; then
    echo "Nothing to repair."
elif [ "$APPLY" = true ]; then
    echo "Repaired $fixed issue(s)."
else
    echo "$fixed issue(s) would be repaired. Re-run with --apply."
fi
