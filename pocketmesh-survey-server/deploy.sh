#!/usr/bin/env bash
set -euo pipefail

# deploy.sh — Pull latest code, back up the database, rebuild and restart the server.
# Usage: ./deploy.sh
#
# Backups are stored in ./backups/ with timestamps.
# To restore: cp backups/survey-YYYYMMDD-HHMMSS.sqlite data/survey.sqlite

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BACKUP_DIR="./backups"
DB_FILE="./data/survey.sqlite"
KEEP_BACKUPS=10

echo "=== PocketMesh Survey Server Deploy ==="

# 1. Pull latest code
echo ""
echo "--- Pulling latest code ---"
git pull

# 2. Back up the database (if it exists)
if [ -f "$DB_FILE" ]; then
    mkdir -p "$BACKUP_DIR"
    TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
    BACKUP_FILE="$BACKUP_DIR/survey-$TIMESTAMP.sqlite"

    # Use sqlite3 .backup for a safe online backup (no corruption risk)
    if command -v sqlite3 &> /dev/null; then
        echo "--- Backing up database (sqlite3 .backup) ---"
        sqlite3 "$DB_FILE" ".backup '$BACKUP_FILE'"
    else
        echo "--- Backing up database (file copy) ---"
        cp "$DB_FILE" "$BACKUP_FILE"
    fi

    BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
    echo "    Backup: $BACKUP_FILE ($BACKUP_SIZE)"

    # Prune old backups, keeping the most recent N
    BACKUP_COUNT=$(ls -1 "$BACKUP_DIR"/survey-*.sqlite 2>/dev/null | wc -l | tr -d ' ')
    if [ "$BACKUP_COUNT" -gt "$KEEP_BACKUPS" ]; then
        REMOVE_COUNT=$((BACKUP_COUNT - KEEP_BACKUPS))
        echo "    Pruning $REMOVE_COUNT old backup(s) (keeping $KEEP_BACKUPS)..."
        ls -1t "$BACKUP_DIR"/survey-*.sqlite | tail -n "$REMOVE_COUNT" | xargs rm -f
    fi
else
    echo "--- No existing database to back up (first deploy?) ---"
fi

# 3. Check .env exists
if [ ! -f ".env" ]; then
    echo ""
    echo "ERROR: .env file not found. Create it with:"
    echo "  SURVEY_API_KEY=<key>"
    echo "  SURVEY_API_KEY_OLD=<old-key>"
    echo "  MAPKIT_TEAM_ID=<team-id>"
    echo "  MAPKIT_KEY_ID=<key-id>"
    echo "  MAPKIT_PRIVATE_KEY=<pem-key>"
    exit 1
fi

# 4. Build the new image first (server stays up during build)
echo ""
echo "--- Building new image ---"
DOCKER_BUILDKIT=1 docker compose build

# 5. Swap: stop old container and start the new one
echo ""
echo "--- Swapping to new image ---"
docker compose down
docker compose up -d

# 6. Verify
echo ""
echo "--- Verifying ---"
sleep 3
if docker compose ps | grep -q "Up"; then
    echo "Server is running."
    docker compose logs --tail=5
else
    echo "WARNING: Server may not have started correctly."
    docker compose logs --tail=20
fi

echo ""
echo "=== Deploy complete ==="
