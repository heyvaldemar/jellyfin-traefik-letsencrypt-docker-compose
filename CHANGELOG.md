# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_(no unreleased changes yet)_

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

[Unreleased]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/releases/tag/v1.0.1
[1.0.0]: https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/releases/tag/v1.0.0
