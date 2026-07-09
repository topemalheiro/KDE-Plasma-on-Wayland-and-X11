#!/bin/bash
# Install the VS Code jump-list launcher and KWin placement script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN_DIR="$HOME/.local/bin"
KWIN_SCRIPTS_DIR="$HOME/.local/share/kwin/scripts"
KWIN_SCRIPT_NAME="vscode-jumplist-spawner"
KWIN_SCRIPT_SOURCE="$SCRIPT_DIR/$KWIN_SCRIPT_NAME"
KWIN_SCRIPT_DEST="$KWIN_SCRIPTS_DIR/$KWIN_SCRIPT_NAME"
LAYOUT_MAP_SOURCE="$REPO_ROOT/config/vscode-jumplist/layout-map.json"
LAYOUT_MAP_DEST="$HOME/.config/vscode-jumplist/layout-map.json"
CODE_OPEN_FOLDER_SOURCE="$SCRIPT_DIR/code-open-folder.sh"
CODE_OPEN_FOLDER_DEST="$BIN_DIR/code-open-folder"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }

log_info "Installing VS Code jump-list helpers ..."

mkdir -p "$BIN_DIR" "$KWIN_SCRIPTS_DIR" "$(dirname "$LAYOUT_MAP_DEST")"

install -Dm755 "$CODE_OPEN_FOLDER_SOURCE" "$CODE_OPEN_FOLDER_DEST"
rm -rf "$KWIN_SCRIPT_DEST"
mkdir -p "$KWIN_SCRIPT_DEST"
cp -R "$KWIN_SCRIPT_SOURCE"/. "$KWIN_SCRIPT_DEST"/

if [ ! -f "$LAYOUT_MAP_DEST" ] && [ -f "$LAYOUT_MAP_SOURCE" ]; then
    install -Dm644 "$LAYOUT_MAP_SOURCE" "$LAYOUT_MAP_DEST"
fi

if kpackagetool6 --type KWin/Script --show "$KWIN_SCRIPT_NAME" >/dev/null 2>&1; then
    kpackagetool6 --type KWin/Script --upgrade "$KWIN_SCRIPT_SOURCE" >/dev/null 2>&1 || \
        log_warn "kpackagetool6 could not refresh $KWIN_SCRIPT_NAME; using the local script copy."
else
    kpackagetool6 --type KWin/Script --install "$KWIN_SCRIPT_SOURCE" >/dev/null 2>&1 || \
        log_warn "kpackagetool6 could not register $KWIN_SCRIPT_NAME; using the local script copy."
fi

kwriteconfig6 --file kwinrc --group Plugins --key "${KWIN_SCRIPT_NAME}Enabled" true
qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || log_warn "Unable to request live KWin reconfigure."

log_info "VS Code jump-list KWin integration is installed."
