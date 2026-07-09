#!/bin/bash
# install-custom-kwin.sh — Build and install the custom KWin fork.
#
# This rebuilds KWin from the kde-kwin submodule inside KDE-Plasma-on-Wayland.
# It expects a standard KDE Plasma 6 system install already present.
#
# Run as root on the installed system (not from live USB).
#
# Usage:
#   ./install-custom-kwin.sh [--dry-run]

set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
fi

# Auto-detect the KDE-Plasma-on-Wayland checkout.
if [ -z "${KDE_ROOT:-}" ]; then
    for candidate in "$HOME/Projects/KDE-Plasma-on-Wayland" "/home/tope/Projects/KDE-Plasma-on-Wayland"; do
        if [ -f "$candidate/kde-kwin/CMakeLists.txt" ]; then
            KDE_ROOT="$candidate"
            break
        fi
    done
fi
KDE_ROOT="${KDE_ROOT:-$HOME/Projects/KDE-Plasma-on-Wayland}"
KWIN_SRC="${KWIN_SRC:-$KDE_ROOT/kde-kwin}"
KWIN_BUILD="${KWIN_BUILD:-$KWIN_SRC/build}"
STATE_DIR="${KDE_POST_REPAIR_STATE_DIR:-/var/lib/kde-post-repair}"
KWIN_STAMP="$STATE_DIR/kwin-build-info.json"

# Extra packages needed to build KWin on top of a standard Plasma install.
BUILD_DEPS=(
    extra-cmake-modules
    cmake
    ninja
    gcc
    make
    pkgconf
    wayland-protocols
    qt6-tools
    qt6-declarative
    kdoctools
)

log_info() { echo "[INFO] $1"; }
log_warn() { echo "[WARN] $1"; }
log_err() { echo "[ERROR] $1"; }

die() { log_err "$1"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        if [ "$DRY_RUN" = true ]; then
            log_warn "Not running as root, but dry-run mode allows testing."
        else
            die "This script must be run as root (e.g., sudo $0)"
        fi
    fi
}

install_build_deps() {
    log_info "Installing KWin build dependencies ..."
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: would run: pacman -S --needed --noconfirm ${BUILD_DEPS[*]}"
        return
    fi
    pacman -S --needed --noconfirm "${BUILD_DEPS[@]}"
}

build_and_install() {
    if [ ! -d "$KWIN_SRC" ]; then
        die "KWin source not found at $KWIN_SRC. Clone KDE-Plasma-on-Wayland with submodules first."
    fi

    log_info "Building KWin from $KWIN_SRC ..."
    if [ "$DRY_RUN" = true ]; then
        echo "  DRY RUN: would run cmake --build $KWIN_BUILD"
        echo "  DRY RUN: would run cmake --install $KWIN_BUILD"
        return
    fi

    mkdir -p "$KWIN_BUILD"
    cd "$KWIN_BUILD"

    cmake .. \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF

    # Build using all cores
    cmake --build . --parallel "$(nproc)"

    # Install
    cmake --install .
    mkdir -p "$STATE_DIR"
    cat > "$KWIN_STAMP" <<EOF
{
  "source": "$KWIN_SRC",
  "installed_at": "$(date -Iseconds)",
  "git_commit": "$(git -C "$KWIN_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
}
EOF

    log_info "Custom KWin installed."
}

main() {
    echo "========================================"
    echo " Custom KWin Build & Install"
    echo "========================================"
    echo

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN mode — no changes will be made."
        echo
    fi

    check_root
    install_build_deps
    build_and_install

    echo
    log_info "Done. Log out and back in (or run 'kwin_wayland --replace') to use the new KWin."
}

main "$@"
