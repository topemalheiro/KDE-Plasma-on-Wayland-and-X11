#!/usr/bin/env bash
# Re-create the Insightful (Workpuls) desktop integration on KDE Plasma 6.
#
# Idempotent: safe to run repeatedly. See insightful-README.md for what each
# piece does and why it is needed.
#
# Usage:  ./insightful-setup.sh [--no-restart]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
KWIN_DIR="$HOME/.local/share/kwin/scripts/insightful-tray-only"
AUTOSTART="$HOME/.config/autostart"
APPLETSRC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
RESTART=1
[ "${1:-}" = "--no-restart" ] && RESTART=0

say() { printf '  %s\n' "$*"; }

echo "==> Installing scripts"
mkdir -p "$BIN" "$AUTOSTART"
install -m 755 "$HERE/insightful-start.sh"      "$BIN/insightful-start.sh"
install -m 755 "$HERE/insightful-tray-proxy.py" "$BIN/insightful-tray-proxy.py"
say "$BIN/insightful-start.sh"
say "$BIN/insightful-tray-proxy.py"

echo "==> Installing the KWin script"
mkdir -p "$KWIN_DIR/contents/code"
install -m 644 "$HERE/insightful-kwin-script/metadata.json" "$KWIN_DIR/metadata.json"
install -m 644 "$HERE/insightful-kwin-script/contents/code/main.js" \
               "$KWIN_DIR/contents/code/main.js"
kwriteconfig6 --file kwinrc --group Plugins --key insightful-tray-onlyEnabled true
say "enabled insightful-tray-only"

echo "==> Configuring the system tray on every panel"
# Panel and applet ids differ per machine, so discover the systray applets
# rather than hardcoding them. We hide the agent's own item (its
# StatusNotifierItem implements no Activate method, so left-click is dead) and
# show the proxy instead.
mapfile -t TRAYS < <(python3 - "$APPLETSRC" <<'PY'
import re, sys
try:
    text = open(sys.argv[1]).read()
except OSError:
    sys.exit(0)
group = None
for line in text.splitlines():
    line = line.strip()
    m = re.match(r'^\[Containments\]\[(\d+)\]\[Applets\]\[(\d+)\]$', line)
    if m:
        group = m.groups()
        continue
    if line.startswith('[') and not line.startswith('[Containments]'):
        group = None
    if line == 'plugin=org.kde.plasma.systemtray' and group:
        print(f"{group[0]} {group[1]}")
        group = None
PY
)

if [ "${#TRAYS[@]}" -eq 0 ]; then
    say "WARNING: no system tray applets found; configure manually via"
    say "         right-click tray -> Configure System Tray -> Entries"
else
    for entry in "${TRAYS[@]}"; do
        read -r cont applet <<<"$entry"
        cur=$(kreadconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
              --group Containments --group "$cont" --group Applets \
              --group "$applet" --group General --key hiddenItems 2>/dev/null || true)
        # Preserve anything already hidden; just add ours.
        hidden="workpuls-agent1"
        if [ -n "$cur" ]; then
            case ",$cur," in
                *,workpuls-agent1,*) hidden="$cur" ;;
                *) hidden="$cur,workpuls-agent1" ;;
            esac
        fi
        kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
            --group Containments --group "$cont" --group Applets \
            --group "$applet" --group General --key hiddenItems "$hidden"
        kwriteconfig6 --file plasma-org.kde.plasma.desktop-appletsrc \
            --group Containments --group "$cont" --group Applets \
            --group "$applet" --group General --key shownItems "Insightful"
        say "panel $cont / applet $applet -> show proxy, hide agent icon"
    done
fi

echo "==> Autostart entries"
cat > "$AUTOSTART/insightful.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Insightful
Exec=$BIN/insightful-start.sh
Icon=insightful
Terminal=false
StartupWMClass=workpuls-agent
X-GNOME-Autostart-enabled=true
EOF
cat > "$AUTOSTART/insightful-tray-proxy.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Insightful Tray Icon
Comment=Proxy tray icon giving the agent a working left-click, which its own tray item cannot do.
Exec=$BIN/insightful-tray-proxy.py
Icon=insightful
Terminal=false
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
EOF
install -m 644 "$AUTOSTART/insightful.desktop" \
        "$HOME/.local/share/applications/insightful.desktop"
say "autostart + app launcher entries written"

echo "==> Dependencies"
for pkg in python-pyqt6 python-dbus; do
    if pacman -Qq "$pkg" >/dev/null 2>&1; then say "$pkg present"
    else say "MISSING: $pkg  ->  sudo pacman -S $pkg"; fi
done

if [ "$RESTART" -eq 1 ]; then
    echo "==> Applying"
    qdbus6 org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
    kquitapp6 plasmashell 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -x plasmashell >/dev/null || break; sleep 0.5; done
    setsid plasmashell >/dev/null 2>&1 < /dev/null &
    sleep 5
    setsid "$BIN/insightful-tray-proxy.py" >/dev/null 2>&1 < /dev/null &
    say "plasmashell restarted, proxy started"
else
    say "skipped restart; log out and back in to apply"
fi

echo "==> Done"
