#!/bin/bash
# Install the VS Code jump-list, automatic recent sync, and KWin placement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BIN_DIR="$HOME/.local/bin"
APPLICATIONS_DIR="$HOME/.local/share/applications"
SERVICE_MENU_DIR="$HOME/.local/share/kio/servicemenus"
KWIN_SCRIPTS_DIR="$HOME/.local/share/kwin/scripts"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
KWIN_SCRIPT_NAME="vscode-jumplist-spawner"
KWIN_SCRIPT_SOURCE="$SCRIPT_DIR/$KWIN_SCRIPT_NAME"
KWIN_SCRIPT_DEST="$KWIN_SCRIPTS_DIR/$KWIN_SCRIPT_NAME"
LAYOUT_MAP_SOURCE="$REPO_ROOT/config/vscode-jumplist/layout-map.json"
LAYOUT_MAP_DEST="$HOME/.config/vscode-jumplist/layout-map.json"
CODE_OPEN_FOLDER_SOURCE="$SCRIPT_DIR/code-open-folder.sh"
CODE_OPEN_FOLDER_DEST="$BIN_DIR/code-open-folder"
JUMPLIST_SOURCE="$SCRIPT_DIR/code-jumplist-manager.py"
JUMPLIST_DEST="$BIN_DIR/code-jumplist-manager"
SERVICE_MENU_SOURCE="$SCRIPT_DIR/open-with-code.desktop"
SERVICE_MENU_DEST="$SERVICE_MENU_DIR/open-with-code.desktop"
OPEN_WITH_CODE_SOURCE="$SCRIPT_DIR/open-with-code.c"
OPEN_WITH_CODE_DEST="$BIN_DIR/open-with-code"
OPEN_WITH_CODE_WRAPPER_SOURCE="$SCRIPT_DIR/open-with-code-wrapper.sh"
OPEN_WITH_CODE_WRAPPER_DEST="$BIN_DIR/open-with-code-wrapper"
WATCH_SERVICE_SOURCE="$REPO_ROOT/config/systemd/user/vscode-jumplist-sync.service"
WATCH_PATH_SOURCE="$REPO_ROOT/config/systemd/user/vscode-jumplist-sync.path"
WATCH_SERVICE_DEST="$SYSTEMD_USER_DIR/vscode-jumplist-sync.service"
WATCH_PATH_DEST="$SYSTEMD_USER_DIR/vscode-jumplist-sync.path"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }

install_if_changed() {
    local mode="$1"
    local source="$2"
    local destination="$3"

    mkdir -p "$(dirname "$destination")"
    if [ -f "$destination" ] && cmp -s "$source" "$destination"; then
        chmod "$mode" "$destination"
        return 1
    fi

    install -m "$mode" "$source" "$destination"
    return 0
}

log_info "Installing VS Code jump-list helpers ..."

mkdir -p \
    "$BIN_DIR" \
    "$APPLICATIONS_DIR" \
    "$SERVICE_MENU_DIR" \
    "$KWIN_SCRIPTS_DIR" \
    "$SYSTEMD_USER_DIR" \
    "$(dirname "$LAYOUT_MAP_DEST")"

install -m755 "$CODE_OPEN_FOLDER_SOURCE" "$CODE_OPEN_FOLDER_DEST"
install -m755 "$JUMPLIST_SOURCE" "$JUMPLIST_DEST"
install -m755 "$OPEN_WITH_CODE_WRAPPER_SOURCE" "$OPEN_WITH_CODE_WRAPPER_DEST"

open_with_code_build=""
service_menu_build=""
trap 'rm -f "$open_with_code_build" "$service_menu_build"' EXIT
open_with_code_build="$(mktemp)"
gcc -O2 -o "$open_with_code_build" "$OPEN_WITH_CODE_SOURCE"
install -m755 "$open_with_code_build" "$OPEN_WITH_CODE_DEST"

# Prefer the icon name from VS Code's vendor desktop file.  On packages that
# omit it, write the packaged pixmap's absolute path into the installed copy.
service_menu_build="$(mktemp)"
service_menu_icon=""
for vendor_desktop in \
    /usr/share/applications/code.desktop \
    /usr/share/applications/visual-studio-code.desktop; do
    [ -f "$vendor_desktop" ] || continue
    candidate_icon="$(awk '
        /^\[Desktop Entry\]$/ { in_entry = 1; next }
        /^\[/ { if (in_entry) exit; in_entry = 0 }
        in_entry && /^Icon=/ { sub(/^Icon=/, ""); print; exit }
    ' "$vendor_desktop")"
    [ -n "$candidate_icon" ] || continue

    if [[ "$candidate_icon" = /* ]]; then
        [ -f "$candidate_icon" ] && service_menu_icon="$candidate_icon"
    elif command -v kiconfinder6 >/dev/null 2>&1 && \
            [ -f "$(kiconfinder6 "$candidate_icon" 2>/dev/null)" ]; then
        service_menu_icon="$candidate_icon"
    fi

    [ -z "$service_menu_icon" ] || break
done

if [ -z "$service_menu_icon" ] && [ -f /usr/share/pixmaps/vscode.png ]; then
    service_menu_icon="/usr/share/pixmaps/vscode.png"
fi
service_menu_icon="${service_menu_icon:-vscode}"
awk -v icon="$service_menu_icon" '
    /^Icon=vscode$/ { print "Icon=" icon; next }
    { print }
' "$SERVICE_MENU_SOURCE" > "$service_menu_build"

service_menu_changed=false
if install_if_changed 755 "$service_menu_build" "$SERVICE_MENU_DEST"; then
    service_menu_changed=true
fi

install -m644 "$WATCH_SERVICE_SOURCE" "$WATCH_SERVICE_DEST"
install -m644 "$WATCH_PATH_SOURCE" "$WATCH_PATH_DEST"

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

log_info "Generating the VS Code launcher and initial Recent Places list ..."
desktop_identity_before="$(stat -c '%d:%i' "$APPLICATIONS_DIR/code.desktop" 2>/dev/null || true)"
"$JUMPLIST_DEST" refresh
desktop_identity_after="$(stat -c '%d:%i' "$APPLICATIONS_DIR/code.desktop" 2>/dev/null || true)"

# The manager refreshes KDE synchronously when code.desktop changes.  If only
# the Dolphin service menu changed, perform the one required cache refresh here.
if "$service_menu_changed" && [ "$desktop_identity_before" = "$desktop_identity_after" ]; then
    if command -v kbuildsycoca6 >/dev/null 2>&1; then
        kbuildsycoca6 --noincremental >/dev/null
    else
        log_warn "kbuildsycoca6 is unavailable; Dolphin will refresh its menu later."
    fi
fi

log_info "Enabling automatic VS Code recent-project synchronization ..."
systemctl --user daemon-reload
systemctl --user enable --now vscode-jumplist-sync.path
systemctl --user start vscode-jumplist-sync.service

log_info "VS Code jump-list KWin integration is installed."
