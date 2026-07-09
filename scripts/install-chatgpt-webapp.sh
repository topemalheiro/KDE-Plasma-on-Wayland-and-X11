#!/bin/bash
# Install a lightweight ChatGPT web-app wrapper for the current user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
WEBAPP_DIR="$HOME/.local/share/chatgpt-webapp"
ICON_ROOT="$HOME/.local/share/icons/hicolor"
APP_NAME="chatgpt-webapp"
LAUNCHER="$BIN_DIR/$APP_NAME"
DESKTOP_FILE="$APP_DIR/$APP_NAME.desktop"
EXTENSION_DEST="$WEBAPP_DIR/extension"
FAVICON_DB="$WEBAPP_DIR/profile/Default/Favicons"
ICON_256="$ICON_ROOT/256x256/apps/$APP_NAME.png"
OLD_APPIMAGE="$HOME/.local/opt/chatgpt-desktop/ChatGPT.AppImage"
OLD_LAUNCHER="$BIN_DIR/chatgpt-desktop"
OLD_DESKTOP_FILE="$APP_DIR/chatgpt-desktop.desktop"

log_warn() { echo "[WARN] $1" >&2; }

install_chatgpt_icon() {
    local icon_hex
    local tmp_png

    if [ ! -f "$FAVICON_DB" ]; then
        log_warn "Cached ChatGPT favicon database not found: $FAVICON_DB"
        return
    fi

    tmp_png="$(mktemp --suffix=.png)"

    icon_hex="$(
        sqlite3 "$FAVICON_DB" "
            select hex(favicon_bitmaps.image_data)
            from favicons
            join favicon_bitmaps on favicons.id = favicon_bitmaps.icon_id
            where favicons.url = 'https://chatgpt.com/favicon.ico'
            order by favicon_bitmaps.width desc
            limit 1;
        " 2>/dev/null || true
    )"

    if [ -z "$icon_hex" ]; then
        log_warn "No cached ChatGPT favicon found yet. Open ChatGPT once, then rerun this installer."
        rm -f "$tmp_png"
        return
    fi

    printf '%s' "$icon_hex" | xxd -r -p > "$tmp_png"
    [ -s "$tmp_png" ] || {
        log_warn "Cached ChatGPT favicon extraction produced an empty icon."
        rm -f "$tmp_png"
        return
    }

    mkdir -p \
        "$ICON_ROOT/16x16/apps" \
        "$ICON_ROOT/32x32/apps" \
        "$ICON_ROOT/256x256/apps" \
        "$ICON_ROOT/scalable/apps"

    magick "$tmp_png" -resize 16x16 "$ICON_ROOT/16x16/apps/$APP_NAME.png"
    magick "$tmp_png" -resize 32x32 "$ICON_ROOT/32x32/apps/$APP_NAME.png"
    magick "$tmp_png" -resize 256x256 "$ICON_ROOT/256x256/apps/$APP_NAME.png"
    rm -f "$ICON_ROOT/scalable/apps/$APP_NAME.svg"
    rm -f "$tmp_png"
}

disable_stale_appimage_launcher() {
    local resolved_launcher

    [ -f "$OLD_DESKTOP_FILE" ] || return
    [ -L "$OLD_LAUNCHER" ] || return

    resolved_launcher="$(readlink -f "$OLD_LAUNCHER")"
    [ "$resolved_launcher" = "$OLD_APPIMAGE" ] || return
    grep -Fq "Exec=$OLD_LAUNCHER %U" "$OLD_DESKTOP_FILE" || return

    grep -q '^NoDisplay=true$' "$OLD_DESKTOP_FILE" || printf '\nNoDisplay=true\n' >> "$OLD_DESKTOP_FILE"
    grep -q '^Hidden=true$' "$OLD_DESKTOP_FILE" || printf 'Hidden=true\n' >> "$OLD_DESKTOP_FILE"
}

mkdir -p "$BIN_DIR" "$APP_DIR" "$EXTENSION_DEST"

install -Dm755 "$SCRIPT_DIR/chatgpt-webapp.sh" "$LAUNCHER"
cp -R "$SCRIPT_DIR/chatgpt-webapp-extension"/. "$EXTENSION_DEST"/
install_chatgpt_icon

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=ChatGPT
Comment=ChatGPT in a lightweight browser app window
Exec=$LAUNCHER
Icon=$ICON_256
Terminal=false
Categories=Network;Chat;Utility;
StartupNotify=true
StartupWMClass=ChatGPTWebApp
EOF

disable_stale_appimage_launcher

update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
gtk-update-icon-cache -q "$ICON_ROOT" >/dev/null 2>&1 || true
kbuildsycoca6 --noincremental >/dev/null 2>&1 || true

echo "$LAUNCHER"
echo "$DESKTOP_FILE"
