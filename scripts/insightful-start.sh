#!/usr/bin/env bash
# Launch the Insightful (Workpuls) agent.
#
# ELECTRON_RUN_AS_NODE MUST be unset. VS Code sets it in its integrated terminal
# for its own tooling, and it makes any Electron binary run as plain Node --
# the app exits 0 immediately with no window and no error. Launching from a
# VS Code terminal without unsetting it silently does nothing.
unset ELECTRON_RUN_AS_NODE ELECTRON_NO_ATTACH_CONSOLE
export DISPLAY="${DISPLAY:-:0}"
exec "${WORKPULS_APPIMAGE:-$HOME/Downloads/Workpuls.AppImage}" --no-sandbox "$@"
