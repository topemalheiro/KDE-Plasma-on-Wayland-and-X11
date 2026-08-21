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
    sudo -H -u "$TARGET_USER" env \
        HOME="$TARGET_HOME" \
        USER="$TARGET_USER" \
        LOGNAME="$TARGET_USER" \
        XDG_RUNTIME_DIR="$TARGET_RUNTIME_DIR" \
        DBUS_SESSION_BUS_ADDRESS="$TARGET_DBUS_ADDRESS" \
        "$@"
}

collect_missing_packages() {
    kde_post_repair_missing_packages
}

collect_missing_managed_components() {
    local path
    local managed_paths=(
        "$TARGET_HOME/.local/bin/code-jumplist-manager"
        "$TARGET_HOME/.local/bin/code-open-folder"
        "$TARGET_HOME/.local/share/kio/servicemenus/open-with-code.desktop"
        "$TARGET_HOME/.local/share/kwin/scripts/vscode-jumplist-spawner/metadata.json"
        "$TARGET_HOME/.local/share/kwin/scripts/vscode-jumplist-spawner/contents/code/main.js"
        "$TARGET_HOME/.config/vscode-jumplist/layout-map.json"
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

libplasma_is_patched() {
    rg -q "secondaryAction" /usr/lib/qt6/qml/org/kde/plasma/extras 2>/dev/null
}

plasma_desktop_is_patched() {
    local context_menu="/usr/share/plasma/plasmoids/org.kde.plasma.taskmanager/contents/ui/ContextMenu.qml"
    [ -f "$context_menu" ] && rg -q "groupJumpListActions|secondaryAction" "$context_menu" 2>/dev/null
}

pacman_holds_are_present() {
    rg -q "IgnorePkg = .*libplasma.*plasma-desktop|IgnorePkg = .*plasma-desktop.*libplasma" /etc/pacman.conf 2>/dev/null
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
    local missing_packages missing_components broken_launchers stale_disabled_autostarts failed_services

    missing_packages="$(collect_missing_packages || true)"
    missing_components="$(collect_missing_managed_components || true)"
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
    if libplasma_is_patched; then
        echo "libplasma: patched"
    else
        echo "libplasma: missing secondary-action patch"
    fi
    if plasma_desktop_is_patched; then
        echo "plasma-desktop: patched"
    else
        echo "plasma-desktop: missing jumplist grouping patch"
    fi
    if pacman_holds_are_present; then
        echo "pacman holds: active"
    else
        echo "pacman holds: missing"
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
    sudo python3 - <<'PY'
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
# Remove any previously injected block, even if it landed in the wrong section.
content = re.sub(
    rf"\n?{re.escape(start_marker)}\n.*?{re.escape(end_marker)}\n?",
    "\n",
    content,
    flags=re.DOTALL,
)

options_match = re.search(r"^\[options\]\n", content, flags=re.MULTILINE)
if not options_match:
    raise SystemExit("Could not find [options] section in /etc/pacman.conf")

insert_at = options_match.end()
content = content[:insert_at] + block + "\n" + content[insert_at:]
pacman_conf.write_text(content)
PY
}

rebuild_custom_kwin() {
    log_info "Rebuilding repo-managed custom KWin ..."
    sudo env KDE_ROOT="$REPO_ROOT" KWIN_SRC="$REPO_ROOT/kde-kwin" TARGET_USER="$TARGET_USER" TARGET_HOME="$TARGET_HOME" "$SCRIPT_DIR/install-custom-kwin.sh"
}

reload_user_session_state() {
    run_as_target_user systemctl --user daemon-reload >/dev/null 2>&1 || true
    run_as_target_user kbuildsycoca6 --noincremental >/dev/null 2>&1 || true
    run_as_target_user qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
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
    sudo env TARGET_USER="$TARGET_USER" TARGET_HOME="$TARGET_HOME" "$SCRIPT_DIR/build-patched-plasma-packages.sh" --apply
    ensure_pacman_holds
    rebuild_custom_kwin
    disable_broken_launchers
    reload_user_session_state
}

main() {
    parse_args "$@"

    if [ "$MODE" = "apply" ]; then
        require_sudo_access
        apply_restore
    fi

    print_audit_report
}

main "$@"
