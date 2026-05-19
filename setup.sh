#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Signage setup — run once on each Raspberry Pi
# Usage: bash setup.sh
# ─────────────────────────────────────────────────────────────
set -e

INSTALL_DIR="$HOME/signage"
SERVICE_USER="$(whoami)"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║        Signage Pi Setup              ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── 1. System packages ───────────────────────────────────────
echo "→ Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-venv \
    chromium-browser \
    unclutter \
    xdotool

# ── 2. Copy app files ────────────────────────────────────────
echo "→ Copying files to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/server.py"       "$INSTALL_DIR/"
cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"
cp -r "$SCRIPT_DIR/templates"    "$INSTALL_DIR/"
mkdir -p "$INSTALL_DIR/videos" "$INSTALL_DIR/assets"

if [ ! -f "$INSTALL_DIR/config.json" ]; then
    cp "$SCRIPT_DIR/config.json" "$INSTALL_DIR/"
    echo "   config.json created — edit it or use the admin panel."
else
    echo "   config.json already exists — keeping your settings."
fi

# ── 3. Python virtual environment ───────────────────────────
echo "→ Setting up Python environment..."
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -q -r "$INSTALL_DIR/requirements.txt"

# ── 4. Ask orientation ───────────────────────────────────────
echo ""
echo "Which orientation is this Pi?"
select ORI in "horizontal" "vertical"; do
    case $ORI in
        horizontal|vertical)
            python3 - <<PYEOF
import json, os
cfg_path = os.path.expanduser('$INSTALL_DIR/config.json')
with open(cfg_path) as f:
    cfg = json.load(f)
cfg['orientation'] = '$ORI'
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
print(f'   Orientation set to: $ORI')
PYEOF
            break;;
    esac
done

# ── 5. Systemd service — server ──────────────────────────────
echo "→ Creating signage-server systemd service..."
sudo tee /etc/systemd/system/signage-server.service > /dev/null <<EOF
[Unit]
Description=Signage HTTP server
After=network.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ── 6. Systemd service — Chromium kiosk ─────────────────────
echo "→ Creating signage-kiosk systemd service..."
sudo tee /etc/systemd/system/signage-kiosk.service > /dev/null <<EOF
[Unit]
Description=Signage Chromium kiosk
After=graphical.target signage-server.service
Requires=signage-server.service

[Service]
User=$SERVICE_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$SERVICE_USER/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/chromium-browser \\
    --kiosk \\
    --noerrdialogs \\
    --disable-infobars \\
    --no-first-run \\
    --disable-session-crashed-bubble \\
    --disable-restore-session-state \\
    --autoplay-policy=no-user-gesture-required \\
    http://localhost:8080
Restart=always
RestartSec=8

[Install]
WantedBy=graphical.target
EOF

# ── 7. Disable screen blanking ──────────────────────────────
echo "→ Disabling screen sleep / blanking..."
AUTOSTART_DIR="$HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
cat > "$AUTOSTART_DIR/disable-blanking.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Disable screen blanking
Exec=xset s off -dpms
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

# Also add to Xsession for good measure
XSESSION="$HOME/.xsessionrc"
grep -qxF 'xset s off -dpms' "$XSESSION" 2>/dev/null || echo 'xset s off -dpms' >> "$XSESSION"
grep -qxF 'xset -dpms' "$XSESSION" 2>/dev/null || echo 'xset -dpms' >> "$XSESSION"

# ── 8. Enable & start services ───────────────────────────────
echo "→ Enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable signage-server.service
sudo systemctl enable signage-kiosk.service
sudo systemctl start signage-server.service

echo ""
echo "╔══════════════════════════════════════╗"
echo "║           Setup complete!            ║"
echo "╚══════════════════════════════════════╝"
echo ""
echo "  Admin panel:  http://$(hostname -I | awk '{print $1}'):8080/admin"
echo "  Display:      http://$(hostname -I | awk '{print $1}'):8080"
echo ""
echo "  Next steps:"
echo "  1. Open the admin panel from any device on your network"
echo "  2. Upload your logo and videos"
echo "  3. Enter your city and OpenWeatherMap API key"
echo "  4. Reboot the Pi:  sudo reboot"
echo ""
