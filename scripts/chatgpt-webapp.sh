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
WINDOW_CLASS="${CHATGPT_WINDOW_CLASS:-chatgpt.com.ChatGPTWebApp}"
SUPERVISOR_SCRIPT="$APP_DIR/chatgpt-webapp-tray.py"
SUPERVISOR_PID_FILE="$APP_DIR/tray-supervisor.pid"
SUPERVISOR_LOG_FILE="$APP_DIR/tray-supervisor.log"

INTERNAL_BROWSER_MODE=false
if [ "${1:-}" = "--internal-browser" ]; then
    INTERNAL_BROWSER_MODE=true
    shift
fi

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
            | awk -v window_class="$WINDOW_CLASS" '
                $3 == window_class || tolower($0) ~ /chatgptwebapp/ || $0 ~ /ChatGPT/ {
                    print $1
                    exit
                }
            '
    )"
    [ -n "$window_id" ] || return 1

    wmctrl -ia "$window_id" >/dev/null 2>&1
}

find_chatgpt_window() {
    command -v wmctrl >/dev/null 2>&1 || return 1

    wmctrl -lx 2>/dev/null \
        | awk -v window_class="$WINDOW_CLASS" '
            $3 == window_class || tolower($0) ~ /chatgptwebapp/ || $0 ~ /ChatGPT/ {
                print $1
                exit
            }
        '
}

wait_for_chatgpt_window() {
    local attempt
    local window_id

    for attempt in $(seq 1 40); do
        window_id="$(find_chatgpt_window || true)"
        if [ -n "$window_id" ]; then
            printf '%s\n' "$window_id"
            return 0
        fi
        sleep 0.5
    done

    return 1
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

launch_browser_background() {
    local browser

    browser="$(pick_browser)" || {
        echo "No supported Chromium-based browser found (chromium, edge, or chrome)." >&2
        exit 1
    }

    case "$browser" in
        chromium|chromium-browser|microsoft-edge-stable|microsoft-edge|google-chrome-stable|google-chrome)
            "$browser" \
                --app="$CHATGPT_URL" \
                --user-data-dir="$PROFILE_DIR" \
                --profile-directory=Default \
                --load-extension="$EXTENSION_DIR" \
                --class=ChatGPTWebApp \
                --ozone-platform=x11 \
                --new-window \
                "$@" \
                >/dev/null 2>&1 &
            ;;
    esac
}

supervisor_pid() {
    [ -f "$SUPERVISOR_PID_FILE" ] || return 1

    local pid
    pid="$(tr -d '[:space:]' < "$SUPERVISOR_PID_FILE")"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" >/dev/null 2>&1 || return 1

    printf '%s\n' "$pid"
}

signal_supervisor() {
    local pid

    pid="$(supervisor_pid)" || return 1
    kill -USR1 "$pid" >/dev/null 2>&1
}

start_supervisor() {
    local child_pid
    local _attempt

    command -v python3 >/dev/null 2>&1 || return 1
    [ -f "$SUPERVISOR_SCRIPT" ] || return 1

    mkdir -p "$APP_DIR"

    nohup setsid python3 "$SUPERVISOR_SCRIPT" >"$SUPERVISOR_LOG_FILE" 2>&1 < /dev/null &
    child_pid=$!

    for _attempt in $(seq 1 20); do
        if supervisor_pid >/dev/null; then
            return 0
        fi

        if ! kill -0 "$child_pid" >/dev/null 2>&1; then
            return 1
        fi

        sleep 0.25
    done

    supervisor_pid >/dev/null
}

if [ "$INTERNAL_BROWSER_MODE" = true ]; then
    launch_browser "$@"
fi

if signal_supervisor; then
    exit 0
fi

if start_supervisor; then
    exit 0
fi

focus_existing_window && exit 0

if command -v kdocker >/dev/null 2>&1 && [ -f "$ICON_FILE" ]; then
    launch_browser_background "$@"

    window_id="$(wait_for_chatgpt_window || true)"
    if [ -n "${window_id:-}" ]; then
        exec kdocker \
            -q \
            -b \
            --no-iconify-docking \
            -w "$window_id" \
            -i "$ICON_FILE" \
            -I "$ICON_FILE"
    fi
fi

launch_browser "$@"
