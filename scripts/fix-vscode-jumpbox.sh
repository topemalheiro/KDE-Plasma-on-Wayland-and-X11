#!/bin/bash
# Fix the VS Code task-manager jumpbox regression only.
#
# This installs the VS Code jump-list helpers and the two Plasma patches needed
# for compound "Project + Pin/Unpin Project" rows in the task-manager menu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-${USER}}}"
TARGET_HOME="${TARGET_HOME:-$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_RUNTIME_DIR="/run/user/$TARGET_UID"
TARGET_DBUS_ADDRESS="unix:path=$TARGET_RUNTIME_DIR/bus"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err() { echo "[ERROR] $1"; }

die() {
    log_err "$1"
    exit 1
}

rerun_as_root_if_needed() {
    if [[ $EUID -eq 0 ]]; then
        return
    fi

    exec sudo env TARGET_USER="$TARGET_USER" TARGET_HOME="$TARGET_HOME" bash "$0" "$@"
}

run_as_target_user() {
    sudo -H -u "$TARGET_USER" env \
        HOME="$TARGET_HOME" \
        USER="$TARGET_USER" \
        LOGNAME="$TARGET_USER" \
        XDG_RUNTIME_DIR="$TARGET_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$TARGET_DBUS_ADDRESS" \
        "$@"
}

ensure_pacman_hold() {
    log_info "Putting Plasma package hold in pacman.conf [options] ..."
    python3 - <<'PY'
from pathlib import Path
import re

pacman_conf = Path("/etc/pacman.conf")
start_marker = "# >>> KDE post-repair holds >>>"
end_marker = "# <<< KDE post-repair holds <<<"
block = """# >>> KDE post-repair holds >>>
IgnorePkg = libplasma plasma-desktop
# <<< KDE post-repair holds <<<
"""

content = pacman_conf.read_text()
content = re.sub(
    rf"\n?{re.escape(start_marker)}\n.*?{re.escape(end_marker)}\n?",
    "\n",
    content,
    flags=re.DOTALL,
)

match = re.search(r"^\[options\]\n", content, flags=re.MULTILINE)
if not match:
    raise SystemExit("Could not find [options] section in /etc/pacman.conf")

content = content[:match.end()] + block + "\n" + content[match.end():]
pacman_conf.write_text(content)
PY
}

install_user_helpers() {
    log_info "Installing VS Code jump-list user helpers for $TARGET_USER ..."
    run_as_target_user bash "$SCRIPT_DIR/install-servicemenu.sh"
    run_as_target_user bash "$SCRIPT_DIR/install-vscode-jumplist-integration.sh"
    run_as_target_user "$TARGET_HOME/.local/bin/code-jumplist-manager" refresh >/dev/null 2>&1 || true
}

install_patched_plasma() {
    log_info "Building and installing patched libplasma + plasma-desktop ..."
    env TARGET_USER="$TARGET_USER" TARGET_HOME="$TARGET_HOME" \
        bash "$SCRIPT_DIR/build-patched-plasma-packages.sh" --apply
}

reload_live_session_best_effort() {
    run_as_target_user kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    run_as_target_user qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
}

verify_patched_packages() {
    local libplasma_version plasma_desktop_version

    libplasma_version="$(pacman -Q libplasma | awk '{print $2}')"
    plasma_desktop_version="$(pacman -Q plasma-desktop | awk '{print $2}')"

    echo "libplasma $libplasma_version"
    echo "plasma-desktop $plasma_desktop_version"

    [[ "$libplasma_version" == *-1.1 ]] || die "libplasma is not patched."
    [[ "$plasma_desktop_version" == *-1.1 ]] || die "plasma-desktop is not patched."

    grep -a -q "secondaryAction" /usr/lib/qt6/qml/org/kde/plasma/extras/libplasmaextracomponentsplugin.so || \
        die "Installed libplasma plugin does not expose secondaryAction."

    pacman -Qkk libplasma plasma-desktop >/dev/null || die "Installed Plasma packages failed pacman -Qkk verification."
}

main() {
    rerun_as_root_if_needed "$@"
    install_user_helpers
    install_patched_plasma
    ensure_pacman_hold
    reload_live_session_best_effort
    verify_patched_packages

    log_info "VS Code jumpbox patch is installed. Log out and back in, or reboot."
}

main "$@"
