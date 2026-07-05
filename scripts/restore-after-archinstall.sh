#!/bin/bash
# restore-after-archinstall.sh — Run once after first boot into a fresh Arch + KDE install.
#
# This restores projects, Desktop folders, shortcuts, and extra packages from the
# GitHub manifests in OS-Toolkit. It deliberately skips the CV Project.
#
# Usage:
#   ./restore-after-archinstall.sh
#   GH_TOKEN=ghp_xxx ./restore-after-archinstall.sh
#   EXCLUDE_CV_FOLDER=true ./restore-after-archinstall.sh

set -euo pipefail

GH_TOKEN="${GH_TOKEN:-}"
SETUP_REPOS="${SETUP_REPOS:-true}"
EXCLUDE_CV_FOLDER="${EXCLUDE_CV_FOLDER:-false}"

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err() { echo "[ERROR] $1"; }

die() { log_err "$1"; exit 1; }

install_packages() {
    log_info "Installing extra packages ..."
    sudo pacman -S --needed --noconfirm \
        git curl wget openssh github-cli \
        docker docker-compose flatpak pacman-contrib \
        firefox chromium code \
        noto-fonts noto-fonts-cjk noto-fonts-emoji \
        ttf-dejavu ttf-liberation ttf-font-awesome \
        p7zip unzip unrar \
        pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
        mesa vulkan-intel intel-media-driver libva-intel-driver \
        extra-cmake-modules cmake ninja
}

enable_services() {
    log_info "Enabling services ..."
    sudo systemctl enable --now sddm.service NetworkManager.service \
        bluetooth.service fstrim.timer docker.service 2>/dev/null || true
}

ensure_gh_auth() {
    if [ -n "$GH_TOKEN" ]; then
        log_info "GH_TOKEN is set; will use it for private HTTPS clones."
        return
    fi

    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        log_info "GitHub CLI is already authenticated."
        return
    fi

    log_warn "No GH_TOKEN set and GitHub CLI is not authenticated."
    log_warn "Private repo clones will fail until you authenticate."
    echo
    read -rp "Do you want to run 'gh auth login' now? [Y/n]: " answer
    if [[ "${answer:-Y}" =~ ^[Yy] ]]; then
        gh auth login
    fi
}

clone_toolkit() {
    log_info "Cloning OS-Toolkit and KDE-Plasma-on-Wayland ..."
    mkdir -p "$HOME/Projects"

    local os_url="https://github.com/topemalheiro/OS-Toolkit.git"
    local kde_url="https://github.com/topemalheiro/kde-plasma-wayland.git"
    local layout_url="https://github.com/topemalheiro/VSCodeSidePanelLayout.git"

    if [ -n "$GH_TOKEN" ]; then
        os_url="${os_url/https:\/\/github.com\//https:\/\/${GH_TOKEN}@github.com\/}"
        kde_url="${kde_url/https:\/\/github.com\//https:\/\/${GH_TOKEN}@github.com\/}"
        layout_url="${layout_url/https:\/\/github.com\//https:\/\/${GH_TOKEN}@github.com\/}"
    fi

    [ -d "$HOME/Projects/OS-Toolkit/.git" ] || git clone "$os_url" "$HOME/Projects/OS-Toolkit"
    [ -d "$HOME/Projects/KDE-Plasma-on-Wayland/.git" ] || git clone --recurse-submodules "$kde_url" "$HOME/Projects/KDE-Plasma-on-Wayland"

    # VS Code: Side Panel Layout daemon lives inside OS-Toolkit/Reprompty
    local layout_dir="$HOME/Projects/OS-Toolkit/Reprompty/VSCodeSidePanelLayout"
    if [ ! -d "$layout_dir/.git" ]; then
        log_info "Cloning VSCodeSidePanelLayout ..."
        mkdir -p "$layout_dir"
        git clone "$layout_url" "$layout_dir"
    fi
}

setup_user_env() {
    if [ "$SETUP_REPOS" != "true" ]; then
        log_info "Skipping repo setup."
        return
    fi

    log_info "Restoring projects, Desktop folders, and shortcuts ..."
    local setup_script="$HOME/Projects/KDE-Plasma-on-Wayland/scripts/setup-user-env.sh"
    if [ ! -x "$setup_script" ]; then
        chmod +x "$setup_script"
    fi

    # Pass exclusion settings down to setup-user-env.sh
    export GH_TOKEN
    export EXCLUDE_CV_FOLDER
    "$setup_script"
}

main() {
    echo "========================================"
    echo " Restore after archinstall"
    echo "========================================"
    echo

    if [ -n "$GH_TOKEN" ]; then
        log_info "GH_TOKEN detected."
    fi

    if [ "$EXCLUDE_CV_FOLDER" = "true" ]; then
        log_info "CV Desktop folder will also be excluded."
    else
        log_info "Only CV Project is excluded (CV Desktop folder will be cloned)."
    fi

    install_packages
    enable_services
    ensure_gh_auth
    clone_toolkit
    setup_user_env
    build_layout_daemon

    echo
    log_info "Done. Log out and back in (or reboot) if KDE was just installed."
    log_info "Custom KWin was NOT built. Run scripts/install-custom-kwin.sh later only if you want it."
}

build_layout_daemon() {
    log_info "Building VS Code: Side Panel Layout daemon ..."
    local layout_dir="$HOME/Projects/OS-Toolkit/Reprompty/VSCodeSidePanelLayout"
    if [ ! -d "$layout_dir" ]; then
        log_warn "VSCodeSidePanelLayout not found; skipping layout daemon build."
        return
    fi

    sudo pacman -S --needed --noconfirm python python-virtualenv gcc

    cd "$layout_dir"
    if [ ! -d venv ]; then
        python3 -m venv venv
    fi
    venv/bin/pip install -q cython 2>/dev/null || true

    if [ -x venv/bin/cython ]; then
        venv/bin/cython --embed -o linux_layout.c linux_layout.py
        gcc $(python3-config --cflags) linux_layout.c -o reprompty-layout-cython $(python3-config --ldflags --embed)
        log_info "Layout daemon rebuilt."
    else
        log_warn "Cython not available; layout daemon not rebuilt."
    fi
}

main "$@"
