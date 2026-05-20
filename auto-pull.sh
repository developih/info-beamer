#!/usr/bin/env bash
# Runs every 5 minutes via cron.
# Fetches latest from GitHub; only restarts the server if there are new commits.
# Also checks server health and Chromium kiosk process — relaunches if either is down.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR" || exit 1

# ── 1. Pull updates from GitHub ───────────────────────────────
git fetch origin main --quiet 2>&1

BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null)

if [ "$BEHIND" -gt "0" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $BEHIND new commit(s) — updating..."
    git reset --hard origin/main --quiet
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Update applied — restarting service..."
    sudo systemctl restart signage-server
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done."
fi

# ── 2. Server health check — restart if not responding ────────
if ! curl -sf --max-time 5 http://localhost:8080/health > /dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Server not responding — restarting..."
    sudo systemctl restart signage-server
fi

# ── 3. Chromium watchdog — relaunch kiosk if crashed ──────────
if ! pgrep -f "chromium.*kiosk" > /dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Chromium not running — relaunching..."
    DISPLAY=:0 XAUTHORITY="$HOME/.Xauthority" nohup chromium \
        --kiosk --noerrdialogs --disable-infobars --no-first-run \
        --disable-session-crashed-bubble --disable-restore-session-state \
        --autoplay-policy=no-user-gesture-required \
        http://localhost:8080 > /dev/null 2>&1 &
fi
