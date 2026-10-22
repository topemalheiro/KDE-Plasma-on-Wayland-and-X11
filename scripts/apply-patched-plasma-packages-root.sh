#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$script_dir/.." && pwd)"
source "$script_dir/package-baseline.sh"

readonly guard_source="$repo_root/scripts/plasma-package-guard"
readonly hook_source="$repo_root/config/pacman-hooks/95-kde-patched-plasma-guard.hook"
readonly guard_target="/usr/local/lib/kde-post-repair/plasma-package-guard"
readonly hook_target="/etc/pacman.d/hooks/95-kde-patched-plasma-guard.hook"
readonly marker_dir="/run/kde-post-repair"
readonly marker="$marker_dir/plasma-package-transaction.allow"
readonly libplasma_plugin="usr/lib/qt6/qml/org/kde/plasma/extras/libplasmaextracomponentsplugin.so"
readonly taskmanager_plugin="usr/lib/qt6/plugins/plasma/applets/org.kde.plasma.taskmanager.so"

die() {
    echo "apply-patched-plasma-packages-root: $1" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || die "must run as root"
[[ $# -eq 2 ]] || die "expected libplasma and plasma-desktop package archives"

libplasma_archive="$(realpath -e -- "$1")"
plasma_desktop_archive="$(realpath -e -- "$2")"

verify_archive() {
    local archive="$1"
    local package_name="$2"
    local plugin_path="$3"
    local marker_text="$4"
    local extract_root plugin

    [[ "$(pacman -Qp "$archive" | awk '{print $1}')" == "$package_name" ]] || \
        die "$archive is not package $package_name"
    [[ "$(pacman -Qp "$archive" | awk '{print $2}')" == "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ]] || \
        die "$archive is not reviewed version $KDE_POST_REPAIR_PLASMA_PATCHED_VERSION"
    bsdtar -tf "$archive" | grep -Fx "$plugin_path" >/dev/null || \
        die "$archive does not contain /$plugin_path"

    extract_root="$(mktemp -d)"
    bsdtar -xf "$archive" -C "$extract_root" "$plugin_path"
    plugin="$extract_root/$plugin_path"
    grep -aFq "$marker_text" "$plugin" || {
        rm -rf -- "$extract_root"
        die "$archive is missing patch marker $marker_text"
    }
    ldd -r "$plugin" >/dev/null || {
        rm -rf -- "$extract_root"
        die "$archive contains a plugin with unresolved dependencies"
    }
    rm -rf -- "$extract_root"
}

verify_archive "$libplasma_archive" libplasma "$libplasma_plugin" secondaryAction
verify_archive "$plasma_desktop_archive" plasma-desktop "$taskmanager_plugin" ContextMenu.qml

install -Dm755 "$guard_source" "$guard_target"
install -Dm644 "$hook_source" "$hook_target"
kde_post_repair_ensure_pacman_hold
kde_post_repair_pacman_hold_is_managed || die "failed to install the managed pacman hold"

install -d -m700 "$marker_dir"
token="$(tr -d '-' </proc/sys/kernel/random/uuid)"
install -m600 /dev/null "$marker"
printf '%s\n' "$token" > "$marker"
cleanup_marker() {
    rm -f -- "$marker"
}
trap cleanup_marker EXIT

KDE_POST_REPAIR_PLASMA_TOKEN="$token" \
    pacman -U --noconfirm -- "$libplasma_archive" "$plasma_desktop_archive"

[[ "$(pacman -Q libplasma | awk '{print $2}')" == "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ]] || \
    die "libplasma did not install as $KDE_POST_REPAIR_PLASMA_PATCHED_VERSION"
[[ "$(pacman -Q plasma-desktop | awk '{print $2}')" == "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ]] || \
    die "plasma-desktop did not install as $KDE_POST_REPAIR_PLASMA_PATCHED_VERSION"
grep -aFq secondaryAction "/$libplasma_plugin" || die "installed libplasma patch marker is missing"
grep -aFq ContextMenu.qml "/$taskmanager_plugin" || die "installed task-manager payload is missing"
pacman -Qkk libplasma plasma-desktop >/dev/null || die "installed package integrity check failed"
ldd -r "/$libplasma_plugin" >/dev/null || die "installed libplasma plugin has unresolved dependencies"
ldd -r "/$taskmanager_plugin" >/dev/null || die "installed task-manager plugin has unresolved dependencies"
