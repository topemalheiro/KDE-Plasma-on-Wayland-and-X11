#!/bin/bash
# Build and install the repo-managed libplasma and plasma-desktop patches
# against the current reviewed Arch Linux 6.7.3-1 packaging sources.

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

# Arch's default makepkg configuration may leave large Plasma builds
# single-threaded. Respect an explicit MAKEFLAGS, otherwise use the machine's
# available CPUs for future rebuilds.
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"

declare -A PACKAGE_REPOS=(
    [libplasma]="https://gitlab.archlinux.org/archlinux/packaging/packages/libplasma.git"
    [plasma-desktop]="https://gitlab.archlinux.org/archlinux/packaging/packages/plasma-desktop.git"
)

# Whitespace-separated list of patch file names per package, applied in this
# order. Every patch listed here is applied AND verified below -- a patch that
# silently stops applying fails the build instead of shipping a package that
# quietly drops a feature. (The folder-view patches were lost exactly that way
# when a rebuild carried only the jumplist patch.)
declare -A PACKAGE_PATCHES=(
    [libplasma]="plasma-framework-secondary-action.patch"
    [plasma-desktop]="plasma-desktop-jumplist-secondary-action.patch
                      plasma-desktop-folder-link-emblem.patch
                      plasma-desktop-copy-location.patch
                      plasma-desktop-folder-color-links.patch
                      plasma-desktop-symlink-target-navigation.patch
                      plasma-desktop-symlink-name-fixup.patch"
)

# "<path relative to the unpacked source>:<string that must be present>", one
# per line. Checked after makepkg --nobuild has prepared the source.
declare -A PACKAGE_VERIFY=(
    [libplasma]="src/declarativeimports/plasmaextracomponents/qmenuitem.h:secondaryAction"
    [plasma-desktop]="applets/taskmanager/qml/ContextMenu.qml:groupJumpListActions
                      containments/desktop/package/contents/ui/FolderItemDelegate.qml:linkEmblem
                      containments/desktop/plugins/folder/foldermodel.cpp:copyLocation
                      containments/desktop/plugins/folder/foldermodel.cpp:resolveLinkedDirectories
                      containments/desktop/plugins/folder/foldermodel.cpp:resolveDirectorySymlink
                      containments/desktop/plugins/folder/foldermodel.cpp:readIcon
                      containments/desktop/package/contents/ui/FolderItemDelegate.qml:isDesktopFileLink
                      containments/desktop/plugins/folder/foldermodel.cpp:renameMisnamedSymlink"
)

declare -A BUILT_PACKAGES=()

declare -A PACKAGE_INSTALLED_FILES=(
    [libplasma]="usr/lib/qt6/qml/org/kde/plasma/extras/libplasmaextracomponentsplugin.so"
    [plasma-desktop]="usr/lib/qt6/plugins/plasma/applets/org.kde.plasma.taskmanager.so"
)

declare -A PACKAGE_PATCH_MARKERS=(
    [libplasma]="secondaryAction"
    # qmlcachegen AOT-compiles ContextMenu.qml and strips JavaScript helper
    # and property names from the resulting plugin.  The patched source is
    # checked before every fresh build; the archive check therefore verifies
    # that the expected AOT ContextMenu payload made it into the package.
    [plasma-desktop]="ContextMenu.qml"
)

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

require_root_installer() {
    if [ "$INSTALL_AFTER_BUILD" != true ] || [ "$(id -u)" -eq 0 ] || sudo -n true >/dev/null 2>&1; then
        return
    fi
    command -v pkexec >/dev/null 2>&1 || \
        die "--apply needs sudo or KDE graphical authorization through pkexec."
}

verify_managed_baseline() {
    [ "$PLASMA_TAG" = "$KDE_POST_REPAIR_PLASMA_SOURCE_TAG" ] || \
        die "PLASMA_SOURCE_TAG=$PLASMA_TAG does not match the reviewed baseline $KDE_POST_REPAIR_PLASMA_SOURCE_TAG. Update package-baseline.sh and the patches together before rebuilding."

    kde_post_repair_assert_plasma_baseline || \
        die "Refusing to build against a different or incomplete Plasma baseline."
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
    local patch_name
    local patch_source
    local -a patch_names=()

    for patch_name in ${PACKAGE_PATCHES[$package_name]}; do
        patch_source="$REPO_ROOT/patches/$patch_name"
        [ -f "$patch_source" ] || die "Configured patch not found: $patch_source"
        run_makepkg_as_target_user cp "$patch_source" "$package_dir/$patch_name"
        patch_names+=("$patch_name")
    done

    [ "${#patch_names[@]}" -gt 0 ] || die "No patches configured for $package_name."
    log_info "Applying ${#patch_names[@]} patch(es) to $package_name: ${patch_names[*]}"

    run_makepkg_as_target_user python3 - \
        "$package_dir/PKGBUILD" \
        "$KDE_POST_REPAIR_PLASMA_SOURCE_VERSION" \
        "${patch_names[@]}" <<'PY'
from pathlib import Path
import re
import sys

pkgbuild_path = Path(sys.argv[1])
expected_version = sys.argv[2]
patch_names = sys.argv[3:]
text = pkgbuild_path.read_text()

pkgver_match = re.search(r"^pkgver=([^\n]+)$", text, flags=re.MULTILINE)
pkgrel_match = re.search(r"^pkgrel=([^\n]+)$", text, flags=re.MULTILINE)
if not pkgver_match or not pkgrel_match:
    raise SystemExit("Unable to determine PKGBUILD pkgver/pkgrel.")

source_version = f"{pkgver_match.group(1)}-{pkgrel_match.group(1)}"
if source_version != expected_version:
    raise SystemExit(
        f"PKGBUILD version {source_version} does not match reviewed baseline {expected_version}."
    )

text, replacements = re.subn(
    r"^pkgrel=1$", "pkgrel=1.1", text, count=1, flags=re.MULTILINE
)
if replacements != 1:
    raise SystemExit("Expected the reviewed PKGBUILD to contain exactly pkgrel=1.")

arrays = re.search(r"source=\((.*?)\)\nsha256sums=\((.*?)\)\n", text, flags=re.DOTALL)
if not arrays:
    raise SystemExit("Unable to locate PKGBUILD source arrays.")

source_block = arrays.group(1)
sha_block = arrays.group(2)

for patch_name in patch_names:
    if patch_name not in source_block:
        source_block = source_block.rstrip() + f"\n        '{patch_name}'"
        sha_block = sha_block.rstrip() + "\n            'SKIP'"

text = (
    text[:arrays.start()]
    + f"source=({source_block})\nsha256sums=({sha_block})\n"
    + text[arrays.end():]
)

text = re.sub(r"(^|\n)prep\(\)\s*\{", r"\1prepare() {", text, count=1)

# One cd, then one patch line per configured patch, skipping any already present.
missing = [n for n in patch_names if f'patch -Np1 -i "$srcdir/{n}"' not in text]
if missing:
    snippet = '  cd "$pkgname-$pkgver"\n' if 'cd "$pkgname-$pkgver"' not in text else ""
    snippet += "".join(f'  patch -Np1 -i "$srcdir/{n}"\n' for n in missing)

    prepare_match = re.search(r"(^|\n)prepare\(\)\s*\{\n", text)
    if prepare_match:
        insert_at = prepare_match.end()
        text = text[:insert_at] + snippet + text[insert_at:]
    else:
        prepare_block = f"prepare() {{\n{snippet}}}\n\n"
        text = text.replace("\nbuild() {\n", f"\n{prepare_block}build() {{\n", 1)

pkgbuild_path.write_text(text)
PY
}

verify_patched_source() {
    local package_name="$1"
    local package_dir="$2"
    local source_dir="$package_dir/src/${package_name}-${PLASMA_TAG%-*}"
    local entry rel verify_path verify_pattern

    log_info "Preparing patched source for $package_name ..."
    (
        cd "$package_dir"
        run_makepkg_as_target_user makepkg --nobuild --nodeps --skippgpcheck --cleanbuild
    )

    [ -n "${PACKAGE_VERIFY[$package_name]:-}" ] \
        || die "No verification markers configured for $package_name."

    while IFS= read -r entry; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [ -n "$entry" ] || continue

        rel="${entry%%:*}"
        verify_pattern="${entry##*:}"
        verify_path="$source_dir/$rel"

        [ -f "$verify_path" ] \
            || die "Prepared source file not found for $package_name: $verify_path"
        grep -q -- "$verify_pattern" "$verify_path" \
            || die "Patch verification failed for $package_name: '$verify_pattern' not found in $rel"
        log_info "  verified $rel contains '$verify_pattern'"
    done <<< "${PACKAGE_VERIFY[$package_name]}"
}

build_package() {
    local package_name="$1"
    local package_dir="$2"
    local package_file package_metadata package_version
    local -a package_candidates=()

    mapfile -t package_candidates < <(
        cd "$package_dir"
        run_makepkg_as_target_user makepkg --packagelist
    )
    [ "${#package_candidates[@]}" -gt 0 ] || \
        die "makepkg did not report an output archive for $package_name."

    # Delete only the exact outputs declared by this patched PKGBUILD. This
    # prevents a previous successful build from being mistaken for this one.
    run_makepkg_as_target_user rm -f -- "${package_candidates[@]}"

    log_info "Building patched $package_name from Arch tag $PLASMA_TAG ..."
    (
        cd "$package_dir"
        run_makepkg_as_target_user makepkg --syncdeps --noconfirm --skippgpcheck --cleanbuild --clean
    )

    package_file=""
    for candidate in "${package_candidates[@]}"; do
        [ -f "$candidate" ] || continue
        package_metadata="$(pacman -Qp "$candidate" 2>/dev/null || true)"
        if [ "${package_metadata%% *}" = "$package_name" ]; then
            [ -z "$package_file" ] || \
                die "Build produced more than one archive named $package_name."
            package_file="$candidate"
        fi
    done

    [ -n "$package_file" ] || \
        die "Build completed but its declared outputs contain no $package_name package."

    package_version="$(pacman -Qp "$package_file" | awk '{print $2}')"
    [ "$package_version" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ] || \
        die "$package_file has version $package_version; expected $KDE_POST_REPAIR_PLASMA_PATCHED_VERSION."

    BUILT_PACKAGES["$package_name"]="$package_file"
}

verify_package_archive() {
    local package_name="$1"
    local package_file="${BUILT_PACKAGES[$package_name]:-}"
    local installed_file="${PACKAGE_INSTALLED_FILES[$package_name]}"
    local marker="${PACKAGE_PATCH_MARKERS[$package_name]}"
    local extracted_root extracted_file

    [ -f "$package_file" ] || die "Missing freshly built archive for $package_name."
    [ "$(pacman -Qp "$package_file" | awk '{print $1}')" = "$package_name" ] || \
        die "Unexpected package name in $package_file."
    [ "$(pacman -Qp "$package_file" | awk '{print $2}')" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ] || \
        die "Unexpected package version in $package_file."
    bsdtar -tf "$package_file" | grep -Fx "$installed_file" >/dev/null || \
        die "$package_file does not own the expected Plasma 6.7 plugin: /$installed_file"

    extracted_root="$(mktemp -d)"
    trap 'rm -rf -- "$extracted_root"' RETURN
    bsdtar -xf "$package_file" -C "$extracted_root" "$installed_file"
    extracted_file="$extracted_root/$installed_file"

    grep -aFq "$marker" "$extracted_file" || \
        die "$package_file is missing patch marker '$marker'."
    ldd -r "$extracted_file" >/dev/null || \
        die "$package_file contains a plugin with unresolved runtime dependencies."

    rm -rf -- "$extracted_root"
    trap - RETURN
}

verify_all_package_archives() {
    local package_name

    [ "${#BUILT_PACKAGES[@]}" -eq "${#KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}" ] || \
        die "Both managed Plasma packages must be built before either can be installed."
    for package_name in "${KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}"; do
        verify_package_archive "$package_name"
    done
}

install_packages_together() {
    local package_name
    local -a package_files=()

    verify_all_package_archives
    for package_name in "${KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}"; do
        package_files+=("${BUILT_PACKAGES[$package_name]}")
    done

    # Installation is package-archive-only. In particular, never copy the
    # saved kde-build-artifacts/*.so files over distro-owned Plasma plugins;
    # they are not ABI-safe for the currently installed package set.
    log_info "Installing patched libplasma and plasma-desktop in one transaction ..."
    if [ "$(id -u)" -eq 0 ]; then
        bash "$SCRIPT_DIR/apply-patched-plasma-packages-root.sh" "${package_files[@]}"
    elif sudo -n true >/dev/null 2>&1; then
        sudo bash "$SCRIPT_DIR/apply-patched-plasma-packages-root.sh" "${package_files[@]}"
    else
        pkexec bash "$SCRIPT_DIR/apply-patched-plasma-packages-root.sh" "${package_files[@]}"
    fi
}

verify_installed_packages() {
    local package_name installed_file marker installed_version

    for package_name in "${KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}"; do
        installed_version="$(pacman -Q "$package_name" 2>/dev/null | awk '{print $2}')"
        [ "$installed_version" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ] || \
            die "$package_name installation has version $installed_version; expected $KDE_POST_REPAIR_PLASMA_PATCHED_VERSION."

        installed_file="/${PACKAGE_INSTALLED_FILES[$package_name]}"
        marker="${PACKAGE_PATCH_MARKERS[$package_name]}"
        [ -f "$installed_file" ] || die "$package_name did not install $installed_file."
        grep -aFq "$marker" "$installed_file" || \
            die "$package_name installed plugin is missing patch marker '$marker'."
        ldd -r "$installed_file" >/dev/null || \
            die "$package_name installed plugin has unresolved runtime dependencies."
    done

    pacman -Qkk "${KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}" >/dev/null || \
        die "Installed patched Plasma packages failed pacman -Qkk verification."
}

main() {
    local package_name
    local package_dir

    parse_args "$@"
    require_root_installer
    verify_managed_baseline
    ensure_build_requirements

    for package_name in "${KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}"; do
        package_dir="$(sync_packaging_repo "$package_name")"
        patch_pkgbuild "$package_name" "$package_dir"
        verify_patched_source "$package_name" "$package_dir"
        build_package "$package_name" "$package_dir"
    done

    verify_all_package_archives

    if [ "$INSTALL_AFTER_BUILD" = true ]; then
        install_packages_together
        verify_installed_packages
    fi

    for package_name in "${KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}"; do
        printf '%s\n' "${BUILT_PACKAGES[$package_name]}"
    done
}

main "$@"
