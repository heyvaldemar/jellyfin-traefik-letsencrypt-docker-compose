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
- **Playback stops after a minute or two, or the first byte takes forever.** Something between the client and Traefik is holding or timing the response. Traefik's own limits are lifted here — and note that it streams by default, so a Buffering middleware added anywhere in the chain is what would make it hold a film before playing it. A proxy or tunnel in front has its own settings.
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

- [`jellyfin/jellyfin`](https://hub.docker.com/r/jellyfin/jellyfin): the server, latest stable (12.1)
- [`traefik`](https://hub.docker.com/_/traefik): reverse proxy
- [`alpine`](https://hub.docker.com/_/alpine): the backups sidecar, which needs tar and nothing else

`git pull` alone delivers the tested combination; an `*_IMAGE_TAG` variable in `.env` overrides deliberately.

Two override levels exist per image. `<PREFIX>_IMAGE_VERSION` in `.env` swaps only the version of that image (Compose then pulls the tag, without a digest) and leaves every other pin as tested; `<PREFIX>_IMAGE_TAG` replaces the whole reference, digest included. Nested defaults need Docker Compose v2.5 or newer (2022).

The daily `check-pin-freshness` CI job re-resolves each pin against its registry and compares the pinned Jellyfin and Traefik versions against the latest upstream releases. GitHub Actions are pinned by commit SHA; Dependabot keeps those fresh.

### Verify what you deploy

Every release from v1.1.8 on carries three files made on GitHub's runner with a short-lived identity and no stored key: `jellyfin-traefik-letsencrypt-docker-compose-<tag>.tar.gz`, a `git archive` of exactly the tree the tag points at; `jellyfin-traefik-letsencrypt-docker-compose-<tag>.tar.gz.sigstore.json`, a keyless [Sigstore](https://www.sigstore.dev/) signature over it; and `jellyfin-traefik-letsencrypt-docker-compose-<tag>.intoto.jsonl`, [SLSA](https://slsa.dev/) build provenance from the SLSA generator. To check them with nothing from this repository trusted:

```bash
cosign verify-blob jellyfin-traefik-letsencrypt-docker-compose-<tag>.tar.gz \
  --bundle jellyfin-traefik-letsencrypt-docker-compose-<tag>.tar.gz.sigstore.json \
  --certificate-identity-regexp '^https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

slsa-verifier verify-artifact jellyfin-traefik-letsencrypt-docker-compose-<tag>.tar.gz \
  --provenance-path jellyfin-traefik-letsencrypt-docker-compose-<tag>.intoto.jsonl \
  --source-uri github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose
```

Add `--source-tag <tag>` for a release published after 24 September 2026, which is signed by the run that published it. The five releases before that date were signed by a run started by hand on `main`, so their provenance names the branch, not the tag; the archive is still the tag's tree, and the signature still belongs to this repository's workflow. The workflow that makes them is [`release-assets.yml`](.github/workflows/release-assets.yml).

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

It lists the backups and asks, or takes a file name as its argument; it reads every path from the running backups container, and CI runs it on every push.

It stops the server first: the library database is SQLite and is written while anything is playing. Artwork and chapter images regenerate on demand afterwards, so a full library rescan is not needed.

## Rows that outlive their files

A library scan removes missing items only in the folders it can enter. Take a library root away and everything under it stays in the database: the scan cannot walk a path that is not there, and Jellyfin will not erase a library because a folder failed to appear. That is the right call. From inside the process, an unreachable root and a disk that did not mount are the same event.

The bill arrives later. Restore a config archive over a library that has moved on since, point `JELLYFIN_MEDIA_PATH` somewhere new, or rename a folder that happens to be a root, and rows for files that no longer exist stay in search, in collections and in recently added. CI reproduces it in four steps: move a root aside, scan, restart, scan again. The rows are still there.

```bash
chmod +x ./*.sh
./jellyfin-drop-orphans.sh          # report only, nothing is stopped
./jellyfin-drop-orphans.sh apply    # stop, remove, start
```

The report groups rows by the folder that went missing instead of listing files, so a mount that did not come up reads as one line rather than forty thousand.

Three decisions make it safe to hand to somebody else. It edits the database rather than calling the API, because `DELETE /Items/{id}` removes the row and the file, and a path recorded in one Unicode normal form can have a composed twin on disk that belongs to a different and perfectly healthy row. It compares paths byte for byte, because the tolerant check that clears false alarms in a disk report is the same check that declares such a row healthy and leaves it in the library. And it refuses above fifty missing files, because fifty missing files is what a detached array looks like, and nothing you can read in the database will tell the two apart. Raise `JELLYFIN_ORPHAN_LIMIT` once you have read the list.

The work happens in the `orphans` container, which holds the library database, the same read-only media mount Jellyfin has, and no Docker socket. Stopping the server stays on the host with the script, which confirms the container is down by reading its state rather than trusting the exit status of `docker stop`. SQLite will let a second process write a database Jellyfin has open, and neither of them will say a word about it.

A copy of the database goes to the backups volume before anything is removed, written with SQLite's own backup rather than `cp`: a live database has a write-ahead log beside it, and a copy of the `.db` alone is a database missing its most recent writes. The retention loop never touches that copy.

## Resource limits

Every service carries memory and CPU limits plus reservations as compose-level defaults: the same values CI boots the stack under. The defaults assume software transcoding, which is what makes them matter — with hardware acceleration on, most of that allowance sits idle. Override any of them in `.env` and the override survives every `git pull`. If a service is OOM-killed, `docker inspect <container> --format '{{.State.OOMKilled}}'` says so.

## Container hardening

Every service runs with `security_opt: no-new-privileges:true`. The reverse proxy and the backups sidecar run with `cap_drop: [ALL]` and add back only what they need. The server keeps the default capability set on purpose: upstream images assume it, and a wrong guess there is a boot loop in production rather than a hardening win. The hardware-transcoding override is the one place that widens this, by adding a group and two device nodes — which is why it is opt-in and why the file explains what each value is.

## Testing

The [Deployment Verification](https://github.com/heyvaldemar/jellyfin-traefik-letsencrypt-docker-compose/actions/workflows/deployment-verification.yml?query=branch%3Amain) workflow runs on every push, pull request, and every day at 06:00 UTC: shellcheck and actionlint, Trivy scans of all four pinned images, the daily freshness check, and a deploy job that boots the stack with ephemeral credentials and then requires the server to report its version through Traefik, an archive to be produced and to carry the config directory, the seven backup and restore scenarios to pass, and Jellyfin to come back up on the config directory the restore test replaced underneath it. The orphan-cleanup suite then builds a library on real video and runs eight more.

### Backup and restore, proven

`tests/e2e-backup-restore.sh` runs against the live stack and is what CI executes after the smoke test. Two scenarios carry the weight. The restore roundtrip writes a file, waits for the archive that contains it, deletes it, restores, and asserts it came back. The failure test blocks the destination the loop is about to write to and asserts the loop says FAILED and leaves nothing behind that is named like a backup and does not open.

```bash
chmod +x tests/e2e-backup-restore.sh
./tests/e2e-backup-restore.sh
```

Run it on a staging copy, not on production: it stops the server and empties the config directory.

### Orphan cleanup, proven

`tests/e2e-orphan-cleanup.sh` builds a two-root library from video generated by the ffmpeg inside the image under test, because a file that is not really video is skipped by the scanner and CI should not have to supply a codec to test a database tool. It then produces an orphan the way a library really produces one, by moving a root away, and proves the rows survive a scan, a restart and another scan before the tool is allowed near them. After that: the report changes nothing, both refusals fire, the removal clears the tables the schema cascades and the four it does not, the healthy library keeps every row, the database copy opens and holds the state from before, and Jellyfin comes back up on the edited database.

```bash
chmod +x tests/e2e-orphan-cleanup.sh
./tests/e2e-orphan-cleanup.sh
```

Same warning: staging, not production. It creates libraries, moves your media directory around and stops the server.

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
