#!/usr/bin/env bash
# Launch the Insightful (Workpuls) agent.
#
# ELECTRON_RUN_AS_NODE MUST be unset. VS Code sets it in its integrated terminal
# for its own tooling, and it makes any Electron binary run as plain Node --
# the app exits 0 immediately with no window and no error. Launching from a
# VS Code terminal without unsetting it silently does nothing.
unset ELECTRON_RUN_AS_NODE ELECTRON_NO_ATTACH_CONSOLE
export DISPLAY="${DISPLAY:-:0}"

# Bring the tray icon proxy up with the agent. It only autostarts at login, so
# without this, launching Insightful from the menu after the proxy had exited
# left the agent with no visible icon. Starting it again is harmless: systemd
# keeps a single instance, and the proxy hides itself while the agent is gone.
PROXY_UNIT='app-insightful\x2dtray\x2dproxy@autostart.service'
if ! systemctl --user start "$PROXY_UNIT" 2>/dev/null; then
    pgrep -f insightful-tray-proxy.py >/dev/null ||
        setsid -f "$HOME/.local/bin/insightful-tray-proxy.py" >/dev/null 2>&1
fi
exec "${WORKPULS_APPIMAGE:-$HOME/Downloads/Workpuls.AppImage}" --no-sandbox "$@"
