#!/bin/bash
# post-install-setup.sh — Run after first boot into KDE to finish setup.
#
# This installs remaining packages, clones repos (if authenticated),
# recreates Desktop shortcuts, and builds custom KWin.
#
# Usage:
#   ./post-install-setup.sh
#   GH_TOKEN=ghp_xxx ./post-install-setup.sh   # for private repos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/package-baseline.sh"

GH_TOKEN="${GH_TOKEN:-}"
SETUP_REPOS="${SETUP_REPOS:-true}"
BUILD_KWIN="${BUILD_KWIN:-true}"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err() { echo "[ERROR] $1"; }

die() { log_err "$1"; exit 1; }

install_packages() {
    log_info "Installing packages ..."
    sudo pacman -S --needed --noconfirm "${KDE_POST_REPAIR_BASELINE_PACKAGES[@]}"
}

enable_services() {
    log_info "Enabling services ..."
    sudo systemctl enable --now "${KDE_POST_REPAIR_BASELINE_SYSTEM_SERVICES[@]}" 2>/dev/null || true
}

clone_repos() {
    if [ "$SETUP_REPOS" != "true" ]; then
        log_info "Skipping repo setup."
        return
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_warn "git not installed; skipping repo setup"
        return
    fi

    log_info "Cloning toolkit repo ..."
    mkdir -p "$HOME/Projects"

    local os_url="https://github.com/topemalheiro/OS-Toolkit.git"
    local kde_url="https://github.com/topemalheiro/kde-plasma-wayland.git"

    if [ -n "$GH_TOKEN" ]; then
        os_url="${os_url/https:\/\/github.com\//https:\/\/${GH_TOKEN}@github.com\/}"
        kde_url="${kde_url/https:\/\/github.com\//https:\/\/${GH_TOKEN}@github.com\/}"
    fi

    [ -d "$HOME/Projects/OS-Toolkit/.git" ] || git clone "$os_url" "$HOME/Projects/OS-Toolkit"
    [ -d "$HOME/Projects/KDE-Plasma-on-Wayland/.git" ] || git clone "$kde_url" "$HOME/Projects/KDE-Plasma-on-Wayland"

    log_info "Running user env setup ..."
    "$HOME/Projects/KDE-Plasma-on-Wayland/scripts/setup-user-env.sh"
}

build_custom_kwin() {
    if [ "$BUILD_KWIN" != "true" ]; then
        log_info "Skipping custom KWin build."
        return
    fi

    if [ ! -d "$HOME/Projects/KDE-Plasma-on-Wayland/kde-kwin" ]; then
        log_warn "KWin source not found; skipping custom KWin build"
        return
    fi

    log_info "Building custom KWin ..."
    sudo "$HOME/Projects/KDE-Plasma-on-Wayland/scripts/install-custom-kwin.sh"
}

main() {
    echo "========================================"
    echo " Post-Install Setup"
    echo "========================================"
    echo

    if [ -n "$GH_TOKEN" ]; then
        log_info "GH_TOKEN detected; will use it for private repo clones."
    else
        log_warn "No GH_TOKEN set. Private repo clones may fail."
        log_warn "Run 'gh auth login' first, or set GH_TOKEN=ghp_xxx."
    fi

    install_packages
    enable_services
    clone_repos
    build_custom_kwin

    echo
    log_info "Done. Reboot or log out/in to use custom KWin."
}

main "$@"
