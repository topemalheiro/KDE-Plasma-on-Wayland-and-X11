#!/bin/bash
# install-servicemenu.sh — Install the "Open with VS Code:" Dolphin right-click menu
# Usage: ./install-servicemenu.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_FILE="$SCRIPT_DIR/open-with-code.desktop"
C_SOURCE="$SCRIPT_DIR/open-with-code.c"
WRAPPER_SOURCE="$SCRIPT_DIR/open-with-code-wrapper.sh"
JUMPLIST_SOURCE="$SCRIPT_DIR/code-jumplist-manager.py"
CODE_OPEN_FOLDER_SOURCE="$SCRIPT_DIR/code-open-folder.sh"
INSTALL_DIR="$HOME/.local/share/kio/servicemenus"
BIN_DIR="$HOME/.local/bin"
BINARY="$BIN_DIR/open-with-code"
WRAPPER="$BIN_DIR/open-with-code-wrapper"
JUMPLIST="$BIN_DIR/code-jumplist-manager"
CODE_OPEN_FOLDER="$BIN_DIR/code-open-folder"

echo "=== Installing Open with VS Code: servicemenu ==="

# Create directories
mkdir -p "$INSTALL_DIR"
mkdir -p "$BIN_DIR"

# Compile the helper binary
echo "Compiling open-with-code binary..."
gcc -O2 -o "$BINARY" "$C_SOURCE"
chmod +x "$BINARY"
echo "  → $BINARY"

# Install wrapper script
echo "Installing wrapper script..."
cp "$WRAPPER_SOURCE" "$WRAPPER"
chmod +x "$WRAPPER"
echo "  → $WRAPPER"

# Install jumplist manager
echo "Installing jumplist manager..."
cp "$JUMPLIST_SOURCE" "$JUMPLIST"
chmod +x "$JUMPLIST"
echo "  → $JUMPLIST"

# Install jump-list launcher wrapper
echo "Installing code-open-folder launcher..."
cp "$CODE_OPEN_FOLDER_SOURCE" "$CODE_OPEN_FOLDER"
chmod +x "$CODE_OPEN_FOLDER"
echo "  → $CODE_OPEN_FOLDER"

# Install the desktop file with executable bit (required by KDE security policy)
echo "Installing servicemenu desktop file..."
cp "$DESKTOP_FILE" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/open-with-code.desktop"
echo "  → $INSTALL_DIR/open-with-code.desktop"

# Refresh KDE service cache
if command -v kbuildsycoca6 >/dev/null 2>&1; then
    echo "Refreshing KDE service cache..."
    kbuildsycoca6 --noincremental
else
    echo "Warning: kbuildsycoca6 not found. You may need to relogin for changes to take effect."
fi

if [ -x "$JUMPLIST" ]; then
    "$JUMPLIST" refresh >/dev/null 2>&1 || true
fi

echo ""
echo "✅ Installation complete."
echo "   Right-click any folder in Dolphin to see 'Open with VS Code:'."
echo "   If Dolphin is already running, restart it: killall dolphin"
