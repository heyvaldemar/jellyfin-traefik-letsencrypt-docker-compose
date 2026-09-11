#!/bin/bash
# End-to-end test for jellyfin-drop-orphans.sh.
#
# It builds a small library, then produces a real orphan the way a real library
# produces one: a library root moves away and never comes back under that path.
# A scan cannot enter a folder that is not there, so the rows below it stay -
# through that scan, through a restart, through every scan after. That is not a
# defect to work around, it is Jellyfin refusing to erase a library because a
# disk was slow, and it is exactly why a separate tool has to do this.
#
# Then it checks the parts that make the tool safe to hand to somebody:
# the report changes nothing, both refusals fire, the removal takes the rows the
# schema cascades AND the ones it does not, the healthy library is untouched,
# the database copy it leaves behind really does hold the pre-removal state, and
# Jellyfin comes back up on the edited database.
#
# Fixture video is produced by the ffmpeg inside the Jellyfin image under test:
# a file that is not really video is skipped by the scanner, and CI should not
# have to supply a codec to test a database tool.
#
# Requires: docker, docker compose, a running stack.
#
#   ./tests/e2e-orphan-cleanup.sh
#
# Tests are dispatched indirectly via run_test "$name"; shellcheck cannot trace
# that and flags every function as unused (SC2329).
# shellcheck disable=SC2329

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-jellyfin}"
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-jellyfin-traefik-letsencrypt-docker-compose.yml}"
MEDIA_DIR="${JELLYFIN_MEDIA_PATH:-./media}"
JF_USER="e2e-orphans"
JF_PASS="e2e-Orphans-Passw0rd"

dc() { docker compose -f "$DOCKER_COMPOSE_FILE" -p "$COMPOSE_PROJECT_NAME" "$@"; }

APP_CONTAINER="$(dc ps -aq jellyfin | head -n 1)"
[[ -n "$APP_CONTAINER" ]] || { echo "error: jellyfin container not found" >&2; exit 1; }
JF_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$APP_CONTAINER")"

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

TOKEN=""
# Every call goes out from inside the Jellyfin container, which reaches the
# server on loopback. No published port, no hostname, no certificate.
jf() {
  local method="$1" path="$2" body="${3:-}"
  local auth='MediaBrowser Client="e2e", Device="e2e", DeviceId="e2e-orphans", Version="1"'
  [[ -n "$TOKEN" ]] && auth="$auth, Token=\"$TOKEN\""
  local args=(curl -sS -X "$method" -H "Content-Type: application/json" -H "Authorization: $auth")
  [[ -n "$body" ]] && args+=(--data "$body")
  args+=("http://127.0.0.1:8096$path")
  docker exec "$APP_CONTAINER" "${args[@]}"
}

# Tolerant of an empty or non-JSON body: a transient miss should read as an
# empty value in the caller's own error message, not as a stack trace from a
# helper.
json_field() {
  python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('$1', ''))
except Exception:
    print('')"
}

# The tool's own container, with a fixture script mounted beside it, so the
# assertions read the same database through the same mount the tool uses.
fixture() {
  dc run --rm --no-deps \
    -v "$REPO_ROOT/tests/orphan-fixture.py:/opt/fixture.py:ro" \
    --entrypoint python3 orphans /opt/fixture.py "$@" 2>/dev/null | tr -d '\r'
}

ffmpeg_make() {
  docker run --rm -v "$(cd "$MEDIA_DIR" && pwd)":/out \
    --entrypoint /usr/lib/jellyfin-ffmpeg/ffmpeg "$JF_IMAGE" \
    -loglevel error -f lavfi -i testsrc=d=1:s=64x64 -c:v libx264 -pix_fmt yuv420p \
    -y "/out/$1" > /dev/null
}

wait_for_scan() {
  local elapsed=0
  sleep 3
  while [[ $elapsed -lt 180 ]]; do
    if ! jf GET /ScheduledTasks | grep -q '"State":"Running"'; then sleep 4; return 0; fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "  a scheduled task is still running after 180s" >&2
  return 1
}

# /health answers while the API is still returning 503 behind a "please wait"
# page. Waiting on it alone is what made the first version of this test post the
# whole startup wizard into a server that was not listening for it yet: the
# calls failed, the last one landed once the server was ready, and the wizard
# closed with no user ever created. Wait for the API.
wait_for_api() {
  local elapsed=0 body=""
  while [[ $elapsed -lt 240 ]]; do
    # The status code is not enough. There is a window during startup where the
    # API answers 200 with an empty body, and a wizard call made in that window
    # fails silently. Wait for content.
    body="$(docker exec "$APP_CONTAINER" curl -s http://127.0.0.1:8096/System/Info/Public 2>/dev/null)" || body=""
    [[ "$body" == *'"Version"'* ]] && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "  the Jellyfin API did not return its version within 240s" >&2
  return 1
}

wizard_completed() {
  jf GET /System/Info/Public | json_field StartupWizardCompleted
}

# No internet metadata: a test of a database tool should not depend on what a
# metadata provider thinks a file called "Delta S01E01" is.
library_options() {
  printf '{"LibraryOptions":{"PathInfos":[{"Path":"%s"}],"EnableRealtimeMonitor":false,"SaveLocalMetadata":false,"TypeOptions":[]}}' "$1"
}

setup() {
  echo "=== setup: a library with two roots, on real video ==="
  wait_for_api
  mkdir -p "$MEDIA_DIR/Movies/Alpha (2001)" "$MEDIA_DIR/Movies/Beta (2002)" \
           "$MEDIA_DIR/Shows/Delta/Season 01" "$MEDIA_DIR/Shows/Delta/Season 02"
  ffmpeg_make "Movies/Alpha (2001)/Alpha (2001).mkv"
  ffmpeg_make "Movies/Beta (2002)/Beta (2002).mkv"
  ffmpeg_make "Shows/Delta/Season 01/Delta S01E01.mkv"
  ffmpeg_make "Shows/Delta/Season 02/Delta S02E01.mkv"

  # Ordered and checked, not fired off with || true. A wizard call that fails
  # silently leaves a server nobody can log into, and the failure surfaces
  # several tests later as something that looks unrelated.
  if [[ "$(wizard_completed)" == "False" ]]; then
    jf POST /Startup/Configuration \
       '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' > /dev/null
    # The GET is not a formality. POST /Startup/User renames the default
    # account; the default account does not exist until something asks for it,
    # and the GET is what asks. Without it the POST reports success, creates
    # nobody, and the wizard closes on a server with no users at all.
    jf GET /Startup/User > /dev/null
    jf POST /Startup/User "{\"Name\":\"$JF_USER\",\"Password\":\"$JF_PASS\"}" > /dev/null
    jf POST /Startup/Complete '{}' > /dev/null
    echo "  startup wizard completed, user $JF_USER created"
  else
    echo "  the startup wizard was already completed"
  fi

  TOKEN="$(jf POST /Users/AuthenticateByName \
    "{\"Username\":\"$JF_USER\",\"Pw\":\"$JF_PASS\"}" | json_field AccessToken)"
  if [[ -z "$TOKEN" ]]; then
    echo "could not authenticate as $JF_USER. If the wizard was completed by an" >&2
    echo "earlier run without creating this user, remove the config volume and" >&2
    echo "bring the stack up again." >&2
    return 1
  fi
  echo "  authenticated"

  jf POST "/Library/VirtualFolders?name=E2E%20Movies&collectionType=movies&refreshLibrary=false" \
     "$(library_options /media/Movies)" > /dev/null
  jf POST "/Library/VirtualFolders?name=E2E%20Shows&collectionType=tvshows&refreshLibrary=false" \
     "$(library_options /media/Shows)" > /dev/null
  jf POST /Library/Refresh '{}' > /dev/null
  wait_for_scan
  echo "  library scanned: $(fixture counts)"
}

test_the_library_is_there_to_begin_with() {
  local c; c="$(fixture counts)"
  echo "  $c"
  grep -q 'movies=[1-9]' <<<"$c" || { echo "  no rows under /media/Movies" >&2; return 1; }
  grep -q 'shows=[1-9]'  <<<"$c" || { echo "  no rows under /media/Shows" >&2; return 1; }
  fixture seed | grep -q 'seeded=[1-9]' || { echo "  could not seed dependent rows" >&2; return 1; }
  grep -q 'dangling=0' <<<"$(fixture counts)" || { echo "  seeded rows are already dangling" >&2; return 1; }
  echo "  dependent rows seeded for every item, none dangling"
}

test_a_root_that_moves_away_leaves_rows_behind() {
  local before after
  before="$(fixture counts | tr ' ' '\n' | grep '^shows=' | cut -d= -f2)"
  mv "$MEDIA_DIR/Shows" "$MEDIA_DIR/Shows-archive"
  jf POST /Library/Refresh '{}' > /dev/null
  wait_for_scan
  docker restart "$APP_CONTAINER" > /dev/null
  wait_for_api
  jf POST /Library/Refresh '{}' > /dev/null
  wait_for_scan
  after="$(fixture counts | tr ' ' '\n' | grep '^shows=' | cut -d= -f2)"
  [[ "$after" == "$before" && "$after" -gt 0 ]] || {
    echo "  expected the $before rows under the moved root to survive, found $after" >&2
    return 1
  }
  echo "  $after rows still point at /media/Shows after a scan, a restart and another scan"
}

test_the_report_names_the_missing_folder_and_changes_nothing() {
  local before out
  before="$(fixture counts)"
  out="$(./jellyfin-drop-orphans.sh)"
  printf '%s\n' "$out" | sed 's/^/    /'
  grep -q '/media/Shows is not there' <<<"$out" || {
    echo "  the report does not name the folder that went away" >&2; return 1; }
  grep -q 'dry run, nothing changed' <<<"$out" || {
    echo "  the report does not say it changed nothing" >&2; return 1; }
  [[ "$(fixture counts)" == "$before" ]] || { echo "  the report changed the database" >&2; return 1; }
  echo "  the folder is named, and nothing moved"
}

test_it_refuses_above_the_limit() {
  local before rc=0
  before="$(fixture counts)"
  JELLYFIN_ORPHAN_LIMIT=1 ./jellyfin-drop-orphans.sh > /tmp/orphan-limit.log 2>&1 || rc=$?
  [[ $rc -eq 2 ]] || { echo "  expected exit 2, got $rc" >&2; cat /tmp/orphan-limit.log >&2; return 1; }
  grep -q 'REFUSED' /tmp/orphan-limit.log || { echo "  no refusal in the output" >&2; return 1; }
  [[ "$(fixture counts)" == "$before" ]] || { echo "  it changed the database anyway" >&2; return 1; }
  echo "  refused, exit 2, database untouched"
}

test_it_refuses_when_the_library_is_not_mounted() {
  local empty rc=0
  empty="$(mktemp -d)"
  # mktemp makes it 0700, and this test is about an EMPTY library, not an
  # unreadable one. On a real runner those are two different failures with two
  # different messages, and a 0700 directory would quietly test the wrong one.
  chmod 755 "$empty"
  dc run --rm --no-deps -v "$empty:/media:ro" orphans dry > /tmp/orphan-empty.log 2>&1 || rc=$?
  rmdir "$empty"
  [[ $rc -ne 0 ]] || { echo "  it accepted an empty media mount" >&2; return 1; }
  grep -q 'REFUSED' /tmp/orphan-empty.log || { echo "  no refusal in the output" >&2; cat /tmp/orphan-empty.log >&2; return 1; }
  echo "  an empty library mount is refused, not read as a deleted library"
}

test_apply_removes_the_orphans_and_leaves_the_rest() {
  local out movies_before
  movies_before="$(fixture counts | tr ' ' '\n' | grep '^movies=' | cut -d= -f2)"
  out="$(JELLYFIN_ORPHANS_ASSUME_YES=1 ./jellyfin-drop-orphans.sh apply)"
  printf '%s\n' "$out" | sed 's/^/    /'
  local after; after="$(fixture counts)"
  echo "  $after"
  grep -q 'shows=0' <<<"$after" || { echo "  rows under the moved root survived" >&2; return 1; }
  grep -q "movies=$movies_before" <<<"$after" || { echo "  the healthy library lost rows" >&2; return 1; }
  grep -q 'dangling=0' <<<"$after" || { echo "  dependent rows were left behind" >&2; return 1; }
  # The four tables the schema does not cascade are the ones a hand-written
  # delete forgets; if they still hold the doomed items' rows, dangling above
  # would have caught it, and this names which half did the work.
  grep -q 'the tables the schema does not cascade' <<<"$out" || {
    echo "  nothing was removed from the non-cascading tables" >&2; return 1; }
  echo "  orphans gone, healthy library intact, no dependent rows left dangling"
}

test_the_database_copy_holds_the_state_from_before() {
  local backups newest
  backups="$(dc run --rm --no-deps --entrypoint sh orphans -c \
    "ls -1 ${DATA_BACKUPS_PATH:-/srv/jellyfin-config/backups}/jellyfin-db-before-orphan-drop-*.db" 2>/dev/null | tr -d '\r')"
  newest="$(printf '%s\n' "$backups" | sort | tail -1)"
  [[ -n "$newest" ]] || { echo "  no database copy was written" >&2; return 1; }
  local c; c="$(fixture counts "$newest")"
  echo "  $newest"
  echo "  $c"
  grep -q 'shows=[1-9]' <<<"$c" || {
    echo "  the copy does not hold the rows that were about to be removed" >&2; return 1; }
  echo "  the copy opens and holds the pre-removal state"
}

test_jellyfin_comes_back_on_the_edited_database() {
  wait_for_api
  TOKEN="$(jf POST /Users/AuthenticateByName \
    "{\"Username\":\"$JF_USER\",\"Pw\":\"$JF_PASS\"}" | json_field AccessToken)"
  [[ -n "$TOKEN" ]] || { echo "  could not authenticate after the edit" >&2; return 1; }
  local n
  n="$(jf GET '/Items?recursive=true&includeItemTypes=Movie' | json_field TotalRecordCount)"
  [[ "$n" -ge 2 ]] || { echo "  expected the movies to still be listed, got $n" >&2; return 1; }
  echo "  Jellyfin is healthy and still lists $n movies"
}

setup

run_test test_the_library_is_there_to_begin_with
run_test test_a_root_that_moves_away_leaves_rows_behind
run_test test_the_report_names_the_missing_folder_and_changes_nothing
run_test test_it_refuses_above_the_limit
run_test test_it_refuses_when_the_library_is_not_mounted
run_test test_apply_removes_the_orphans_and_leaves_the_rest
run_test test_the_database_copy_holds_the_state_from_before
run_test test_jellyfin_comes_back_on_the_edited_database

echo
echo "=== $PASSED passed, $FAILED failed ==="
if [[ $FAILED -gt 0 ]]; then
  printf '  %s\n' "${FAILURES[@]}" >&2
  exit 1
fi
