#!/bin/bash
# Hubstaff launcher wrapper
# - Forces a valid locale to avoid the Hubstaff locale crash
# - Launches directly when Hubstaff native tray-only mode is enabled
# - Falls back to kdocker only when native tray mode is not configured

export LC_ALL=en_US.UTF-8

HUBSTAFF_BIN="$HOME/Hubstaff/HubstaffClient.bin.x86_64"
SETTINGS_FILE="$HOME/.local/share/Hubstaff/settings.json"
KDOCKER_BIN="$HOME/.local/bin/kdocker"

find_hubstaff_window() {
    command -v wmctrl >/dev/null 2>&1 || return 1

    wmctrl -lx 2>/dev/null \
        | awk 'tolower($0) ~ /hubstaff/ { print $1; exit }'
}

focus_hubstaff_window() {
    local window_id

    window_id="$(find_hubstaff_window || true)"
    [ -n "$window_id" ] || return 1

    wmctrl -ia "$window_id" >/dev/null 2>&1
}

native_tray_enabled() {
    local taskbar_behavior
    local close_action

    command -v python3 >/dev/null 2>&1 || return 1
    [ -f "$SETTINGS_FILE" ] || return 1

    taskbar_behavior="$(
        python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); print(d.get('client',{}).get('preferences',{}).get('taskbar_behavior',''))" 2>/dev/null
    )"
    close_action="$(
        python3 -c "import json; d=json.load(open('$SETTINGS_FILE')); print(d.get('client',{}).get('preferences',{}).get('main_window_close_action',''))" 2>/dev/null
    )"

    [ "$taskbar_behavior" = "1" ] && [ "$close_action" = "1" ]
}

if pgrep -x "HubstaffClient.bin.x86_64" >/dev/null 2>&1; then
    focus_hubstaff_window && exit 0
    exec "$HUBSTAFF_BIN" "$@"
fi

if native_tray_enabled; then
    exec "$HUBSTAFF_BIN" "$@"
fi

exec "$KDOCKER_BIN" -o -q -b -r "$HUBSTAFF_BIN" "$@"
