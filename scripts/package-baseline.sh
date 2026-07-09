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

KDE_POST_REPAIR_DISPLAY_MANAGER_PACKAGE="plasma-login-manager"
KDE_POST_REPAIR_DISPLAY_MANAGER_SERVICE="plasma-login-manager.service"
KDE_POST_REPAIR_PLASMA_SOURCE_TAG="${KDE_POST_REPAIR_PLASMA_SOURCE_TAG:-6.7.2-1}"

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
