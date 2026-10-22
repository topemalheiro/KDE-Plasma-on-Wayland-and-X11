#!/usr/bin/env bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$script_dir/.." && pwd)"
readonly user_bin="$HOME/.local/bin"
readonly user_units="$HOME/.config/systemd/user"
readonly autostart_dir="$HOME/.config/autostart"
readonly autostart_file="$autostart_dir/com.ktechpit.whatsie.desktop"
readonly backup_dir="$HOME/.local/share/kde-post-repair/backups"
readonly autostart_backup="$backup_dir/com.ktechpit.whatsie.desktop.before-theme-guard"
readonly app_id="com.ktechpit.whatsie"

flatpak info "$app_id" >/dev/null 2>&1 || {
    echo "install-whatsie-theme-guard: $app_id is not installed" >&2
    exit 1
}
command -v kdocker >/dev/null || {
    echo "install-whatsie-theme-guard: kdocker is not installed" >&2
    exit 1
}

mkdir -p "$user_bin" "$user_units" "$autostart_dir" "$backup_dir"

# A previous installer revision placed its backup beside the live autostart
# file, where systemd-xdg-autostart-generator still treated it as launchable.
legacy_backup="$autostart_dir/com.ktechpit.whatsie.desktop.before-theme-guard"
if [[ -f "$legacy_backup" ]]; then
    if [[ ! -e "$autostart_backup" ]]; then
        mv -- "$legacy_backup" "$autostart_backup"
    else
        mv -- "$legacy_backup" "$backup_dir/com.ktechpit.whatsie.desktop.legacy.$(date +%s)"
    fi
fi

if [[ -f "$autostart_file" && ! -e "$autostart_backup" ]]; then
    cp -p -- "$autostart_file" "$autostart_backup"
fi

# End the old generated autostart cgroup before replacing its source file. A
# stale KDocker process ignores SIGTERM after its child exits, so explicitly
# kill that one exact cgroup instead of waiting for systemd's default timeout.
systemctl --user stop --no-block 'app-com.ktechpit.whatsie@autostart.service' >/dev/null 2>&1 || true
systemctl --user kill --kill-whom=all --signal=KILL 'app-com.ktechpit.whatsie@autostart.service' >/dev/null 2>&1 || true
flatpak kill "$app_id" >/dev/null 2>&1 || true

install -m755 "$repo_root/scripts/whatsie-flatpak-x11" "$user_bin/whatsie-flatpak-x11"
install -m755 "$repo_root/scripts/whatsie-tray-launcher" "$user_bin/whatsie-tray-launcher"
install -m755 "$repo_root/scripts/whatsie-open" "$user_bin/whatsie-open"
install -m755 "$repo_root/scripts/whatsie-theme-guard.py" "$user_bin/whatsie-theme-guard"
install -m644 "$repo_root/config/systemd/user/whatsie-tray.service" "$user_units/whatsie-tray.service"
install -m644 "$repo_root/config/autostart/com.ktechpit.whatsie.desktop" "$autostart_file"

systemctl --user daemon-reload
systemctl --user enable whatsie-tray.service
systemctl --user restart whatsie-tray.service

echo "WhatSie dark-theme guard installed."
