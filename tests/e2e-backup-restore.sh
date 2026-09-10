#!/bin/bash
# End-to-end tests for the jellyfin-traefik-letsencrypt-docker-compose
# backup + restore flow.
#
# This application keeps everything it knows in one directory: a SQLite file
# and a few upload folders. There is no database server to dump, so the archive
# IS the database, and the test that matters is whether a file written before a
# backup comes back after a restore that has since destroyed it.
#
# Requires: docker, docker compose. Assumes the stack is already up with short
# backup intervals in .env (CI uses INIT_SLEEP=15s, INTERVAL=60s).
#
#   ./tests/e2e-backup-restore.sh
#
# Tests are dispatched indirectly via run_test "$name"; shellcheck cannot trace
# that and flags every function as unused (SC2329).
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-jellyfin}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-jellyfin-traefik-letsencrypt-docker-compose.yml}"

if [[ -f .env ]]; then
  # Read, do not execute. A compose .env file is key=value with literal values,
  # not a shell script.
  while IFS='=' read -r _k _v; do
    [[ -n "$_k" ]] || continue
    export "${_k}=${_v}"
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env)
  unset _k _v
else
  echo "error: .env not found at $REPO_ROOT/.env" >&2
  exit 1
fi

: "${DATA_BACKUPS_PATH:=/srv/jellyfin-config/backups}"
: "${DATA_BACKUP_NAME:=jellyfin-config-backup}"
: "${DATA_PATH:=/config}"
: "${BACKUP_INTERVAL:=24h}"

BACKUPS_PATH="${DATA_BACKUPS_PATH%/}"
MARKER="${DATA_PATH%/}/.e2e-marker"

# Resolve containers through compose, not by name: a container_name override
# would defeat a docker ps name filter.
BACKUPS_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq backups | head -n 1)"
APP_CONTAINER="$(docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" ps -aq jellyfin | head -n 1)"
[[ -n "$BACKUPS_CONTAINER" ]] || { echo "error: backups container not found" >&2; exit 1; }
[[ -n "$APP_CONTAINER" ]] || { echo "error: jellyfin container not found" >&2; exit 1; }

interval_seconds() {
  local v="$BACKUP_INTERVAL"
  case "$v" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}
CYCLE_WAIT=$(( $(interval_seconds) + 90 ))

PASSED=0
FAILED=0
FAILURES=()
run_test() {
  local name="$1"
  echo
  echo "=== $name ==="
  if "$name"; then
    echo "  PASS: $name"; PASSED=$((PASSED + 1))
  else
    echo "  FAIL: $name" >&2; FAILED=$((FAILED + 1)); FAILURES+=("$name")
  fi
}

bk() { docker exec "$BACKUPS_CONTAINER" sh -c "$1"; }

list_backups() {
  bk "ls -1 ${BACKUPS_PATH}/${DATA_BACKUP_NAME}-*.tar.gz 2>/dev/null" | grep -v '\.failed$' | sort || true
}

# The first archive taken after the marker existed. A file that exists is not
# yet a backup: the loop may still be writing it, so this waits for the
# "backup OK" line that names it.
post_marker_backup() {
  local f elapsed=0
  while :; do
    f=$(bk "find ${BACKUPS_PATH} -name '${DATA_BACKUP_NAME}-*.tar.gz' -newer ${BACKUPS_PATH}/.e2e-stamp 2>/dev/null | sort | head -1")
    if [[ -n "$f" ]] && docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -qF "backup OK: $f"; then echo "$f"; return 0; fi
    [[ $elapsed -lt $CYCLE_WAIT ]] || return 1
    sleep 5; elapsed=$((elapsed + 5))
  done
}

test_env_required() {
  grep -qE '^JELLYFIN_HOSTNAME=.' .env || { echo "  JELLYFIN_HOSTNAME is not set in .env" >&2; return 1; }
  grep -qE '^TRAEFIK_ACME_EMAIL=.' .env || { echo "  TRAEFIK_ACME_EMAIL is not set in .env" >&2; return 1; }
  echo "  the required variables are present"
}

test_backup_created() {
  local elapsed=0
  echo "  waiting up to 180s for the first backup..."
  while [[ $elapsed -lt 180 ]]; do
    [[ -n "$(list_backups)" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  local first; first=$(list_backups | head -1)
  [[ -n "$first" ]] || { echo "  no archive appeared" >&2; return 1; }
  echo "  first backup: $first ($(bk "stat -c %s '$first'") bytes)"
}

test_backup_readable() {
  local f; f=$(list_backups | tail -1)
  bk "tar -tzf '$f' > /dev/null" || { echo "  $f is not a readable archive" >&2; return 1; }
  echo "  archive reads: $f"
}

test_backup_carries_the_data_directory() {
  local f; f=$(list_backups | tail -1)
  bk "tar -tzf '$f' | grep -q '^config/'" || { echo "  $f does not carry the config directory" >&2; return 1; }
  echo "  the archive carries the data directory"
}

test_failure_is_detected() {
  # The data directory and the backup directory are both volume mounts, so
  # neither can be moved or unmounted from inside the container. What CAN be
  # taken away is the destination file: the loop writes
  # <prefix>-<stamp>.tar.gz.partial, and a DIRECTORY sitting at that exact path
  # is something tar cannot write to. The stamp is the minute, so the next few
  # minutes are blocked and the loop hits one of them on its next cycle.
  echo "  blocking the next few destination names"
  local blocked=()
  # The stamps are computed here rather than in the container: BusyBox date
  # has no relative-time option, so asking it for "+2 minutes" returns an
  # error and every stamp would be the same minute.
  local i stamp path
  for i in 0 1 2 3 4; do
    stamp=$(python3 -c "import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(minutes=int(sys.argv[1]))).strftime('%Y-%m-%d_%H-%M'))" "$i")
    path="${BACKUPS_PATH}/${DATA_BACKUP_NAME}-${stamp}.tar.gz.partial"
    bk "rm -rf '${path}' && mkdir -p '${path}'" || return 1
    blocked+=("$path")
  done
  local before after elapsed=0
  before=$(docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -c 'Data backup FAILED' || true)
  while [[ $elapsed -lt $CYCLE_WAIT ]]; do
    after=$(docker logs "$BACKUPS_CONTAINER" 2>&1 | grep -c 'Data backup FAILED' || true)
    [[ "$after" -gt "$before" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  for i in "${blocked[@]}"; do bk "rm -rf '$i'" || true; done
  [[ "$after" -gt "$before" ]] || { echo "  no new FAILED line appeared while the destination was unwritable" >&2; return 1; }
  echo "  the loop reported the failure instead of leaving a file that looks like a backup"
  # And nothing that failed is sitting there pretending to be an archive.
  local bogus; bogus=$(bk "ls -1 ${BACKUPS_PATH}/${DATA_BACKUP_NAME}-*.tar.gz 2>/dev/null" | while read -r f; do
    bk "tar -tzf '$f' > /dev/null 2>&1" || echo "$f"; done)
  [[ -z "$bogus" ]] || { echo "  an unreadable file is named like a backup: $bogus" >&2; return 1; }
  echo "  every file named like a backup still reads as one"
}

test_restore_roundtrip() {
  # A file written before the backup, destroyed after it, and back once the
  # archive is restored. This is the whole promise in three steps.
  bk "echo e2e > ${MARKER} && touch ${BACKUPS_PATH}/.e2e-stamp"
  local f
  echo "  waiting for the first archive taken after the marker..."
  f=$(post_marker_backup) || { echo "  no archive appeared within one cycle" >&2; return 1; }
  echo "  baseline: $f"
  bk "rm -f ${MARKER}"
  bk "test ! -f ${MARKER}" || { echo "  the marker did not go away" >&2; return 1; }
  docker stop "$APP_CONTAINER" > /dev/null
  bk "rm -rf ${DATA_PATH:?}/* && tar -zxpf '$f' -C /"
  docker start "$APP_CONTAINER" > /dev/null
  bk "test -f ${MARKER}" || { echo "  the marker did not come back — the archive is not restorable" >&2; return 1; }
  bk "rm -f ${MARKER} ${BACKUPS_PATH}/.e2e-stamp"
  echo "  the marker came back — the backup is restorable"
}

test_prune_removes_old() {
  local fake="${BACKUPS_PATH}/${DATA_BACKUP_NAME}-0000-00-00_00-00.tar.gz"
  echo "  placing a fake file dated 2020 at $fake"
  bk "cp \$(ls -1 ${BACKUPS_PATH}/${DATA_BACKUP_NAME}-*.tar.gz | head -1) ${fake} && touch -d 2020-01-01 ${fake}"
  local elapsed=0
  echo "  waiting up to ${CYCLE_WAIT}s for the next prune cycle..."
  while [[ $elapsed -lt $CYCLE_WAIT ]]; do
    bk "test ! -f ${fake}" && { echo "  the old file was pruned"; return 0; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "  the old file is still there after a full cycle" >&2
  return 1
}

echo "=== Deployment Verification: backup/restore E2E tests ==="
echo "  project=$COMPOSE_PROJECT_NAME backups=$BACKUPS_CONTAINER app=$APP_CONTAINER"
echo "  path=$BACKUPS_PATH prefix=$DATA_BACKUP_NAME interval=$BACKUP_INTERVAL"

run_test test_env_required
run_test test_backup_created
run_test test_backup_readable
run_test test_backup_carries_the_data_directory
run_test test_failure_is_detected
run_test test_restore_roundtrip
run_test test_prune_removes_old

echo
echo "==============================="
echo "Passed: $PASSED  Failed: $FAILED"
if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
[[ $FAILED -eq 0 ]]
