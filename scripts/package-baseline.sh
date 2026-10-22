#!/bin/bash
# Shared package baseline for workstation install and post-repair restore flows.

KDE_POST_REPAIR_BASELINE_PACKAGES=(
    mesa
    vulkan-intel
    intel-media-driver
    libva-intel-driver
    plasma-meta
    plasma-login-manager
    konsole
    dolphin
    kate
    ark
    okular
    plasma-pa
    plasma-nm
    kwalletmanager
    noto-fonts
    noto-fonts-cjk
    noto-fonts-emoji
    ttf-dejavu
    ttf-liberation
    woff2-font-awesome
    firefox
    chromium
    visual-studio-code-bin
    docker
    docker-compose
    flatpak
    pacman-contrib
    github-cli
    7zip
    unzip
    unrar
    pipewire
    pipewire-pulse
    pipewire-alsa
    pipewire-jack
    wireplumber
    fish
    fastfetch
    python-dbus
    python-gobject
    lolcat
    alacritty
    curl
    wget
    openssh
    git
    extra-cmake-modules
    cmake
    ninja
)

KDE_POST_REPAIR_ARCH_BUILD_PACKAGES=(
    base-devel
    git
    intltool
    kdoctools
    kaccounts-integration
    libibus
    packagekit-qt6
    scim
    wayland-protocols
    xf86-input-libinput
    xorg-server-devel
)

KDE_POST_REPAIR_BASELINE_SYSTEM_SERVICES=(
    plasma-login-manager.service
    NetworkManager.service
    bluetooth.service
    fstrim.timer
    docker.service
)

KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES=(
    libplasma
    plasma-desktop
)

KDE_POST_REPAIR_VOXTYPE_PACKAGES=(
    voxtype-bin
    wtype
    wl-clipboard
    ydotool
    python-numpy
    python-vosk
    python-sounddevice
    python-pyqt6
)

KDE_POST_REPAIR_DISPLAY_MANAGER_PACKAGE="plasma-login-manager"
KDE_POST_REPAIR_DISPLAY_MANAGER_SERVICE="plasma-login-manager.service"
KDE_POST_REPAIR_PLASMA_SOURCE_VERSION="6.7.3-1"
KDE_POST_REPAIR_PLASMA_PATCHED_VERSION="6.7.3-1.1"
KDE_POST_REPAIR_PLASMA_SOURCE_TAG="${KDE_POST_REPAIR_PLASMA_SOURCE_TAG:-$KDE_POST_REPAIR_PLASMA_SOURCE_VERSION}"
KDE_POST_REPAIR_PACMAN_HOLD_START="# >>> KDE post-repair holds >>>"
KDE_POST_REPAIR_PACMAN_HOLD_END="# <<< KDE post-repair holds <<<"

kde_post_repair_package_satisfied() {
    local package_name="$1"

    case "$package_name" in
        code)
            pacman -Qq code >/dev/null 2>&1 || pacman -Qq visual-studio-code-bin >/dev/null 2>&1
            ;;
        p7zip)
            pacman -Qq 7zip >/dev/null 2>&1 || pacman -Qq p7zip >/dev/null 2>&1
            ;;
        sddm|sddm-kcm)
            pacman -Qq "${KDE_POST_REPAIR_DISPLAY_MANAGER_PACKAGE}" >/dev/null 2>&1
            ;;
        *)
            pacman -Qq "$package_name" >/dev/null 2>&1
            ;;
    esac
}

kde_post_repair_missing_packages() {
    local package_name

    for package_name in "${KDE_POST_REPAIR_BASELINE_PACKAGES[@]}"; do
        if ! kde_post_repair_package_satisfied "$package_name"; then
            printf '%s\n' "$package_name"
        fi
    done
}

kde_post_repair_plasma_version_is_supported() {
    local version="$1"

    [ "$version" = "$KDE_POST_REPAIR_PLASMA_SOURCE_VERSION" ] || \
        [ "$version" = "$KDE_POST_REPAIR_PLASMA_PATCHED_VERSION" ]
}

kde_post_repair_assert_plasma_baseline() {
    local package_name installed_version
    local failed=false

    for package_name in "${KDE_POST_REPAIR_PATCHED_PLASMA_PACKAGES[@]}"; do
        installed_version="$(pacman -Q "$package_name" 2>/dev/null | awk '{print $2}')"
        if [ -z "$installed_version" ]; then
            echo "$package_name is not installed." >&2
            failed=true
        elif ! kde_post_repair_plasma_version_is_supported "$installed_version"; then
            echo "$package_name $installed_version does not match the managed Plasma baseline $KDE_POST_REPAIR_PLASMA_SOURCE_VERSION." >&2
            failed=true
        fi
    done

    [ "$failed" = false ]
}

kde_post_repair_pacman_hold_is_managed() {
    python3 - "/etc/pacman.conf" "$KDE_POST_REPAIR_PACMAN_HOLD_START" "$KDE_POST_REPAIR_PACMAN_HOLD_END" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
start_marker = sys.argv[2]
end_marker = sys.argv[3]
content = path.read_text(errors="replace")

options = re.search(r"(?ms)^\[options\]\n(?P<body>.*?)(?=^\[|\Z)", content)
if not options:
    raise SystemExit(1)

expected = f"{start_marker}\nIgnorePkg = libplasma plasma-desktop\n{end_marker}"
blocks = re.findall(
    rf"(?ms)^{re.escape(start_marker)}\n.*?^{re.escape(end_marker)}$",
    content,
)
raise SystemExit(0 if blocks == [expected] and expected in options.group("body") else 1)
PY
}

kde_post_repair_ensure_pacman_hold() {
    local -a python_command=(python3)

    if [ ! -w /etc/pacman.conf ]; then
        python_command=(sudo python3)
    fi

    "${python_command[@]}" - "/etc/pacman.conf" "$KDE_POST_REPAIR_PACMAN_HOLD_START" "$KDE_POST_REPAIR_PACMAN_HOLD_END" <<'PY'
from pathlib import Path
import os
import re
import sys
import tempfile

path = Path(sys.argv[1])
start_marker = sys.argv[2]
end_marker = sys.argv[3]
block = f"{start_marker}\nIgnorePkg = libplasma plasma-desktop\n{end_marker}\n"

content = path.read_text()
content_without_blocks = re.sub(
    rf"(?ms)^\s*{re.escape(start_marker)}\n.*?^{re.escape(end_marker)}\s*\n?",
    "",
    content,
)
options = re.search(r"(?m)^\[options\]\n", content_without_blocks)
if not options:
    raise SystemExit("Could not find [options] section in /etc/pacman.conf")

updated = (
    content_without_blocks[: options.end()]
    + block
    + content_without_blocks[options.end() :]
)
if updated == content:
    raise SystemExit(0)

stat = path.stat()
fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    with os.fdopen(fd, "w") as temporary:
        temporary.write(updated)
        temporary.flush()
        os.fsync(temporary.fileno())
        os.fchmod(temporary.fileno(), stat.st_mode)
        os.fchown(temporary.fileno(), stat.st_uid, stat.st_gid)
    os.replace(temporary_name, path)
except BaseException:
    try:
        os.unlink(temporary_name)
    except FileNotFoundError:
        pass
    raise
PY
}
