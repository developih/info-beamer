#!/usr/bin/env bash
# Runs every 5 minutes via cron.
# Fetches latest from GitHub; only restarts the server if server.py changed.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR" || exit 1

git fetch origin main --quiet 2>&1

BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null)

if [ "$BEHIND" -gt "0" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $BEHIND new commit(s) — updating..."

    # Apply update (safe: gitignored files like config.json/videos are untouched)
    git fetch origin main --quiet
    git reset --hard origin/main --quiet

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Update applied — restarting service..."
    sudo systemctl restart signage-server
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done."
fi
