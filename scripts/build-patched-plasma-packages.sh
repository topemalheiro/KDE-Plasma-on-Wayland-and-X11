#!/bin/bash
# Build and install the repo-managed libplasma and plasma-desktop patches
# against the current Arch Linux 6.7.2-1 packaging sources.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/package-baseline.sh"

PLASMA_TAG="${PLASMA_SOURCE_TAG:-$KDE_POST_REPAIR_PLASMA_SOURCE_TAG}"
TARGET_USER="${TARGET_USER:-${SUDO_USER:-${USER}}}"
TARGET_HOME="${TARGET_HOME:-$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
TARGET_UID="$(id -u "$TARGET_USER")"
BUILD_ROOT="${BUILD_ROOT:-$TARGET_HOME/.cache/kde-post-repair/arch-pkgbuilds}"
INSTALL_AFTER_BUILD=false

declare -A PACKAGE_REPOS=(
    [libplasma]="https://gitlab.archlinux.org/archlinux/packaging/packages/libplasma.git"
    [plasma-desktop]="https://gitlab.archlinux.org/archlinux/packaging/packages/plasma-desktop.git"
)

declare -A PACKAGE_PATCHES=(
    [libplasma]="$REPO_ROOT/patches/plasma-framework-secondary-action.patch"
    [plasma-desktop]="$REPO_ROOT/patches/plasma-desktop-jumplist-secondary-action.patch"
)

BUILT_PACKAGES=()

log_info() { echo "[INFO] $1" >&2; }
log_warn() { echo "[WARN] $1" >&2; }
log_err() { echo "[ERROR] $1" >&2; }

die() {
    log_err "$1"
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./scripts/build-patched-plasma-packages.sh --apply
  ./scripts/build-patched-plasma-packages.sh --build-only

Options:
  --apply       Build and install the patched packages.
  --build-only  Build the patched packages without installing them.
EOF
}

parse_args() {
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --apply)
                INSTALL_AFTER_BUILD=true
                ;;
            --build-only)
                INSTALL_AFTER_BUILD=false
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

require_sudo_access() {
    if [ "$INSTALL_AFTER_BUILD" = true ] && ! sudo -n true >/dev/null 2>&1; then
        die "sudo access is required for --apply. Run this script from an interactive terminal with sudo privileges."
    fi
}

run_makepkg_as_target_user() {
    if [ "$(id -u)" -eq "$TARGET_UID" ] && [ "${HOME:-}" = "$TARGET_HOME" ]; then
        "$@"
    else
        sudo -H -u "$TARGET_USER" env \
            HOME="$TARGET_HOME" \
            USER="$TARGET_USER" \
            LOGNAME="$TARGET_USER" \
            "$@"
    fi
}

ensure_build_requirements() {
    log_info "Installing Arch package build requirements ..."
    if sudo -n true >/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm "${KDE_POST_REPAIR_ARCH_BUILD_PACKAGES[@]}"
    else
        log_warn "Skipping build dependency installation because sudo is unavailable; assuming they are already installed."
    fi
}

sync_packaging_repo() {
    local package_name="$1"
    local package_dir="$BUILD_ROOT/$package_name"
    local commit

    run_makepkg_as_target_user mkdir -p "$BUILD_ROOT"

    if [ ! -d "$package_dir/.git" ]; then
        log_info "Cloning packaging repo for $package_name ..."
        run_makepkg_as_target_user git clone --quiet "${PACKAGE_REPOS[$package_name]}" "$package_dir"
    fi

    run_makepkg_as_target_user git -C "$package_dir" fetch --quiet --tags origin
    commit="$(run_makepkg_as_target_user git -C "$package_dir" rev-list -n 1 "refs/tags/$PLASMA_TAG" 2>/dev/null || true)"
    [ -n "$commit" ] || die "Could not resolve tag $PLASMA_TAG for $package_name."

    run_makepkg_as_target_user git -C "$package_dir" checkout --quiet --force "$commit"
    run_makepkg_as_target_user git -C "$package_dir" clean -fdx >/dev/null

    printf '%s\n' "$package_dir"
}

patch_pkgbuild() {
    local package_name="$1"
    local package_dir="$2"
    local patch_source="${PACKAGE_PATCHES[$package_name]}"
    local patch_name

    patch_name="$(basename "$patch_source")"
    run_makepkg_as_target_user cp "$patch_source" "$package_dir/$patch_name"

    run_makepkg_as_target_user python3 - "$package_dir/PKGBUILD" "$patch_name" <<'PY'
from pathlib import Path
import re
import sys

pkgbuild_path = Path(sys.argv[1])
patch_name = sys.argv[2]
text = pkgbuild_path.read_text()

text = re.sub(r"^pkgrel=1$", "pkgrel=1.1", text, count=1, flags=re.MULTILINE)

arrays = re.search(r"source=\((.*?)\)\nsha256sums=\((.*?)\)\n", text, flags=re.DOTALL)
if not arrays:
    raise SystemExit("Unable to locate PKGBUILD source arrays.")

source_block = arrays.group(1)
sha_block = arrays.group(2)

if patch_name not in source_block:
    source_block = source_block.rstrip() + f"\n        '{patch_name}'"
if patch_name not in sha_block:
    sha_block = sha_block.rstrip() + "\n            'SKIP'"

text = (
    text[:arrays.start()]
    + f"source=({source_block})\nsha256sums=({sha_block})\n"
    + text[arrays.end():]
)

text = re.sub(r"(^|\n)prep\(\)\s*\{", r"\1prepare() {", text, count=1)

patch_snippet = f'  cd "$pkgname-$pkgver"\n  patch -Np1 -i "$srcdir/{patch_name}"\n'
patch_command = f'patch -Np1 -i "$srcdir/{patch_name}"'

if patch_command not in text:
    prepare_match = re.search(r"(^|\n)prepare\(\)\s*\{\n", text)
    if prepare_match:
        insert_at = prepare_match.end()
        text = text[:insert_at] + patch_snippet + text[insert_at:]
    else:
        prepare_block = f"""prepare() {{
{patch_snippet}}}

"""
        text = text.replace("\nbuild() {\n", f"\n{prepare_block}build() {{\n", 1)

pkgbuild_path.write_text(text)
PY
}

verify_patched_source() {
    local package_name="$1"
    local package_dir="$2"
    local source_dir="$package_dir/src/${package_name}-${PLASMA_TAG%-*}"
    local verify_path
    local verify_pattern

    log_info "Preparing patched source for $package_name ..."
    (
        cd "$package_dir"
        run_makepkg_as_target_user makepkg --nobuild --nodeps --skippgpcheck --cleanbuild
    )

    case "$package_name" in
        libplasma)
            verify_path="$source_dir/src/declarativeimports/plasmaextracomponents/qmenuitem.h"
            verify_pattern="secondaryAction"
            ;;
        plasma-desktop)
            verify_path="$source_dir/applets/taskmanager/qml/ContextMenu.qml"
            verify_pattern="groupJumpListActions"
            ;;
        *)
            die "No verification pattern configured for $package_name."
            ;;
    esac

    [ -f "$verify_path" ] || die "Prepared source file not found for $package_name: $verify_path"
    rg -q "$verify_pattern" "$verify_path" || die "Patch verification failed for $package_name: '$verify_pattern' not found in $verify_path"
}

build_package() {
    local package_name="$1"
    local package_dir="$2"
    local package_file

    log_info "Building patched $package_name from Arch tag $PLASMA_TAG ..."
    (
        cd "$package_dir"
        run_makepkg_as_target_user makepkg --syncdeps --noconfirm --skippgpcheck --cleanbuild --clean
    )

    package_file="$(
        find "$package_dir" -maxdepth 1 -type f \
            -name "${package_name}-[0-9]*.pkg.tar.*" \
            ! -name '*.sig' \
            | sort \
            | tail -n 1
    )"
    [ -n "$package_file" ] || die "Build completed but no package file was found for $package_name."
    BUILT_PACKAGES+=("$package_file")
}

install_packages() {
    [ "${#BUILT_PACKAGES[@]}" -gt 0 ] || return
    log_info "Installing patched Plasma packages ..."
    sudo pacman -U --noconfirm "${BUILT_PACKAGES[@]}"
}

main() {
    local package_name
    local package_dir

    parse_args "$@"
    require_sudo_access
    ensure_build_requirements

    for package_name in "${KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}"; do
        package_dir="$(sync_packaging_repo "$package_name")"
        patch_pkgbuild "$package_name" "$package_dir"
        verify_patched_source "$package_name" "$package_dir"
        build_package "$package_name" "$package_dir"
    done

    if [ "$INSTALL_AFTER_BUILD" = true ]; then
        install_packages
    fi

    printf '%s\n' "${BUILT_PACKAGES[@]}"
}

main "$@"
