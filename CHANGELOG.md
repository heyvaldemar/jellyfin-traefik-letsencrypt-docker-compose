# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

## [1.0.0] - 2026-09-10

First release. A production deployment of Jellyfin behind Traefik, built to the
fleet standard established in
[keycloak-traefik-letsencrypt-docker-compose](https://github.com/heyvaldemar/keycloak-traefik-letsencrypt-docker-compose).

### Added

- **Jellyfin 12.0 behind Traefik with Let's Encrypt TLS.** Three images pinned
  by `tag@sha256:<digest>` in the compose `x-images` block: the server,
  Traefik, and a plain alpine for the backups sidecar.
- **Streaming that is not cut off by the proxy.** Traefik buffers requests and
  responses by default, which for video means holding a file in memory before a
  byte reaches the player, and its response timeout ends a film part way. Both
  are turned off for this router, which is what makes seeking responsive.
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

[Unreleased]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
