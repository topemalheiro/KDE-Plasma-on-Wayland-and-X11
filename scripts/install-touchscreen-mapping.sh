#!/bin/bash
# Install the event-driven touchscreen -> output mapping daemon.
#
# Replaces ~/.config/autostart/fix-touchscreen-mapping.desktop, which only ran
# at login and so was defeated by the first USB hub bounce (the monitors cut
# their built-in hubs when the displays sleep, dozens of times a session).
#
# The daemon runs from this checkout rather than ~/.local/bin, because that
# directory is a separate git repo (bin.git) that the reinstall scripts never
# clone -- which is the real reason the old fix did not survive a reinstall.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DAEMON="$SCRIPT_DIR/touchscreen-mapping-daemon.py"
UNIT_SOURCE="$REPO_ROOT/config/systemd/user/touchscreen-mapping.service"
UNIT_DEST="$HOME/.config/systemd/user/touchscreen-mapping.service"
CONF_SOURCE="$REPO_ROOT/config/touchscreen-mapping/mapping.json"
CONF_DEST="$HOME/.config/touchscreen-mapping/mapping.json"

OLD_AUTOSTART="$HOME/.config/autostart/fix-touchscreen-mapping.desktop"
OLD_SCRIPT="$HOME/.local/bin/fix-touchscreen-mapping.sh"
DISABLED_DIR="$HOME/.config/autostart-disabled"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }

# --- dependencies --------------------------------------------------------
missing=()
python3 -c "import dbus, dbus.mainloop.glib" 2>/dev/null || missing+=(python-dbus)
python3 -c "from gi.repository import GLib" 2>/dev/null || missing+=(python-gobject)
if [ ${#missing[@]} -gt 0 ]; then
    log_warn "Installing missing dependencies: ${missing[*]}"
    sudo pacman -S --needed --noconfirm "${missing[@]}"
fi

# --- install -------------------------------------------------------------
chmod 755 "$DAEMON"
install -Dm644 "$UNIT_SOURCE" "$UNIT_DEST"

# Never clobber a mapping the user has tuned.
if [ -f "$CONF_DEST" ]; then
    log_info "Keeping existing $CONF_DEST (reference copy: $CONF_SOURCE)."
else
    install -Dm644 "$CONF_SOURCE" "$CONF_DEST"
    log_info "Installed default mapping to $CONF_DEST."
fi

# --- retire the old one-shot fix ----------------------------------------
if [ -f "$OLD_AUTOSTART" ]; then
    mkdir -p "$DISABLED_DIR"
    mv "$OLD_AUTOSTART" "$DISABLED_DIR/$(basename "$OLD_AUTOSTART")"
    log_info "Retired old autostart entry to $DISABLED_DIR."
    # The generated unit only exists for the current session; stop it so the
    # old script cannot race the daemon before the next login.
    systemctl --user stop 'app-fix\x2dtouchscreen\x2dmapping@autostart.service' 2>/dev/null || true
fi

if [ -f "$OLD_SCRIPT" ]; then
    log_warn "$OLD_SCRIPT is now unused but still tracked in bin.git."
    log_warn "  Remove it when convenient:  git -C ~/.local/bin rm fix-touchscreen-mapping.sh"
fi

# --- activate ------------------------------------------------------------
systemctl --user daemon-reload
systemctl --user enable --now touchscreen-mapping.service

sleep 2
if "$DAEMON" --status; then
    log_info "Touchscreen mapping daemon installed and both panels are correct."
else
    log_warn "Mapping is not fully correct yet."
    log_warn "  Check: journalctl --user -u touchscreen-mapping -n 30"
fi
