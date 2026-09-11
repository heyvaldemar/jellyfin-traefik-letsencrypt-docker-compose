# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.1.1] - 2026-09-11

### Fixed

- **An unreadable library was a stack trace, and it should have been the
  loudest refusal in the tool.** `os.path.exists` answers False for a path it
  is not allowed to look at exactly as it does for one that is not there, so a
  media root the container cannot read makes every row in the library look like
  an orphan. That is the single input that turns this tool into the accident it
  exists to prevent. It is now checked before any path is examined, and it
  refuses with a line that says which directory and why.

- **The orphans container could not read a library that was not
  world-readable.** `cap_drop: ALL` takes `DAC_READ_SEARCH` with it, and root
  without that capability cannot enter a `0700` directory owned by somebody
  else. Jellyfin itself keeps the default capability set and reads it fine, so
  the two containers disagreed about what exists. The container now adds back
  `DAC_READ_SEARCH` and only that: the right to read any file and traverse any
  directory, with no right to write a byte anywhere. `DAC_OVERRIDE` would have
  worked too, and would have handed it write access to the media it must never
  touch.

  Found by CI on a real runner. It could not be found locally: Docker Desktop
  virtualises bind-mount ownership, so the permission never bites on a Mac.

## [1.1.0] - 2026-09-11

### Added

- **A tool for library rows whose file is gone.** `jellyfin-drop-orphans.sh`
  reports them, and on request removes them.

  A library scan removes missing items only in the folders it can enter. A
  folder it cannot enter is left alone entirely, and that is deliberate: an
  unreachable library root is indistinguishable from a detached disk, and
  Jellyfin would rather keep a library than erase one because a NAS was slow to
  mount. The cost is that a root which goes away for good strands everything
  below it. Reproduced against the pinned version and now asserted in CI: move
  a library root aside, scan, restart, scan again, and the rows underneath it
  are still there. Nothing will ever walk that path again.

  Restoring a config archive over a library that has moved on since produces
  exactly the same state, which is what puts this tool in this repository
  rather than somewhere else.

  It edits the database instead of calling the API on purpose.
  `DELETE /Items/{id}` removes the row *and the file*. For an orphan there is
  nothing to delete, right up until one row's path exists in a different
  Unicode normal form and the composed twin on disk belongs to a different,
  healthy row. The path comparison is byte for byte for the same reason: the
  tolerant check that clears false alarms in a disk report is the one that
  declares such a row healthy and leaves it.

  Above fifty missing files it prints the list and refuses, because fifty
  missing files is what a detached array looks like. `JELLYFIN_ORPHAN_LIMIT`
  raises the ceiling once a person has read the list. An empty media mount is
  refused outright rather than read as a deleted library.

  The work runs in a new `orphans` service in the `tools` profile, so `up`
  never starts it and `pull` never fetches it. It has the library database, the
  same read-only media mount Jellyfin has (from one YAML anchor, so the two
  cannot drift), and no Docker socket. Stopping the server stays on the host
  with the script, which confirms the container is down by reading its state
  rather than trusting the exit status of `docker stop`. SQLite will let a
  second process write a database Jellyfin has open and report nothing at all.

  Deletion turns on `PRAGMA foreign_keys`, so the twelve tables the schema
  cascades are cleared by the schema itself, including an item's children
  through `BaseItems.ParentId`. Four tables carry an `ItemId` with no foreign
  key and are deleted by name. Two more carry a column called `ItemId` that is
  not an item reference at all: `ActivityLogs`, which should keep saying what
  happened, and `DisplayPreferences`, whose `ItemId` is a per-user view setting
  defaulting to the all-zero GUID. Both are named in the source rather than
  left looking like an oversight. Any other table carrying an `ItemId` is
  reported as schema drift instead of being deleted from or quietly ignored.

  A copy of the database goes to the backups volume first, written with
  SQLite's own backup rather than `cp`: a live database has a write-ahead log
  beside it. The name does not match the retention loop's prune pattern.

- `tests/e2e-orphan-cleanup.sh`, eight scenarios against the live stack, run by
  CI. Fixture video comes from the ffmpeg inside the Jellyfin image under test,
  because the scanner skips a file that is not really video and CI should not
  need to supply a codec to test a database tool.

- `JELLYFIN_ORPHAN_LIMIT` in `.env.example`, and the new `python` pin in the
  Trivy matrix and the daily freshness check.

## [1.0.1] - 2026-09-10

### Fixed

- **The proxy was buffering every stream instead of passing it through.** The
  compose file attached a Traefik `buffering` middleware with all four limits
  set to `0`, in the belief that Traefik buffers by default and that zero
  turned it off. Both halves of that were wrong. Traefik streams bodies unless
  a Buffering middleware is attached; attaching one is what turns buffering on,
  and `0` on its limits means *no size ceiling*, not *disabled*.

  Measured against a response that takes four seconds to produce: without the
  middleware the first byte reaches the client in 0.03s, with it at 4.15s. For
  video that is the whole film assembled in the proxy before playback can
  start, memory in Traefik proportional to what is being watched, and every
  seek paying it again.

  The middleware is gone. What actually limits a long request is the entry
  point's `readTimeout`, 60 seconds by default, which this template already
  sets to zero; `idleTimeout` is raised from the 180-second default to ten
  minutes. Those were correct and are unchanged.

  Found by reading Traefik's own API back and seeing the middleware Traefik had
  built from the labels, then measuring it rather than trusting the label.

## [1.0.0] - 2026-09-10

First release. A production deployment of Jellyfin behind Traefik, built to the
fleet standard established in
[keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose).

### Added

- **Jellyfin 12.0 behind Traefik with Let's Encrypt TLS.** Three images pinned
  by `tag@sha256:<digest>` in the compose `x-images` block: the server,
  Traefik, and a plain alpine for the backups sidecar.
- **Streaming that is not cut off by the proxy.** Traefik gives an entry point
  60 seconds to read an entire request by default and closes an idle connection
  after 180; both are lifted here, the idle timeout to ten minutes.
- **Hardware transcoding as an opt-in override file.** A GPU belongs to the
  host: putting `/dev/dri` in the compose file means the stack refuses to start
  anywhere that device does not exist, including the CI runner that proves this
  template works. `hardware-transcoding.override.yml` carries it, says how to
  read each value off the host rather than guessing, and says that the device
  changes nothing until Jellyfin is told to use it.
- **A read-only media mount.** Jellyfin never needs to write to the library,
  and a media server with write access is one bad plugin away from a long
  restore.
- **A backup loop that reads its own archive back before naming it a backup.**
  Each cycle writes `.partial`, verifies it with `tar -tzf`, and only then
  renames. BusyBox tar returns exit code 1 both for "a file changed while I
  read it" and for "I could not write the output at all", so the exit code
  alone would rename an empty file into place and log it as OK.
- **A restore script that stops the server first**, because the library
  database is SQLite and is written while anything is playing.
- **Deployment Verification workflow.** shellcheck and actionlint, Trivy scans
  of all three images, a daily freshness check, and a deploy job requiring the
  server to report its version through Traefik, an archive to be produced and
  to carry the config directory, seven backup and restore scenarios to pass,
  and the server to come back on the config directory the restore replaced.
- **`update.sh`**, container hardening on every service, resource limits and
  reservations on all three, and a sixty-second `stop_grace_period` on the
  server.

### Notes

- **The media is not in the archive, on purpose.** A library is not something a
  tar inside a Docker volume can hold, and shipping something that looks like a
  backup of it would be worse than saying so. What the archive holds is the
  expensive part: users, the library database with watch state, metadata,
  artwork, plugins and API keys.

[Unreleased]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/releases/tag/v1.1.1
[1.1.0]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/releases/tag/v1.1.0
[1.0.1]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/releases/tag/v1.0.1
[1.0.0]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
