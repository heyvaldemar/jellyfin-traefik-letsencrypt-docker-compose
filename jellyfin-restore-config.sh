#!/bin/bash

# Restore Jellyfin's config directory from one of the archives the `backups`
# container has taken.
#
# That directory is everything Jellyfin knows apart from the files themselves:
# users and their passwords, the library database with watch state and
# resume positions, downloaded metadata and artwork, plugins and their
# settings, and the API keys any client was given.
#
#     chmod +x jellyfin-restore-config.sh
#     ./jellyfin-restore-config.sh
#
# The media library is NOT in the archive and is not touched by this script.
# It is mounted read-only and is the one thing a backup of this size cannot
# sensibly hold; back it up wherever it actually lives.
#
# The transcoding cache is not in the archive either. Jellyfin rebuilds it.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-jellyfin-traefik-letsencrypt-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-jellyfin}"
BACKUP_PATH="${DATA_BACKUPS_PATH:-/srv/jellyfin-config/backups}"
RESTORE_PATH="${DATA_PATH:-/config}"

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

APP_CONTAINER="$(dc ps -aq jellyfin | head -n 1)"
BACKUPS_CONTAINER="$(dc ps -aq backups | head -n 1)"
[ -n "$APP_CONTAINER" ] || { echo "the jellyfin container was not found — is the stack up?" >&2; exit 1; }
[ -n "$BACKUPS_CONTAINER" ] || { echo "the backups container was not found — is the stack up?" >&2; exit 1; }

echo "--> All available config backups:"
docker exec "$BACKUPS_CONTAINER" sh -c "ls -1 $BACKUP_PATH" || true

echo "--> Copy and paste the backup name from the list above and press [ENTER]
--> Example: jellyfin-config-backup-YYYY-MM-DD_hh-mm.tar.gz"
echo -n "--> "
read -r SELECTED
[ -n "$SELECTED" ] || { echo "nothing selected, nothing restored" >&2; exit 1; }

if ! docker exec "$BACKUPS_CONTAINER" sh -c "tar -tzf '${BACKUP_PATH}/${SELECTED}' > /dev/null"; then
  echo "that file is not a readable tar archive — nothing has been stopped or deleted" >&2
  exit 1
fi
echo "--> $SELECTED was selected and reads as a valid archive"

echo "--> Stopping Jellyfin..."
docker stop "$APP_CONTAINER" > /dev/null

echo "--> Restoring the config directory..."
# The archive stores paths relative to /, so it extracts there. The directory
# is emptied first: a restore that merges leaves rows in the old library
# database that the archive never had.
docker exec "$BACKUPS_CONTAINER" sh -c "rm -rf '${RESTORE_PATH:?}'/* && tar -zxpf '${BACKUP_PATH}/${SELECTED}' -C /"
echo "--> Config recovery completed."

echo "--> Starting Jellyfin..."
docker start "$APP_CONTAINER" > /dev/null
echo "--> Jellyfin answers once it has opened the restored library database."
echo "--> Artwork and chapter images regenerate on demand; a library scan is not required."
