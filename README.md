# Jellyfin + Traefik + Let's Encrypt on Docker Compose

[![Deployment Verification](https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml/badge.svg?branch=main)](https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

This repository deploys Jellyfin (a self-hosted media server for film, television and music, with clients on every platform and no subscription attached) behind Traefik with automatic Let's Encrypt TLS, with scheduled backups of everything the server knows and a companion restore script.

## Getting started

```bash
# 1. Clone
git clone https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose
cd jellyfin-traefik-letsencrypt-docker-compose

# 2. Create the two Docker networks the stack expects
docker network create traefik-network
docker network create jellyfin-network

# 3. Copy the environment template and fill in required values
cp .env.example .env
$EDITOR .env
# ^ Required: JELLYFIN_HOSTNAME, TRAEFIK_HOSTNAME,
#   TRAEFIK_ACME_EMAIL, TRAEFIK_BASIC_AUTH.
#   Point JELLYFIN_MEDIA_PATH at your library, or leave it and use ./media.

# 4. Deploy
docker compose -f jellyfin-traefik-letsencrypt-docker-compose.yml -p jellyfin up -d
```

**Open the site and finish the setup wizard immediately.** Jellyfin has no accounts until the wizard runs, and the wizard is open to whoever reaches it first.

### What success looks like

```bash
docker compose -f jellyfin-traefik-letsencrypt-docker-compose.yml -p jellyfin ps
curl -sk "https://${JELLYFIN_HOSTNAME}/System/Info/Public"
# Expected: {"LocalAddress":"https://…","ServerName":"…","Version":"12.0.0",…}
```

`ps` shows `jellyfin` and `traefik` healthy, and `backups` running with no health check of its own.

### Common first-deploy issues

- **The library is empty after a scan.** The media mount is read-only and points where `JELLYFIN_MEDIA_PATH` says. Check it resolves to the directory you meant: `docker compose -p jellyfin exec jellyfin ls /media`.
- **Playback stops after a minute or two.** Something between the client and Traefik is enforcing a response timeout. This template sets Traefik's to zero, because a film is one response that lasts as long as the film; a proxy or tunnel in front of it may have its own.
- **Everything transcodes on the CPU and the box melts.** That is the default. See the section below — the device alone is not enough, Jellyfin has to be told to use it.
- **Cert issuance fails.** DNS has not propagated, or port 80 is not reachable from the internet.
- **Networks not found.** Step 2 was skipped.

## Hardware transcoding is a separate file, deliberately

A GPU belongs to the host, not to this template. Putting `/dev/dri` in the compose file would mean the stack refuses to start on any machine without that exact device node — including the CI runner that proves this template works, and including anybody deploying it on a VPS.

So it lives in `hardware-transcoding.override.yml`, and you name both files:

```bash
docker compose \
  -f jellyfin-traefik-letsencrypt-docker-compose.yml \
  -f hardware-transcoding.override.yml \
  -p jellyfin up -d
```

Three values come from the host and must not be guessed — the file says how to read each one, and a wrong render group id is the usual reason acceleration silently falls back to the CPU. Then turn it on in Jellyfin: **Dashboard → Playback → Transcoding → Hardware acceleration**. The device being present changes nothing until the server is told to use it.

NVIDIA needs the Container Toolkit and a reservation rather than a device node; that file deliberately does not guess at it.

## The media mount is read-only

Jellyfin never needs to write to your library, and a media server with write access to it is one bad plugin away from a very long restore. It is mounted `:ro` here and the archive does not include it: a media library is not something a tar in a Docker volume can hold, and pretending otherwise is worse than saying so. Back it up wherever the disk it lives on is backed up.

What the archive does hold is the part that is expensive to lose: users and their passwords, the library database with watch state and resume positions, downloaded metadata and artwork, plugins and their settings, and the API keys any client was given. Rebuilding that by hand is the bad Saturday.

## Updating

`./update.sh` moves this checkout to the latest release tag — a combination this repository's CI has booted, upgraded from the previous release on the same volumes, and smoke-tested — and then runs `docker compose up -d`. It refuses to cross a major version unattended, refuses to run over local changes, and names any variable that became required since your version before anything has moved. `./update.sh --dry-run` says what would happen. Every release cut by fleet triage also carries what upstream changed, read from its release notes against this compose file.

If you run with the hardware-transcoding override, add it to your own `up` command after the update: `update.sh` starts the base file only.

## Supply chain trust

Three images pinned to `tag@sha256:<digest>` as interpolation defaults in the compose `x-images` block:

- [`jellyfin/jellyfin`](https://hub.docker.com/r/jellyfin/jellyfin): the server, latest stable (12.0)
- [`traefik`](https://hub.docker.com/_/traefik): reverse proxy
- [`alpine`](https://hub.docker.com/_/alpine): the backups sidecar, which needs tar and nothing else

`git pull` alone delivers the tested combination; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

Two override levels exist per image. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of that image (Compose then pulls the tag, without a digest) and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. Nested defaults need Docker Compose v2.5 or newer (2022).

The daily `check-pin-freshness` CI job re-resolves each pin against its registry and compares the pinned Jellyfin and Traefik versions against the latest upstream releases. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

## Production checklist

- [ ] **Finish the setup wizard immediately after deploy.**
- [ ] **Point `JELLYFIN_MEDIA_PATH` at the real library** and confirm it is mounted read-only.
- [ ] **Regenerate the Traefik dashboard hash.** The one in `.env.example` is a placeholder.
- [ ] **Host-mount the backup volume.** By default the archives land in a named volume: if the host dies, they die with it.
- [ ] **Back up the media separately.** It is not in these archives and cannot sensibly be.
- [ ] **Decide about hardware transcoding** before you invite anyone. Software transcoding one 4K stream will use every core you gave the container.
- [ ] **Check what your provider says about streaming video** through whatever fronts this. Some tunnels and CDNs forbid it in their free terms, and the penalty is usually account-wide rather than per-service.

## Backups and restore

The `backups` container archives `/config` on a loop — a 30-minute warm-up, a 24-hour interval, 7-day retention, all overridable in `.env`.

Each archive is written to a `.partial` name, **read back with `tar -tzf`**, and only then renamed. The read-back is not decoration: BusyBox tar, which is what an alpine image ships, returns exit code 1 both for "a file changed while I was reading it" and for "I could not write the output at all". Trusting the exit code alone renames an empty file into place and calls it a backup. This loop refuses to.

Restore with the interactive script:

```bash
chmod +x ./*.sh
./jellyfin-restore-config.sh
```

It stops the server first: the library database is SQLite and is written while anything is playing. Artwork and chapter images regenerate on demand afterwards, so a full library rescan is not needed.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults: the same values CI boots the stack under. The defaults assume software transcoding, which is what makes them matter — with hardware acceleration on, most of that allowance sits idle. Override any of them in `.env` and the override survives every `git pull`. If a service is OOM-killed, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`. The reverse proxy and the backups sidecar run with `cap_drop: [ALL]` and add back only what they need. The server keeps the default capability set on purpose: upstream images assume it, and a wrong guess there is a boot loop in production rather than a hardening win. The hardware-transcoding override is the one place that widens this, by adding a group and two device nodes — which is why it is opt-in and why the file explains what each value is.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck and actionlint, Trivy scans of all three pinned images, the daily freshness check, and a deploy job that boots the stack with ephemeral credentials and then requires the server to report its version through Traefik, an archive to be produced and to carry the config directory, the seven backup and restore scenarios to pass, and Jellyfin to come back up on the config directory the restore test replaced underneath it.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the smoke test. Two scenarios carry the weight. The restore roundtrip writes a file, waits for the archive that contains it, deletes it, restores, and asserts it came back. The failure test blocks the destination the loop is about to write to and asserts the loop says FAILED and leaves nothing behind that is named like a backup and does not open.

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

Run it on a staging copy, not on production: it stops the server and empties the config directory.

## Security notes

- Credentials are read from `.env` at deploy time; `.env` is gitignored and compose fails fast on missing required variables.
- The media library is mounted read-only.
- Jellyfin has no accounts before the setup wizard runs, and no gate in front of it.

---

## About the maintainer

<div align="center">

**Maintained by [Vladimir Mikhalev](https://github.com/heyvaldemar)** · Docker Captain · IBM Champion · AWS Community Builder

[YouTube](https://www.youtube.com/channel/UCf85kQ0u1sYTTTyKVpxrlyQ?sub_confirmation=1) · [Blog](https://heyvaldemar.com) · [LinkedIn](https://www.linkedin.com/in/heyvaldemar/)

</div>
