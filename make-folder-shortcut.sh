#!/bin/bash
# make-folder-shortcut.sh — Create a KDE folder shortcut (.desktop Type=Link)
#
# Type=Link is used rather than a symlink because Dolphin opens a symlink at the
# symlink's own path (~/Desktop/Name) instead of the target — see
# KDE-Customization-TODO.md item #2. A Type=Link entry navigates to the real path.
#
# The link badge and folder-colour support for these files come from the
# plasma-desktop patches in patches/ (folder-link-emblem, folder-color-links),
# applied by scripts/build-patched-plasma-packages.sh.
#
# Usage: ./make-folder-shortcut.sh <folder-path> [shortcut-name]
#
# Examples:
#   ./make-folder-shortcut.sh ~/Projects/MyProject
#   ./make-folder-shortcut.sh ~/Projects/MyProject "My Project"
#   ./make-folder-shortcut.sh /mnt/data/Backups Backups

set -euo pipefail

FOLDER_PATH="${1:-}"
SHORTCUT_NAME="${2:-}"

if [ -z "$FOLDER_PATH" ]; then
    echo "Usage: $0 <folder-path> [shortcut-name]" >&2
    echo "  Creates ~/Desktop/<name>.desktop pointing at <folder-path>." >&2
    exit 1
fi

FOLDER_PATH="$(realpath -m "$FOLDER_PATH")"
[ -n "$SHORTCUT_NAME" ] || SHORTCUT_NAME="$(basename "$FOLDER_PATH")"

# Only '/' and NUL are actually illegal in a filename. The old version ran
# `tr -cd '[:alnum:]_-'`, which turned "C VS C++" into "C_VS_C" and
# "Proj.&Role Pitches" into "ProjRole_Pitches" — the file no longer matched
# its own visible label. Keep the name; strip only what the filesystem rejects.
FILENAME="$(printf '%s' "$SHORTCUT_NAME" | tr -d '\000' | tr '/' '-')"
OUTPUT="$HOME/Desktop/$FILENAME.desktop"

# FORCE=1 skips both prompts, for callers such as
# scripts/convert-symlinks-to-desktop.sh. Piping `yes` into this script is not a
# substitute: `yes` then dies of SIGPIPE and, under `set -o pipefail`, aborts the
# caller mid-way.
FORCE="${FORCE:-0}"

if [ ! -d "$FOLDER_PATH" ]; then
    if [ "$FORCE" = "1" ]; then
        mkdir -p "$FOLDER_PATH"
    else
        echo "Warning: folder does not exist yet: $FOLDER_PATH" >&2
        read -r -p "Create it? [y/N] " reply
        case "$reply" in
            [Yy]*) mkdir -p "$FOLDER_PATH" ;;
            *) echo "Cancelled." >&2; exit 1 ;;
        esac
    fi
fi

if [ -e "$OUTPUT" ] && [ "$FORCE" != "1" ]; then
    read -r -p "$OUTPUT already exists. Overwrite? [y/N] " reply
    case "$reply" in
        [Yy]*) ;;
        *) echo "Cancelled." >&2; exit 1 ;;
    esac
fi

# Prefer $HOME-relative so the entry survives a different home path. The [$e]
# suffix is the KConfig flag that makes KDE expand shell variables in the value.
#
# NOTE the QUOTED heredoc below. With an unquoted one the shell expands "$e"
# (undefined) to nothing and the file ends up with a useless `URL[]=` key —
# that was the long-standing bug in this script, and desktop-shortcuts-guide.md
# had the correct quoted form all along.
if [ "${FOLDER_PATH#"$HOME"/}" != "$FOLDER_PATH" ]; then
    URL_VALUE="file:\$HOME/${FOLDER_PATH#"$HOME"/}"
else
    URL_VALUE="file:$FOLDER_PATH"
fi

mkdir -p "$HOME/Desktop"
{
    cat <<'EOF'
[Desktop Entry]
Icon=folder
Type=Link
EOF
    printf 'Name=%s\n' "$SHORTCUT_NAME"
    printf 'URL[$e]=%s\n' "$URL_VALUE"
} > "$OUTPUT"

# KDE refuses to trust a user-owned .desktop launcher without the executable bit.
chmod +x "$OUTPUT"

echo "Created: $OUTPUT"
echo "  -> $FOLDER_PATH"
