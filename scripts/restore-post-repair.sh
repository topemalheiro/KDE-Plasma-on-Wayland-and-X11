#!/bin/bash
# Restore the repo-defined workstation baseline after a repair or broken update.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/package-baseline.sh"

MODE=""
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_RUNTIME_DIR="/run/user/$TARGET_UID"
TARGET_DBUS_ADDRESS="unix:path=$TARGET_RUNTIME_DIR/bus"
LIBPLASMA_PLUGIN="/usr/lib/qt6/qml/org/kde/plasma/extras/libplasmaextracomponentsplugin.so"
TASKMANAGER_PLUGIN="/usr/lib/qt6/plugins/plasma/applets/org.kde.plasma.taskmanager.so"
VSCODE_DESKTOP_FILE="$TARGET_HOME/.local/share/applications/code.desktop"
VSCODE_WATCH_PATH_UNIT="vscode-jumplist-sync.path"
VSCODE_WATCH_SERVICE_UNIT="vscode-jumplist-sync.service"
VOXTYPE_CORE_MODEL="$TARGET_HOME/.local/share/voxtype/models/ggml-base.en.bin"
VOXTYPE_TURBO_MODEL="$TARGET_HOME/.local/share/voxtype/models/ggml-large-v3-turbo.bin"
VOXTYPE_WAKE_MODEL="$TARGET_HOME/.local/share/voxtype-ptt-tray/models/vosk-model-small-en-us-0.15"
VOXTYPE_SHORTCUT_DESKTOP="$TARGET_HOME/.local/share/applications/voxtype-toggle.desktop"
WHATSIE_CONFIG="$TARGET_HOME/.var/app/com.ktechpit.whatsie/config/org.keshavnrj.ubuntu/WhatSie.conf"
WHATSIE_AUTOSTART="$TARGET_HOME/.config/autostart/com.ktechpit.whatsie.desktop"
WHATSIE_SERVICE="whatsie-tray.service"
PLASMA_GUARD_HOOK="/etc/pacman.d/hooks/95-kde-patched-plasma-guard.hook"
PLASMA_GUARD_EXEC="/usr/local/lib/kde-post-repair/plasma-package-guard"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err() { echo "[ERROR] $1"; }

die() {
    log_err "$1"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./scripts/restore-post-repair.sh --audit-only
  ./scripts/restore-post-repair.sh --apply

Options:
  --audit-only  Report missing packages, broken launchers, and restore state.
  --apply       Install and repair the reproducible repo-defined baseline.
EOF
}

parse_args() {
    if [ $# -ne 1 ]; then
        usage
        exit 1
    fi

    case "$1" in
        --audit-only)
            MODE="audit"
            ;;
        --apply)
            MODE="apply"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
}

require_sudo_access() {
    if ! sudo -n true >/dev/null 2>&1; then
        die "sudo access is required for --apply. Run this script from an interactive terminal with sudo privileges."
    fi
}

run_as_target_user() {
    if [ "$(id -u)" -eq "$TARGET_UID" ]; then
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

collect_missing_packages() {
    kde_post_repair_missing_packages
}

collect_missing_managed_components() {
    local path
    local managed_paths=(
        "$TARGET_HOME/.local/bin/code-jumplist-manager"
        "$TARGET_HOME/.local/bin/code-open-folder"
        "$VSCODE_DESKTOP_FILE"
        "$TARGET_HOME/.local/share/kio/servicemenus/open-with-code.desktop"
        "$TARGET_HOME/.local/share/kwin/scripts/vscode-jumplist-spawner/metadata.json"
        "$TARGET_HOME/.local/share/kwin/scripts/vscode-jumplist-spawner/contents/code/main.js"
        "$TARGET_HOME/.config/vscode-jumplist/layout-map.json"
        "$TARGET_HOME/.config/systemd/user/$VSCODE_WATCH_PATH_UNIT"
        "$TARGET_HOME/.config/systemd/user/$VSCODE_WATCH_SERVICE_UNIT"
        "$TARGET_HOME/.config/voxtype/config.toml"
        "$TARGET_HOME/.local/share/voxtype-ptt-tray/voxtype-ptt-tray.py"
        "$TARGET_HOME/.local/share/applications/voxtype-ptt-tray.desktop"
        "$VOXTYPE_SHORTCUT_DESKTOP"
        "$TARGET_HOME/.config/systemd/user/voxtype-ptt-tray.service"
        "$TARGET_HOME/.local/bin/whatsie-flatpak-x11"
        "$TARGET_HOME/.local/bin/whatsie-tray-launcher"
        "$TARGET_HOME/.local/bin/whatsie-open"
        "$TARGET_HOME/.local/bin/whatsie-theme-guard"
        "$TARGET_HOME/.config/systemd/user/$WHATSIE_SERVICE"
        "$WHATSIE_AUTOSTART"
        "$TARGET_HOME/.config/fish/functions/fastfetch.fish"
        "$TARGET_HOME/.config/systemd/user/hubstaff.service"
        "$TARGET_HOME/Hubstaff/hubstaff-launcher.sh"
    )

    for path in "${managed_paths[@]}"; do
        if [ ! -e "$path" ]; then
            printf '%s\n' "$path"
        fi
    done
}

collect_missing_voxtype_packages() {
    local package_name

    for package_name in "${KDE_POST_REPAIR_VOXTYPE_PACKAGES[@]}"; do
        pacman -Qq "$package_name" >/dev/null 2>&1 || printf '%s\n' "$package_name"
    done
}

collect_broken_launchers() {
    HOME="$TARGET_HOME" python3 - <<'PY'
from pathlib import Path
import os
import shlex
import shutil

desktop_dirs = [
    ("applications", Path.home() / ".local/share/applications"),
    ("autostart", Path.home() / ".config/autostart"),
]


def extract_exec(path: Path) -> str | None:
    in_desktop_entry = False
    for raw_line in path.read_text(errors="ignore").splitlines():
        line = raw_line.strip()
        if line.startswith("[") and line.endswith("]"):
            in_desktop_entry = line == "[Desktop Entry]"
            continue
        if in_desktop_entry and line.startswith("Exec="):
            return line.split("=", 1)[1]
    return None


def resolve_command(exec_line: str) -> tuple[str, str]:
    tokens = shlex.split(exec_line, posix=True)
    if not tokens:
        return ("", "empty Exec")

    idx = 0
    if tokens[0] == "env":
        idx = 1

    while idx < len(tokens) and "=" in tokens[idx] and not tokens[idx].startswith(("/", ".", "~")):
        idx += 1

    if idx >= len(tokens):
        return ("", "missing executable")

    command = os.path.expandvars(os.path.expanduser(tokens[idx]))
    if "/" in command:
        return (command, "path")
    return (command, "command")


for category, directory in desktop_dirs:
    if not directory.exists():
        continue

    for desktop_file in sorted(directory.glob("*.desktop")):
        exec_line = extract_exec(desktop_file)
        if not exec_line:
            continue

        command, command_type = resolve_command(exec_line)
        if not command:
            print(f"{desktop_file}\t{category}\tMISSING\t{exec_line}")
            continue

        if command_type == "path":
            if not Path(command).exists():
                print(f"{desktop_file}\t{category}\t{command}\t{exec_line}")
        elif shutil.which(command) is None:
            print(f"{desktop_file}\t{category}\t{command}\t{exec_line}")
PY
}

collect_stale_disabled_autostarts() {
    find "$TARGET_HOME/.config/autostart" -maxdepth 1 -type f -name '*.desktop.disabled' 2>/dev/null | sort || true
}

plasma_versions_match_baseline() {
    kde_post_repair_assert_plasma_baseline >/dev/null 2>&1
}

plasma_packages_are_patched() {
    [ "$(pacman -Q libplasma 2>/dev/null | awk '{print $2}')" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ] && \
        [ "$(pacman -Q plasma-desktop 2>/dev/null | awk '{print $2}')" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ]
}

libplasma_is_patched() {
    [ -f "$LIBPLASMA_PLUGIN" ] && grep -aFq "secondaryAction" "$LIBPLASMA_PLUGIN"
}

plasma_desktop_is_patched() {
    # Plasma 6.7 compiles ContextMenu.qml into this package-owned plugin; the
    # old /usr/share/plasma/.../ContextMenu.qml path no longer exists. Qt's
    # AOT compiler also strips JavaScript helper/property identifiers, so the
    # reviewed -1.1 package version plus its compiled ContextMenu payload is
    # the durable installed-state check.
    [ "$(pacman -Q plasma-desktop 2>/dev/null | awk '{print $2}')" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ] && \
        [ -f "$TASKMANAGER_PLUGIN" ] && \
        grep -aFq "ContextMenu.qml" "$TASKMANAGER_PLUGIN"
}

plasma_plugins_link_cleanly() {
    [ -f "$LIBPLASMA_PLUGIN" ] && [ -f "$TASKMANAGER_PLUGIN" ] && \
        ldd -r "$LIBPLASMA_PLUGIN" >/dev/null 2>&1 && \
        ldd -r "$TASKMANAGER_PLUGIN" >/dev/null 2>&1
}

plasma_desktop_folder_view_is_patched() {
    local delegate="/usr/share/plasma/plasmoids/org.kde.desktopcontainment/contents/ui/FolderItemDelegate.qml"
    [ -f "$delegate" ] && rg -q "linkEmblem" "$delegate" 2>/dev/null
}

# The folder-view work used to survive only as hand-built files copied into
# ~/.local. They are not on Qt6's QML import path, so they silently do nothing
# while looking installed -- which is how the regression went unnoticed. Flag
# them so they get removed once the packaged build carries the patches.
stale_folder_view_overrides() {
    local o
    for o in \
        "$TARGET_HOME/.local/lib/qt6/qml/org/kde/private/desktopcontainment/folder/libfolderplugin.so" \
        "$TARGET_HOME/.local/share/plasma/plasmoids/org.kde.desktopcontainment"; do
        [ -e "$o" ] && printf '%s\n' "$o"
    done
    return 0
}

pacman_holds_are_present() {
    kde_post_repair_pacman_hold_is_managed
}

plasma_transaction_guard_is_managed() {
    [ -x "$PLASMA_GUARD_EXEC" ] && [ -f "$PLASMA_GUARD_HOOK" ] && \
        cmp -s "$REPO_ROOT/scripts/plasma-package-guard" "$PLASMA_GUARD_EXEC" && \
        cmp -s "$REPO_ROOT/config/pacman-hooks/95-kde-patched-plasma-guard.hook" "$PLASMA_GUARD_HOOK"
}

vscode_launcher_icon_is_correct() {
    [ -f "$VSCODE_DESKTOP_FILE" ] && \
        grep -Eq '^Icon=(vscode|/usr/share/pixmaps/vscode\.png)$' "$VSCODE_DESKTOP_FILE" && \
        ! grep -Fxq "Icon=visual-studio-code" "$VSCODE_DESKTOP_FILE" && \
        [ -r /usr/share/pixmaps/vscode.png ]
}

vscode_watch_path_is_healthy() {
    local unit_file="$TARGET_HOME/.config/systemd/user/$VSCODE_WATCH_PATH_UNIT"
    local service_file="$TARGET_HOME/.config/systemd/user/$VSCODE_WATCH_SERVICE_UNIT"

    [ -f "$unit_file" ] && [ -f "$service_file" ] && \
        grep -Fq ".config/Code/User/globalStorage/storage.json" "$unit_file" && \
        run_as_target_user systemctl --user is-enabled --quiet "$VSCODE_WATCH_PATH_UNIT" && \
        run_as_target_user systemctl --user is-active --quiet "$VSCODE_WATCH_PATH_UNIT"
}

vscode_kwin_helper_is_enabled() {
    [ -f "$TARGET_HOME/.local/share/kwin/scripts/vscode-jumplist-spawner/metadata.json" ] && \
        [ -f "$TARGET_HOME/.local/share/kwin/scripts/vscode-jumplist-spawner/contents/code/main.js" ] && \
        [ "$(run_as_target_user kreadconfig6 --file kwinrc --group Plugins --key vscode-jumplist-spawnerEnabled 2>/dev/null || true)" = "true" ]
}

voxtype_version_is_supported() {
    local version
    version="$(pacman -Q voxtype-bin 2>/dev/null | awk '{print $2}')"
    [[ "$version" = 0.7.5 || "$version" = 0.7.5-* ]]
}

voxtype_models_are_present() {
    [ -s "$VOXTYPE_CORE_MODEL" ] && \
        [ -s "$VOXTYPE_TURBO_MODEL" ] && \
        [ -d "$VOXTYPE_WAKE_MODEL" ] && \
        [ -n "$(find "$VOXTYPE_WAKE_MODEL" -type f -print -quit 2>/dev/null)" ]
}

voxtype_services_are_healthy() {
    run_as_target_user systemctl --user is-enabled --quiet voxtype.service && \
        run_as_target_user systemctl --user is-active --quiet voxtype.service && \
        run_as_target_user systemctl --user is-enabled --quiet voxtype-ptt-tray.service && \
        run_as_target_user systemctl --user is-active --quiet voxtype-ptt-tray.service
}

voxtype_shortcut_is_configured() {
    [ -f "$VOXTYPE_SHORTCUT_DESKTOP" ] && \
        grep -Fxq 'Exec=/usr/bin/voxtype record toggle' "$VOXTYPE_SHORTCUT_DESKTOP" && \
        grep -Fxq 'X-KDE-Shortcuts=Shift+Alt' "$VOXTYPE_SHORTCUT_DESKTOP" && \
        grep -Eq '^model[[:space:]]*=[[:space:]]*"large-v3-turbo"[[:space:]]*$' "$TARGET_HOME/.config/voxtype/config.toml"
}

voxtype_legacy_autostarts_are_absent() {
    [ ! -e "$TARGET_HOME/.config/autostart/voxtype-live.desktop" ] && \
        [ ! -e "$TARGET_HOME/.config/autostart/voxtype-meta-alt.desktop" ] && \
        [ ! -e "$TARGET_HOME/.config/systemd/user/voxtype-live.service" ]
}

whatsie_theme_guard_is_healthy() {
    run_as_target_user flatpak info com.ktechpit.whatsie >/dev/null 2>&1 && \
        [ -f "$WHATSIE_CONFIG" ] && \
        grep -Fxq 'windowTheme=dark' "$WHATSIE_CONFIG" && \
        grep -Fxq 'automaticTheme=false' "$WHATSIE_CONFIG" && \
        [ -f "$WHATSIE_AUTOSTART" ] && \
        grep -Fxq 'Hidden=true' "$WHATSIE_AUTOSTART" && \
        run_as_target_user systemctl --user is-enabled --quiet "$WHATSIE_SERVICE" && \
        run_as_target_user systemctl --user is-active --quiet "$WHATSIE_SERVICE"
}

kwin_custom_build_stamp_present() {
    [ -f /var/lib/kde-post-repair/kwin-build-info.json ]
}

fastfetch_config_is_managed() {
    rg -Fq "# >>> KDE post-repair fastfetch >>>" "$TARGET_HOME/.config/fish/config.fish" 2>/dev/null
}

user_failed_services() {
    run_as_target_user systemctl --user --failed --no-legend --plain 2>/dev/null || true
}

print_audit_report() {
    local missing_packages missing_components missing_voxtype_packages
    local broken_launchers stale_disabled_autostarts failed_services

    missing_packages="$(collect_missing_packages || true)"
    missing_components="$(collect_missing_managed_components || true)"
    missing_voxtype_packages="$(collect_missing_voxtype_packages || true)"
    broken_launchers="$(collect_broken_launchers || true)"
    stale_disabled_autostarts="$(collect_stale_disabled_autostarts || true)"
    failed_services="$(user_failed_services || true)"

    echo "== Package Baseline =="
    if [ -n "$missing_packages" ]; then
        printf '%s\n' "$missing_packages"
    else
        echo "All baseline packages are installed."
    fi
    echo

    echo "== Plasma Patch State =="
    pacman -Q libplasma plasma-desktop 2>/dev/null || true
    if plasma_versions_match_baseline; then
        echo "baseline: compatible with $KDE_POST_REPAIR_PLASMA_SOURCE_VERSION"
    else
        echo "baseline: MISMATCH; apply/build will refuse to continue"
    fi
    if plasma_packages_are_patched; then
        echo "package versions: reviewed patched pair"
    else
        echo "package versions: not the patched $KDE_POST_REPAIR_PLASMA_PATCHED_VERSION pair"
    fi
    if libplasma_is_patched; then
        echo "libplasma plugin: secondaryAction present"
    else
        echo "libplasma plugin: missing secondaryAction"
    fi
    if plasma_desktop_is_patched; then
        echo "task-manager plugin: grouped jump-list row present"
    else
        echo "task-manager plugin: missing grouped jump-list row"
    fi
    if plasma_plugins_link_cleanly; then
        echo "plugin linkage: clean"
    else
        echo "plugin linkage: unresolved or missing plugin"
    fi
    if pacman -Qkk libplasma plasma-desktop >/dev/null 2>&1; then
        echo "package file integrity: clean"
    else
        echo "package file integrity: failed"
    fi
    if plasma_desktop_folder_view_is_patched; then
        echo "plasma-desktop folder view: patched (link badge + folder colour on shortcuts)"
    else
        echo "plasma-desktop folder view: MISSING link-badge/folder-colour patches"
        echo "  -> rebuild: sudo ./scripts/build-patched-plasma-packages.sh --apply"
    fi
    local stale_overrides
    stale_overrides="$(stale_folder_view_overrides)"
    if [ -n "$stale_overrides" ]; then
        echo "stale hand-built folder-view overrides present (inert; remove them):"
        printf '  %s\n' $stale_overrides
    fi
    if pacman_holds_are_present; then
        echo "pacman holds: managed block active"
    else
        echo "pacman holds: managed block missing or malformed"
    fi
    if plasma_transaction_guard_is_managed; then
        echo "transaction guard: managed deny-by-default hook active"
    else
        echo "transaction guard: missing or unmanaged"
    fi
    echo

    echo "== VS Code Taskbar Integration =="
    if vscode_launcher_icon_is_correct; then
        echo "launcher icon: vendor vscode icon or packaged fallback"
    else
        echo "launcher icon: incorrect or vendor fallback missing"
    fi
    if vscode_watch_path_is_healthy; then
        echo "recent-place watcher: enabled, active, and watching storage.json"
    else
        echo "recent-place watcher: missing, inactive, or misconfigured"
    fi
    if vscode_kwin_helper_is_enabled; then
        echo "KWin placement helper: installed and enabled"
    else
        echo "KWin placement helper: missing or disabled"
    fi
    echo

    echo "== VoxType PTT Tray =="
    if [ -n "$missing_voxtype_packages" ]; then
        echo "missing packages:"
        printf '%s\n' "$missing_voxtype_packages"
    else
        echo "packages: installed"
    fi
    if command -v voxtype >/dev/null 2>&1 && voxtype_version_is_supported; then
        echo "voxtype: stable 0.7.5"
    else
        echo "voxtype: missing or not stable 0.7.5"
    fi
    if voxtype_models_are_present; then
        echo "models: base.en, large-v3-turbo, and pinned Vosk wake model present"
    else
        echo "models: base.en, large-v3-turbo, or pinned Vosk wake model missing"
    fi
    if voxtype_services_are_healthy; then
        echo "services: core and PTT tray enabled and active"
    else
        echo "services: core or PTT tray missing, disabled, or inactive"
    fi
    if voxtype_shortcut_is_configured; then
        echo "shortcut: Shift+Alt toggle with large-v3-turbo selected"
    else
        echo "shortcut: Shift+Alt toggle missing or large-v3-turbo not selected"
    fi
    if voxtype_legacy_autostarts_are_absent; then
        echo "legacy autostarts: absent"
    else
        echo "legacy autostarts: old live or Meta/Alt integration remains"
    fi
    echo

    echo "== WhatSie Theme Guard =="
    if whatsie_theme_guard_is_healthy; then
        echo "dark theme: persisted; ordered tray service enabled and active"
    else
        echo "dark theme: guard missing, inactive, or misconfigured"
    fi
    echo

    echo "== Custom KWin State =="
    if kwin_custom_build_stamp_present; then
        echo "custom KWin rebuild: recorded"
    else
        echo "custom KWin rebuild: not recorded"
    fi
    pacman -Qkk kwin 2>/dev/null || true
    echo

    echo "== Managed Home Integrations =="
    if [ -n "$missing_components" ]; then
        printf '%s\n' "$missing_components"
    else
        echo "All tracked managed components are present."
    fi
    echo

    echo "== Fastfetch =="
    if [ -f "$TARGET_HOME/.config/fish/functions/fastfetch.fish" ]; then
        echo "fish function: present"
    else
        echo "fish function: missing"
    fi
    if fastfetch_config_is_managed; then
        echo "config.fish sanity path: present"
    else
        echo "config.fish sanity path: missing"
    fi
    echo

    echo "== Broken Launchers =="
    if [ -n "$broken_launchers" ]; then
        printf '%s\n' "$broken_launchers"
    else
        echo "No broken .desktop launchers detected."
    fi
    echo

    echo "== Stale Disabled Autostarts =="
    if [ -n "$stale_disabled_autostarts" ]; then
        printf '%s\n' "$stale_disabled_autostarts"
    else
        echo "No stale *.desktop.disabled files remain in ~/.config/autostart."
    fi
    echo

    echo "== User Service Failures =="
    if [ -n "$failed_services" ]; then
        printf '%s\n' "$failed_services"
    else
        echo "No failed user units."
    fi
}

install_missing_packages() {
    mapfile -t missing_packages < <(collect_missing_packages)
    if [ "${#missing_packages[@]}" -eq 0 ]; then
        log_info "Baseline packages already installed."
        return
    fi

    log_info "Installing missing baseline packages ..."
    sudo pacman -S --needed --noconfirm "${missing_packages[@]}"
}

run_setup_user_env() {
    log_info "Reapplying repo-managed user environment state ..."
    if ! run_as_target_user "$SCRIPT_DIR/setup-user-env.sh"; then
        log_warn "setup-user-env.sh reported an issue; continuing with targeted restore."
    fi
}

move_stale_disabled_autostarts() {
    local disabled_dir="$TARGET_HOME/.config/autostart-disabled"
    local file target

    mkdir -p "$disabled_dir"
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        target="$disabled_dir/$(basename "$file")"
        if [ -e "$target" ]; then
            target="$target.$(date +%s)"
        fi
        mv "$file" "$target"
    done < <(collect_stale_disabled_autostarts)
}

disable_broken_launchers() {
    local entry category missing_target exec_line target
    local disabled_autostart_dir="$TARGET_HOME/.config/autostart-disabled"

    mkdir -p "$disabled_autostart_dir"

    while IFS=$'\t' read -r entry category missing_target exec_line; do
        [ -n "$entry" ] || continue
        if [ "$category" = "autostart" ]; then
            target="$disabled_autostart_dir/$(basename "$entry")"
        else
            target="$entry.disabled"
        fi
        if [ -e "$target" ]; then
            target="$target.$(date +%s)"
        fi
        log_warn "Disabling broken launcher $entry (missing: $missing_target)"
        mv "$entry" "$target"
    done < <(collect_broken_launchers)
}

ensure_pacman_holds() {
    log_info "Holding patched Plasma packages in pacman.conf ..."
    kde_post_repair_ensure_pacman_hold
    pacman_holds_are_present || die "Failed to install the managed Plasma package hold."
}

verify_patched_plasma_installation() {
    plasma_packages_are_patched || \
        die "libplasma and plasma-desktop were not installed as the reviewed patched pair."
    libplasma_is_patched || die "Installed libplasma is missing secondaryAction."
    plasma_desktop_is_patched || die "Installed task-manager plugin is missing jump-list grouping."
    plasma_plugins_link_cleanly || die "Installed patched Plasma plugins have unresolved dependencies."
    pacman -Qkk libplasma plasma-desktop >/dev/null || \
        die "Installed patched Plasma packages failed pacman -Qkk."
}

rebuild_custom_kwin() {
    log_info "Rebuilding repo-managed custom KWin ..."
    sudo env KDE_ROOT="$REPO_ROOT" KWIN_SRC="$REPO_ROOT/kde-kwin" TARGET_USER="$TARGET_USER" TARGET_HOME="$TARGET_HOME" "$SCRIPT_DIR/install-custom-kwin.sh"
}

restore_voxtype_integration_if_ready() {
    local installer="$SCRIPT_DIR/install-voxtype-ptt-tray.sh"
    local missing_packages

    if [ ! -x /usr/bin/voxtype ]; then
        log_warn "VoxType is not installed; leaving PTT tray restoration pending."
        return
    fi
    missing_packages="$(collect_missing_voxtype_packages || true)"
    if [ -n "$missing_packages" ]; then
        log_warn "VoxType dependencies are incomplete; leaving PTT tray restoration pending: ${missing_packages//$'\n'/, }"
        return
    fi
    if [ ! -x "$installer" ]; then
        log_warn "VoxType PTT tray installer is missing from the repository."
        return
    fi
    if ! voxtype_models_are_present; then
        log_warn "VoxType models are incomplete; installing tray files but not starting the services."
        run_as_target_user "$installer"
        return
    fi

    run_as_target_user "$installer"
    run_as_target_user systemctl --user daemon-reload
    run_as_target_user systemctl --user enable --now voxtype.service voxtype-ptt-tray.service
}

restore_whatsie_theme_guard_if_ready() {
    if ! run_as_target_user flatpak info com.ktechpit.whatsie >/dev/null 2>&1; then
        log_warn "WhatSie Flatpak is not installed; leaving its theme guard pending."
        return
    fi
    run_as_target_user "$SCRIPT_DIR/install-whatsie-theme-guard.sh"
}

reload_user_session_state() {
    run_as_target_user systemctl --user daemon-reload >/dev/null 2>&1 || true
    run_as_target_user kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    run_as_target_user qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
    if run_as_target_user systemctl --user is-active --quiet plasma-plasmashell.service; then
        run_as_target_user systemctl --user restart plasma-plasmashell.service || \
            log_warn "Unable to restart Plasma Shell; log out and back in to load repaired plugins."
    fi
}

apply_restore() {
    install_missing_packages
    run_setup_user_env
    run_as_target_user "$SCRIPT_DIR/install-servicemenu.sh"
    run_as_target_user "$SCRIPT_DIR/install-vscode-jumplist-integration.sh"
    run_as_target_user "$TARGET_HOME/.local/bin/code-jumplist-manager" refresh >/dev/null 2>&1 || true
    run_as_target_user "$SCRIPT_DIR/install-managed-hubstaff.sh"
    run_as_target_user "$SCRIPT_DIR/install-touchscreen-mapping.sh"
    run_as_target_user "$SCRIPT_DIR/install-fastfetch-fish.sh"
    move_stale_disabled_autostarts
    ensure_pacman_holds
    sudo env TARGET_USER="$TARGET_USER" TARGET_HOME="$TARGET_HOME" "$SCRIPT_DIR/build-patched-plasma-packages.sh" --apply
    verify_patched_plasma_installation
    rebuild_custom_kwin
    restore_voxtype_integration_if_ready
    restore_whatsie_theme_guard_if_ready
    disable_broken_launchers
    reload_user_session_state
}

main() {
    parse_args "$@"

    if [ "$MODE" = "apply" ]; then
        require_sudo_access
        kde_post_repair_assert_plasma_baseline || \
            die "Installed Plasma does not match the reviewed $KDE_POST_REPAIR_PLASMA_SOURCE_VERSION baseline; update the repo baseline and patches before applying repairs."
        apply_restore
    fi

    print_audit_report
}

main "$@"
