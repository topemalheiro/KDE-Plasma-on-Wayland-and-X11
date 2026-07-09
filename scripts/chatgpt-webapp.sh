#!/bin/bash
# Launch ChatGPT as a lightweight browser app wrapper.
#
# This keeps the UI current because it opens chatgpt.com directly in a browser
# app window instead of using a frozen native wrapper.

set -euo pipefail

CHATGPT_URL="${CHATGPT_URL:-https://chatgpt.com/}"
APP_DIR="${CHATGPT_APP_DIR:-$HOME/.local/share/chatgpt-webapp}"
PROFILE_DIR="$APP_DIR/profile"
EXTENSION_DIR="${CHATGPT_EXTENSION_DIR:-$APP_DIR/extension}"
mkdir -p "$PROFILE_DIR"

pick_browser() {
    local candidate

    for candidate in \
        chromium \
        chromium-browser \
        microsoft-edge-stable \
        microsoft-edge \
        google-chrome-stable \
        google-chrome
    do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

browser="$(pick_browser)" || {
    echo "No supported Chromium-based browser found (chromium, edge, or chrome)." >&2
    exit 1
}

case "$browser" in
    chromium|chromium-browser)
        exec "$browser" \
            --app="$CHATGPT_URL" \
            --user-data-dir="$PROFILE_DIR" \
            --profile-directory=Default \
            --load-extension="$EXTENSION_DIR" \
            --new-window \
            "$@"
        ;;
    microsoft-edge-stable|microsoft-edge)
        exec "$browser" \
            --app="$CHATGPT_URL" \
            --user-data-dir="$PROFILE_DIR" \
            --profile-directory=Default \
            --load-extension="$EXTENSION_DIR" \
            --new-window \
            "$@"
        ;;
    google-chrome-stable|google-chrome)
        exec "$browser" \
            --app="$CHATGPT_URL" \
            --user-data-dir="$PROFILE_DIR" \
            --profile-directory=Default \
            --load-extension="$EXTENSION_DIR" \
            --new-window \
            "$@"
        ;;
esac
