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
ICON_FILE="${CHATGPT_ICON_FILE:-$HOME/.local/share/icons/hicolor/32x32/apps/chatgpt-webapp.png}"
WINDOW_PATTERN="${CHATGPT_WINDOW_PATTERN:-^ChatGPT($|[[:space:]-])}"
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

focus_existing_window() {
    local window_id

    command -v wmctrl >/dev/null 2>&1 || return 1

    window_id="$(
        wmctrl -lx 2>/dev/null \
            | awk 'tolower($0) ~ /chatgptwebapp/ || $0 ~ /ChatGPT/ { print $1; exit }'
    )"
    [ -n "$window_id" ] || return 1

    wmctrl -ia "$window_id" >/dev/null 2>&1
}

launch_browser() {
    local browser

    browser="$(pick_browser)" || {
        echo "No supported Chromium-based browser found (chromium, edge, or chrome)." >&2
        exit 1
    }

    case "$browser" in
        chromium|chromium-browser|microsoft-edge-stable|microsoft-edge|google-chrome-stable|google-chrome)
            exec "$browser" \
                --app="$CHATGPT_URL" \
                --user-data-dir="$PROFILE_DIR" \
                --profile-directory=Default \
                --load-extension="$EXTENSION_DIR" \
                --class=ChatGPTWebApp \
                --ozone-platform=x11 \
                --new-window \
                "$@"
            ;;
    esac
}

if [ "${CHATGPT_WEBAPP_INTERNAL:-}" = "1" ]; then
    launch_browser "$@"
fi

focus_existing_window && exit 0

if command -v kdocker >/dev/null 2>&1 && [ -f "$ICON_FILE" ]; then
    exec env CHATGPT_WEBAPP_INTERNAL=1 kdocker \
        -q \
        -b \
        --no-iconify-docking \
        -d 30 \
        -n "$WINDOW_PATTERN" \
        -i "$ICON_FILE" \
        -I "$ICON_FILE" \
        "$0"
fi

CHATGPT_WEBAPP_INTERNAL=1 launch_browser "$@"
