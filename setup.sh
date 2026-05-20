#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# Signage setup — run once on each Raspberry Pi
# Usage: bash setup.sh
# ─────────────────────────────────────────────────────────────
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    chromium \
    unclutter \
    xdotool

# ── 2. Create data directories inside repo ──────────────────
echo "→ Creating data directories..."
mkdir -p "$REPO_DIR/videos" "$REPO_DIR/assets" "$REPO_DIR/overlays"

# ── 3. Config (only created if missing) ─────────────────────
if [ ! -f "$REPO_DIR/config.json" ]; then
    cat > "$REPO_DIR/config.json" <<'JSEOF'
{
  "city": "Buenos Aires",
  "weather_api_key": "",
  "orientation": "horizontal",
  "logo_size": 100,
  "schedule_on": "07:00",
  "schedule_off": "19:00"
}
JSEOF
    echo "   config.json created — edit it or use the admin panel."
else
    echo "   config.json already exists — keeping your settings."
fi

# ── 4. Python virtual environment ───────────────────────────
echo "→ Setting up Python environment..."
python3 -m venv "$REPO_DIR/venv"
"$REPO_DIR/venv/bin/pip" install -q --upgrade pip
"$REPO_DIR/venv/bin/pip" install -q -r "$REPO_DIR/requirements.txt"

# ── 5. Ask orientation ───────────────────────────────────────
echo ""
echo "Which orientation is this Pi?"
select ORI in "horizontal" "vertical"; do
    case $ORI in
        horizontal|vertical)
            python3 - <<PYEOF
import json, os
cfg_path = '$REPO_DIR/config.json'
with open(cfg_path) as f:
    cfg = json.load(f)
cfg['orientation'] = '$ORI'
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
print('   Orientation set to: $ORI')
PYEOF
            break;;
    esac
done

# ── 6. Systemd service — server ──────────────────────────────
echo "→ Creating signage-server systemd service..."
sudo tee /etc/systemd/system/signage-server.service > /dev/null <<EOF
[Unit]
Description=Signage HTTP server
After=network.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$REPO_DIR
ExecStart=$REPO_DIR/venv/bin/python $REPO_DIR/server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ── 7. Chromium kiosk autostart ─────────────────────────────
echo "→ Setting up Chromium kiosk autostart..."

# XDG standard — works on any desktop environment
AUTOSTART_DIR="$HOME/.config/autostart"
mkdir -p "$AUTOSTART_DIR"
cat > "$AUTOSTART_DIR/signage-kiosk.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Signage Kiosk
Exec=bash -c 'sleep 10 && chromium --kiosk --noerrdialogs --disable-infobars --no-first-run --disable-session-crashed-bubble --disable-restore-session-state --autoplay-policy=no-user-gesture-required http://localhost:8080'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

# LXDE-pi session autostart (belt-and-suspenders)
LXDE_DIR="$HOME/.config/lxsession/LXDE-pi"
mkdir -p "$LXDE_DIR"
cat > "$LXDE_DIR/autostart" <<'EOF'
@xset s off
@xset -dpms
@xset s noblank
@unclutter -idle 1 -root
@bash -c 'sleep 10 && chromium --kiosk --noerrdialogs --disable-infobars --no-first-run --disable-session-crashed-bubble --disable-restore-session-state --autoplay-policy=no-user-gesture-required http://localhost:8080'
EOF

# ── 8. Disable screen blanking ──────────────────────────────
echo "→ Disabling screen sleep / blanking..."
XSESSION="$HOME/.xsessionrc"
grep -qxF 'xset s off -dpms' "$XSESSION" 2>/dev/null || echo 'xset s off -dpms' >> "$XSESSION"
grep -qxF 'xset -dpms' "$XSESSION" 2>/dev/null || echo 'xset -dpms' >> "$XSESSION"

# ── 9. Auto-pull cron job (every 5 min) ─────────────────────
echo "→ Setting up auto-pull cron job..."
chmod +x "$REPO_DIR/auto-pull.sh"
CRON_CMD="*/5 * * * * $REPO_DIR/auto-pull.sh >> $REPO_DIR/pull.log 2>&1"
( crontab -l 2>/dev/null | grep -v 'auto-pull.sh'; echo "$CRON_CMD" ) | crontab -

# Sudoers rule so cron can restart the server without a password
if ! sudo grep -qF "signage" /etc/sudoers.d/signage 2>/dev/null; then
    echo "$SERVICE_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart signage-server" \
        | sudo tee /etc/sudoers.d/signage > /dev/null
    sudo chmod 0440 /etc/sudoers.d/signage
fi

# ── 10. Enable & start services ──────────────────────────────
echo "→ Enabling services..."
sudo systemctl daemon-reload
sudo systemctl enable signage-server.service
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
