#!/bin/bash
# Launch ChatGPT as a lightweight browser app wrapper.
#
# This keeps the UI current because it opens chatgpt.com directly in a browser
# app window instead of using a frozen native wrapper.

set -euo pipefail

# RTKit 0.14 can impose a realtime runtime limit that kills long-lived audio
# capture clients on this system. PipeWire supports this opt-out natively.
export DISABLE_RTKIT="${DISABLE_RTKIT:-1}"

CHATGPT_URL="${CHATGPT_URL:-https://chatgpt.com/}"
APP_DIR="${CHATGPT_APP_DIR:-$HOME/.local/share/chatgpt-webapp}"
EXTENSION_DIR="${CHATGPT_EXTENSION_DIR:-$APP_DIR/extension}"
ICON_FILE="${CHATGPT_ICON_FILE:-$HOME/.local/share/icons/hicolor/32x32/apps/chatgpt-webapp.png}"
WINDOW_PATTERN="${CHATGPT_WINDOW_PATTERN:-^ChatGPT($|[[:space:]-])}"
WINDOW_CLASS="${CHATGPT_WINDOW_CLASS:-chatgpt.com.ChatGPTWebApp}"
SUPERVISOR_SCRIPT="$APP_DIR/chatgpt-webapp-tray.py"
SUPERVISOR_PID_FILE="$APP_DIR/tray-supervisor.pid"
SUPERVISOR_LOG_FILE="$APP_DIR/tray-supervisor.log"
BROWSER_REALTIME_ARGS=(
    # KDocker can make the app window occluded while a voice session remains
    # active. Keep Chromium from throttling the page's WebRTC timers/renderer.
    --disable-background-timer-throttling
    --disable-backgrounding-occluded-windows
    --disable-renderer-backgrounding
)

INTERNAL_BROWSER_MODE=false
if [ "${1:-}" = "--internal-browser" ]; then
    INTERNAL_BROWSER_MODE=true
    shift
fi

mkdir -p "$APP_DIR"

pick_browser() {
    local candidate

    if [ -n "${CHATGPT_BROWSER:-}" ]; then
        command -v "$CHATGPT_BROWSER" >/dev/null 2>&1 || {
            echo "Configured CHATGPT_BROWSER was not found: $CHATGPT_BROWSER" >&2
            return 1
        }
        printf '%s\n' "$CHATGPT_BROWSER"
        return 0
    fi

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

browser_profile_dir() {
    local browser_name="${1##*/}"

    case "$browser_name" in
        chromium|chromium-browser)
            printf '%s\n' "$APP_DIR/profile-chromium"
            ;;
        microsoft-edge-stable|microsoft-edge)
            printf '%s\n' "$APP_DIR/profile-edge"
            ;;
        google-chrome-stable|google-chrome)
            printf '%s\n' "$APP_DIR/profile-chrome"
            ;;
        *)
            echo "Unsupported Chromium-based browser: $1" >&2
            return 1
            ;;
    esac
}

focus_existing_window() {
    local window_id

    command -v wmctrl >/dev/null 2>&1 || return 1

    window_id="$(
        wmctrl -lx 2>/dev/null \
            | awk -v window_class="$WINDOW_CLASS" '
                $3 == window_class || tolower($3) ~ /chatgptwebapp/ {
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
            $3 == window_class || tolower($3) ~ /chatgptwebapp/ {
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
    local profile_dir

    browser="$(pick_browser)" || {
        echo "No supported Chromium-based browser found (chromium, edge, or chrome)." >&2
        exit 1
    }
    profile_dir="$(browser_profile_dir "$browser")"
    mkdir -p "$profile_dir"

    case "$browser" in
        chromium|chromium-browser|microsoft-edge-stable|microsoft-edge|google-chrome-stable|google-chrome)
            exec "$browser" \
                --app="$CHATGPT_URL" \
                --user-data-dir="$profile_dir" \
                --profile-directory=Default \
                --disable-extensions-except="$EXTENSION_DIR" \
                --load-extension="$EXTENSION_DIR" \
                --class=ChatGPTWebApp \
                --ozone-platform=x11 \
                "${BROWSER_REALTIME_ARGS[@]}" \
                --new-window \
                "$@"
            ;;
    esac
}

launch_browser_background() {
    local browser
    local profile_dir

    browser="$(pick_browser)" || {
        echo "No supported Chromium-based browser found (chromium, edge, or chrome)." >&2
        exit 1
    }
    profile_dir="$(browser_profile_dir "$browser")"
    mkdir -p "$profile_dir"

    case "$browser" in
        chromium|chromium-browser|microsoft-edge-stable|microsoft-edge|google-chrome-stable|google-chrome)
            "$browser" \
                --app="$CHATGPT_URL" \
                --user-data-dir="$profile_dir" \
                --profile-directory=Default \
                --disable-extensions-except="$EXTENSION_DIR" \
                --load-extension="$EXTENSION_DIR" \
                --class=ChatGPTWebApp \
                --ozone-platform=x11 \
                "${BROWSER_REALTIME_ARGS[@]}" \
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
