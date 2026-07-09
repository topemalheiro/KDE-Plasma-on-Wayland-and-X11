#!/bin/bash
# Install a lightweight ChatGPT web-app wrapper for the current user.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
APP_NAME="chatgpt-webapp"
LAUNCHER="$BIN_DIR/$APP_NAME"
DESKTOP_FILE="$APP_DIR/$APP_NAME.desktop"

mkdir -p "$BIN_DIR" "$APP_DIR"

install -Dm755 "$SCRIPT_DIR/chatgpt-webapp.sh" "$LAUNCHER"

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=ChatGPT
Comment=ChatGPT in a lightweight browser app window
Exec=$LAUNCHER %U
Icon=applications-internet
Terminal=false
Categories=Network;Chat;Utility;
StartupNotify=true
StartupWMClass=ChatGPTWebApp
EOF

update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true

echo "$LAUNCHER"
echo "$DESKTOP_FILE"
