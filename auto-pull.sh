#!/usr/bin/env bash
# Runs every 5 minutes via cron. Pulls latest from GitHub;
# if anything changed, restarts the signage server.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$REPO_DIR" || exit 1

# Fetch without merging so we can count commits behind
git fetch origin main --quiet 2>&1

BEHIND=$(git rev-list HEAD..origin/main --count 2>/dev/null)

if [ "$BEHIND" -gt "0" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $BEHIND new commit(s) — pulling..."
    git pull origin main --quiet
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restarting signage server..."
    sudo systemctl restart signage-server
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done."
fi
