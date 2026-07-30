# docker-volume-backup

[![Build and publish image](https://github.com/sander-van-damme/docker-volume-backup/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/sander-van-damme/docker-volume-backup/actions/workflows/docker-publish.yml)

A single backup container for docker compose stacks. It backs up **all named
volumes of its own compose project** to **any S3-compatible storage** using
[restic](https://restic.net/) (incremental, deduplicated, optionally
encrypted), and automatically **restores the latest backup on a fresh
deploy** — a simple form of disaster recovery.

## How it works

- **Discovery through the Docker API.** The container inspects itself through
  the docker socket, reads its `com.docker.compose.project` label and lists
  all volumes carrying that project label. No custom labels or configuration
  needed, and no guessing of host volume names (a compose volume `example`
  may be called `example-y1fal5` or `myproject_example` on the host — the
  labels are authoritative, the name never matters). Bind mounts and
  anonymous volumes are not backed up. Volumes mounted into the backup
  container itself (the staging volume) are excluded automatically.

- **Minimal downtime.** At each scheduled backup, every running container
  that uses one of the volumes is stopped, the volume contents are copied to
  a local staging volume (fast), and the containers are started again.
  Only then is the data uploaded to S3, in the background, while your stack
  is already running again.

- **Incremental + encrypted.** Uploads go through restic: only changed data
  is uploaded and stored (deduplicated chunks), old snapshots are pruned per
  the retention setting, and setting a password enables encryption.

- **Automatic disaster recovery.** Start the backup service before everything
  else via `depends_on: condition: service_healthy`. On start it checks every
  named volume of the project:
  - volume has data → left alone;
  - volume is empty and a backup exists in S3 → the latest snapshot is
    restored into it before dependent services start;
  - volume is empty and there is no backup → left for the application to
    initialize.

  Volumes that are *intentionally* empty (e.g. a media volume that never got
  content) get a `.docker-volume-backup.init` marker file at backup time, so
  a fresh deploy remembers they are supposed to be empty and doesn't keep
  looking for data to restore. The marker is only ever written to volumes
  that are already empty while their containers run, so it never interferes
  with applications (like PostgreSQL) that require an empty directory to
  initialize. Once real data appears in the volume, the next backup removes
  the marker again.

## Usage

See [docker-compose.yml](docker-compose.yml) for a complete example. The
essential parts:

```yaml
services:
  backup:
    image: ghcr.io/sander-van-damme/docker-volume-backup:latest
    pull_policy: always
    restart: unless-stopped
    environment:
      S3_BUCKET: my-backup-bucket
      AWS_ACCESS_KEY_ID: ...
      AWS_SECRET_ACCESS_KEY: ...
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - backup-staging:/staging

  your-app:
    # ...
    depends_on:
      backup:
        condition: service_healthy

volumes:
  backup-staging:
```

Notes:

- The docker socket mount is required (volume discovery, stopping/starting
  containers, helper containers for copying volume data). Be aware of what
  that means: access to the docker socket is equivalent to root on the host,
  so only run this container (like anything else with the socket mounted) if
  you trust the image and the machine is yours to administer.
- Backups and restores are scoped to the compose project name (the restic
  `host`). Two projects can safely share one bucket/prefix — one project will
  never restore or prune another's snapshots. The flip side: renaming a
  project (or its directory) makes existing backups invisible to the
  automatic restore and to retention. After a rename, prune the old
  snapshots manually (`dvb restic forget --host <old-name> ...`) or copy
  them over.
- The staging volume (`/staging`) must be large enough to hold an
  uncompressed copy of all backed-up volumes.
- Don't set a custom `hostname:` on the backup service — it identifies its
  own container by hostname.
- If the backup container fails to start (e.g. S3 unreachable on a fresh
  deploy), dependent services intentionally stay down: starting an empty
  stack when backups might exist could fork your data.

## Configuration

Everything is configured through environment variables:

| Variable | Default | Description |
|---|---|---|
| `S3_BUCKET` | — (required) | Bucket to store backups in |
| `AWS_ACCESS_KEY_ID` | — (required) | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | — (required) | S3 secret key |
| `S3_ENDPOINT` | `https://s3.eu-central-003.backblazeb2.com` | Any S3-compatible endpoint (Backblaze B2 by default — pick your bucket's region endpoint) |
| `S3_PREFIX` | *(empty — bucket root)* | Path prefix inside the bucket |
| `BACKUP_CRON` | `0 4 * * *` | Backup schedule (standard 5-field cron) |
| `TZ` | `Europe/Brussels` | Timezone the schedule is evaluated in |
| `BACKUP_RETENTION` | `31` | Snapshots kept per volume (with the default daily schedule: 31 days) |
| `RESTIC_PASSWORD` | *(empty — encryption off)* | Set to enable encryption. **Losing it means losing the backups.** Changing it later requires a new repository (new bucket/prefix). |
| `BACKUP_STOP_TIMEOUT` | `30` | Seconds to wait for containers to stop gracefully |
| `BACKUP_EXCLUDE_VOLUMES` | *(empty)* | Comma-separated compose volume names to skip |
| `RESTIC_REPOSITORY` | *(derived from the S3 settings)* | Full restic repository override, for non-S3 backends |

## Manual operations

```sh
# trigger a backup right now
docker compose exec backup dvb backup

# inspect snapshots (any restic command works through the dvb wrapper,
# which fills in the repository and encryption settings)
docker compose exec backup dvb restic snapshots

# re-run the restore pass
docker compose exec backup dvb restore
```

Since the repository is plain restic, you can also browse, mount or restore
backups from any machine with restic installed.

## Published image

The image is built and pushed to the GitHub container registry by
[.github/workflows/docker-publish.yml](.github/workflows/docker-publish.yml),
for `linux/amd64` and `linux/arm64`. Publishing is gated on the end-to-end
test (see below) passing in CI:

| Trigger | Tags published |
|---|---|
| push to `main` | `latest`, `sha-<commit>` |
| push of a `v*` tag (e.g. `v1.2.3`) | `1.2.3`, `1.2`, `1`, `sha-<commit>` |
| pull request | *none* — the image is built as a check only |

Nothing needs to be configured: the workflow authenticates to `ghcr.io` with
the automatic `GITHUB_TOKEN`. The package itself starts out private, so make
it public once under *Packages → docker-volume-backup → Package settings →
Change visibility* if you want to pull it without logging in.

## Testing locally

`./test/run-test.sh` runs a full end-to-end test against a local MinIO
container: initial deploy, backup, retention, destroying all volumes, and
verifying the automatic restore on redeploy (including the
intentionally-empty-volume marker and the cron schedule).

`./test/failure/run-all.sh` is the counterpart that breaks things on
purpose — S3 outages and blackholes, crashes mid-backup, misconfiguration,
`depends_on` mistakes, a full staging volume, and multi-project scoping. It
takes considerably longer (several scenarios wait out multi-minute retry
budgets) and is not part of CI. See
[test/failure/FINDINGS.md](test/failure/FINDINGS.md) for what it turned up.
