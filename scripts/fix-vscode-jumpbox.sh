#!/bin/bash
# Fix the VS Code task-manager jumpbox regression only.
#
# This installs the VS Code jump-list helpers and the two Plasma patches needed
# for compound "Project + Pin/Unpin Project" rows in the task-manager menu.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/package-baseline.sh"

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

usage() {
    cat <<'EOF'
Usage: ./scripts/fix-vscode-jumpbox.sh

Installs the VS Code jump-list integration and rebuilds the reviewed Plasma
6.7.3 libplasma/plasma-desktop patch pair.
EOF
}

run_as_target_user() {
    if [[ $(id -u) -eq $TARGET_UID ]]; then
        env \
            HOME="$TARGET_HOME" \
            USER="$TARGET_USER" \
            LOGNAME="$TARGET_USER" \
            XDG_RUNTIME_DIR="$TARGET_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="$TARGET_DBUS_ADDRESS" \
            "$@"
    else
        sudo -H -u "$TARGET_USER" env \
            HOME="$TARGET_HOME" \
            USER="$TARGET_USER" \
            LOGNAME="$TARGET_USER" \
            XDG_RUNTIME_DIR="$TARGET_RUNTIME_DIR" \
            DBUS_SESSION_BUS_ADDRESS="$TARGET_DBUS_ADDRESS" \
            "$@"
    fi
}

verify_pacman_protection() {
    kde_post_repair_pacman_hold_is_managed || \
        die "The managed libplasma/plasma-desktop hold is missing."
    cmp -s "$SCRIPT_DIR/plasma-package-guard" /usr/local/lib/kde-post-repair/plasma-package-guard || \
        die "The deny-by-default Plasma transaction guard is missing."
    cmp -s "$SCRIPT_DIR/../config/pacman-hooks/95-kde-patched-plasma-guard.hook" \
        /etc/pacman.d/hooks/95-kde-patched-plasma-guard.hook || \
        die "The managed Plasma ALPM hook is missing."
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
    if run_as_target_user systemctl --user is-active --quiet plasma-plasmashell.service; then
        run_as_target_user systemctl --user restart plasma-plasmashell.service || \
            log_warn "Unable to restart Plasma Shell; log out and back in to load the patched plugins."
    fi
}

verify_patched_packages() {
    local libplasma_version plasma_desktop_version
    local libplasma_plugin="/usr/lib/qt6/qml/org/kde/plasma/extras/libplasmaextracomponentsplugin.so"
    local taskmanager_plugin="/usr/lib/qt6/plugins/plasma/applets/org.kde.plasma.taskmanager.so"

    libplasma_version="$(pacman -Q libplasma | awk '{print $2}')"
    plasma_desktop_version="$(pacman -Q plasma-desktop | awk '{print $2}')"

    echo "libplasma $libplasma_version"
    echo "plasma-desktop $plasma_desktop_version"

    [ "$libplasma_version" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ] || \
        die "libplasma is not the reviewed patched version $KDE_POST_REPAIR_PLASMA_PATCHED_VERSION."
    [ "$plasma_desktop_version" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ] || \
        die "plasma-desktop is not the reviewed patched version $KDE_POST_REPAIR_PLASMA_PATCHED_VERSION."

    grep -aFq "secondaryAction" "$libplasma_plugin" || \
        die "Installed libplasma plugin does not expose secondaryAction."
    # Qt AOT-compiles ContextMenu.qml and strips its JavaScript identifiers.
    # The build verifies groupJumpListActions/secondaryAction in the patched
    # source before packaging; here verify that exact patched package version
    # owns a compiled ContextMenu payload rather than looking for stripped
    # source identifiers in the binary.
    grep -aFq "ContextMenu.qml" "$taskmanager_plugin" || \
        die "Installed Plasma task-manager plugin is missing its compiled ContextMenu payload."

    pacman -Qkk libplasma plasma-desktop >/dev/null || die "Installed Plasma packages failed pacman -Qkk verification."
    ldd -r "$libplasma_plugin" >/dev/null || die "Installed libplasma plugin has unresolved dependencies."
    ldd -r "$taskmanager_plugin" >/dev/null || die "Installed task-manager plugin has unresolved dependencies."
}

verify_vscode_integration() {
    local desktop_file="$TARGET_HOME/.local/share/applications/code.desktop"
    local path_unit="$TARGET_HOME/.config/systemd/user/vscode-jumplist-sync.path"
    local service_unit="$TARGET_HOME/.config/systemd/user/vscode-jumplist-sync.service"

    [ -f "$desktop_file" ] || die "Managed VS Code desktop file is missing."
    grep -Eq '^Icon=(vscode|/usr/share/pixmaps/vscode\.png)$' "$desktop_file" || \
        die "Managed VS Code launcher uses neither the vendor vscode icon nor its packaged fallback."
    ! grep -Fxq "Icon=visual-studio-code" "$desktop_file" || \
        die "Managed VS Code launcher still contains the invalid visual-studio-code icon name."
    [ -r /usr/share/pixmaps/vscode.png ] || die "Vendor VS Code fallback icon is missing."

    [ -f "$path_unit" ] || die "VS Code recent-place path unit is missing."
    [ -f "$service_unit" ] || die "VS Code recent-place refresh service is missing."
    grep -Fq ".config/Code/User/globalStorage/storage.json" "$path_unit" || \
        die "VS Code path unit does not watch storage.json."
    run_as_target_user systemctl --user is-enabled --quiet vscode-jumplist-sync.path || \
        die "vscode-jumplist-sync.path is not enabled."
    run_as_target_user systemctl --user is-active --quiet vscode-jumplist-sync.path || \
        die "vscode-jumplist-sync.path is not active."

    [ -f "$TARGET_HOME/.local/share/kwin/scripts/vscode-jumplist-spawner/metadata.json" ] || \
        die "VS Code KWin placement helper is missing."
    [ -f "$TARGET_HOME/.local/share/kwin/scripts/vscode-jumplist-spawner/contents/code/main.js" ] || \
        die "VS Code KWin placement helper code is missing."
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi
    [ "$#" -eq 0 ] || die "This script takes no arguments."

    kde_post_repair_assert_plasma_baseline || \
        die "Installed Plasma does not match the reviewed $KDE_POST_REPAIR_PLASMA_SOURCE_VERSION baseline."
    install_user_helpers
    install_patched_plasma
    verify_pacman_protection
    verify_patched_packages
    verify_vscode_integration
    reload_live_session_best_effort

    log_info "VS Code jumpbox patch is installed. Log out and back in, or reboot."
}

main "$@"
