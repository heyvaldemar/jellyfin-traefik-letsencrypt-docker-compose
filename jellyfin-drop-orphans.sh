#!/bin/bash

# Find - and on request remove - library rows whose file is no longer on disk.
#
#     chmod +x jellyfin-drop-orphans.sh
#     ./jellyfin-drop-orphans.sh            # report only, Jellyfin keeps running
#     ./jellyfin-drop-orphans.sh apply      # stop, remove, start
#
# The report is read-only and safe at any time. The removal stops Jellyfin
# first, and that is not a courtesy: SQLite will let a second process write the
# library database while Jellyfin has it open, and nothing will say a word about
# it until the library is wrong. Measured, not assumed - an exclusive lock is
# granted against a running Jellyfin, so "can I take the lock?" is not a test of
# anything.
#
# The work happens in the `orphans` container, which has the database and the
# media mount and no Docker socket. Stopping the server is the host's job,
# because the host is the only side of that line that should be able to.
#
# The reasoning about what is and is not safe to delete is in
# jellyfin-drop-orphans.py, which this runs.
set -euo pipefail
cd "$(dirname "$0")"

COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-jellyfin-traefik-letsencrypt-docker-compose.yml}"
PROJECT="${COMPOSE_PROJECT_NAME:-jellyfin}"
MODE="${1:-dry}"

case "$MODE" in
  dry|apply) ;;
  *) echo "usage: $0 [dry|apply]" >&2; exit 1 ;;
esac

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

[ -f jellyfin-drop-orphans.py ] || {
  echo "jellyfin-drop-orphans.py is not next to this script, and it is what does" >&2
  echo "the work. Download it from the same place you got the compose file." >&2
  exit 1
}

APP_CONTAINER="$(dc ps -aq jellyfin | head -n 1)"
[ -n "$APP_CONTAINER" ] || { echo "the jellyfin container was not found - is the stack up?" >&2; exit 1; }

# --no-deps so this never starts anything. It matters below, where Jellyfin has
# deliberately been stopped and must stay that way while the database is open.
echo "--> Looking for library rows whose file is missing..."
set +e
REPORT="$(dc run --rm --no-deps orphans dry 2>&1)"
RC=$?
set -e
printf '%s\n' "$REPORT"
[ "$RC" -eq 0 ] || exit "$RC"
[ "$MODE" = apply ] || exit 0

# Read from the report already printed rather than scanning a second time: two
# scans can disagree, and the one the operator is about to approve should be the
# one they just read.
printf '%s\n' "$REPORT" | grep -q '^  orphans:  [1-9]' || {
  echo "--> Nothing to remove."
  exit 0
}

if [ "${JELLYFIN_ORPHANS_ASSUME_YES:-}" != "1" ]; then
  echo "--> This stops Jellyfin, removes the rows listed above and starts it again."
  echo "--> A copy of the database is written to the backups volume first."
  echo -n "--> Type yes to go ahead: "
  read -r CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo "nothing was stopped or changed"; exit 0; }
fi

echo "--> Stopping Jellyfin..."
docker stop "$APP_CONTAINER" > /dev/null

# Judged by state, not by the exit status of docker stop. A stop can report
# success while the container is still on its way down, and the whole safety of
# what follows rests on this one fact being true rather than likely.
RUNNING=unknown
for _ in $(seq 30); do
  RUNNING="$(docker inspect -f '{{.State.Running}}' "$APP_CONTAINER" 2>/dev/null || echo unknown)"
  [ "$RUNNING" = "false" ] && break
  sleep 1
done
if [ "$RUNNING" != "false" ]; then
  echo "--> Jellyfin is still running ($RUNNING). Nothing has been changed." >&2
  exit 1
fi
echo "--> Jellyfin is stopped."

set +e
dc run --rm --no-deps orphans apply
RC=$?
set -e

echo "--> Starting Jellyfin..."
docker start "$APP_CONTAINER" > /dev/null
echo "--> Jellyfin answers once it has opened the library database."
exit "$RC"
