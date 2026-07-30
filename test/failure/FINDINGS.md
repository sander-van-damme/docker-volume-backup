# Failure-injection results

Results of running `test/failure/run-all.sh` (plus the existing
`test/run-test.sh`) against the image built from this repository, on Docker
29.3.1 / compose v5.1.1, with MinIO standing in for S3.

The happy path is solid: `test/run-test.sh` passed end to end, and the
failure suite confirmed the core promises — no downtime when S3 is
unreachable, crash recovery of stopped containers, exact file-level fidelity
through a disaster restore, and correct per-project scoping in a shared
bucket.

What follows is what broke.

| Group | Scenario | Pass | Genuine failures |
|---|---|---|---|
| A | S3 outages | 15/16 | 0 (one harness timing bug, re-verified in F1) |
| B | crashes and restarts | 19/21 | 1 (B1b) |
| C | `depends_on` mistakes | 6/9 | 3 (one issue class) |
| D | misconfiguration | 12/16 | 3 (D5, D6, D8) |
| E | fidelity and scoping | 13/14 | 0 (postgres check was a timing artifact, re-verified in H2) |
| F | concurrency and scheduling | 7/9 | 1 (F4) |
| G | deeper edge cases | 8/10 | 2 (G1, G2) |

---

## High

### 1. The init marker can permanently break a service that has not started yet (G2)

`cmd_backup` writes `.docker-volume-backup.init` into every volume that is
empty at backup time. The README says this "never interferes with
applications (like PostgreSQL) that require an empty directory to
initialize" — but that only holds while every such service is already
running. A volume whose service has not been deployed yet, is scaled to 0,
is crash-looping, or was skipped by a partial `docker compose up <service>`
is also empty, so it gets a marker too:

```
[dvb] volume 'newdb-data' is empty; writing init marker
...
initdb: error: directory "/var/lib/postgresql/data" exists but is not empty
initdb: detail: It contains a dot-prefixed/invisible file
```

The database then never starts, and the marker is now in the backups as
well. Adding a database service to an existing stack and letting one
scheduled backup run before its first start is enough to trigger this.

Suggested fix: only write the marker for volumes that at least one container
in the project actually mounts (the container list is already computed for
the stop step), or write it only for volumes that were empty on a previous
backup too.

### 2. `external: true` volumes are silently never backed up (G1)

Volume discovery filters on `label=com.docker.compose.project`. A volume
declared `external: true` is not created by compose and carries no compose
labels, so it never appears:

```
volume labels on the external volume: map[]
[dvb] backing up project 'dvblabgx', volumes: own-data
paths actually present in the repository: /staging/own-data
```

Nothing in the log says a volume was skipped — the run just reports the
volumes it did find, and looks entirely successful. External volumes are a
common way to protect data from `compose down -v`, which makes this exactly
the data an operator is least willing to lose.

The README's discovery section cites external volumes (`example-y1fal5`) as
a case the label lookup handles; that is true only when the external volume
happens to have been created by some *other* compose project.

Suggested fix: cross-check the volumes actually mounted by the project's
containers against the label query and warn loudly about any that are
mounted but unlabelled, or resolve external volumes through the service
definitions.

### 3. An unreadable repository is mistaken for a missing one (D6 / H1)

`ensure_repo` cannot distinguish "no repository here" from "cannot open this
repository". It runs `restic init`, gets `config file already exists`, and
the `grep -qi "already\|config file exists"` treats that as success.

Setting `RESTIC_PASSWORD` on an existing unencrypted repository (or changing
it) therefore produces a container that reports **healthy**:

```
[dvb] no repository found at s3:http://minio:9000/dvblab; initializing (attempt 1/5)
[dvb] volume 'db-data' contains data; skipping restore
[dvb] ready; scheduling backups at '0 4 * * *'
backup container health: healthy
```

Dependent services start normally, and only the backup itself fails, with
exit 12 — a log line inside a cron job that nobody is watching. Worse, the
doomed run gets far enough to stop the application containers first, so you
pay the downtime *and* get no backup:

```
[dvb] staging volume 'app-data' ...
[dvb] starting 2 container(s) again
[dvb] uploading snapshot of 'app-data'
Fatal: wrong password or no key found
```

This defeats the purpose of the pre-flight check, which exists precisely so
that an unusable repository never causes downtime.

Wrong *credentials* are handled correctly (F1: `init` fails with an auth
error, so the retry budget is exhausted and the container dies). It is only
the "repo is there but I can't open it" case that slips through.

On a genuinely fresh deploy the wrong password is fatal, as it should be
(`ERROR: cannot list snapshots for volume 'app-data'`, container unhealthy,
stack refuses to start).

Suggested fix: only fall through to `init` when the failure looks like a
missing repository, and treat "config file already exists" after a failed
`cat config` as fatal rather than as success.

### 4. A hung upload silently stops all future backups (F4)

`ensure_repo` bounds its probe with `timeout 30`, but the upload phase
(`restic backup` / `forget --prune`) has no timeout. Against an endpoint that
drops packets rather than refusing them — a hung load balancer, a dropped
route, an overloaded gateway — the run wedges while holding `/tmp/dvb.lock`.

Every subsequent cron backup then does this and exits 0:

```
[dvb] another backup or restore is still in progress; skipping
```

Observed still holding the lock after 120s of blackholed S3, with the
container healthy the whole time. There is no upper bound, no unhealthy
signal, and no non-zero exit anywhere: backups just quietly stop happening
for as long as the network stays broken.

Suggested fix: bound the whole backup run (`timeout` around the restic
calls), and/or make repeated skips visible — e.g. refuse to report healthy
once N consecutive scheduled runs have been skipped or have failed.

---

## Medium

### 5. `depends_on` mistakes fork the data silently (C1, C2)

This is the documented requirement, and the failure mode is exactly as
severe as the README implies — but it is completely silent.

Fresh deploy with backups present in S3:

```
good    (depends_on: service_healthy) -> 'REAL-DATA-good'
nodep   (no depends_on)               -> 'FRESH-INIT'
weakdep (depends_on without condition)-> 'FRESH-INIT'
```

`depends_on: [backup]` without `condition: service_healthy` gives no
protection at all: compose only waits for the container to exist. The
ungated services initialized their own volumes first, and dvb then reported:

```
[dvb] volume 'nodep-data' contains data; skipping restore
[dvb] volume 'weakdep-data' contains data; skipping restore
```

That reads like normal operation. The backups were still intact in the
bucket (1 snapshot each) — the running stack had simply forked away from
them.

C2 makes it worse: with S3 unreachable on a fresh deploy, the gated service
correctly stayed in `created`, but the ungated one started and initialized
its volume anyway — the precise scenario the design exists to prevent.

Suggested fix: this cannot be fully prevented from inside the container, but
it can be made loud. When a volume contains data, has no init marker, and a
snapshot for it exists in the repository, log a `WARNING` rather than an
informational "skipping restore" line.

### 6. An invalid `BACKUP_CRON` leaves a healthy container that never backs up (D8)

`BACKUP_CRON` is written into the crontab unvalidated:

```
[dvb] ready; scheduling backups at 'not a cron' (Europe/Brussels)
state=running health=healthy
```

busybox `crond` ignores the malformed line, the container reports healthy,
dependent services start, and no backup is ever taken. A typo in an
environment variable becomes an open-ended, silent backup outage.

Suggested fix: validate the five fields before writing the crontab and
`die` on a malformed schedule.

### 7. An operator stopping dvb mid-backup takes the whole stack down (B1b)

Crash recovery itself works well (B1, B2, B6 — see below). But it only runs
when the backup container comes back, and docker treats `docker kill`,
`docker stop`, `compose stop backup` and `compose down backup` as *manual*
stops, which suppresses `restart: unless-stopped`:

```
after 25s: backup=exited restartcount=1 apps running=0
```

Because dvb had already stopped the application containers with
`docker stop`, their own restart policies do not apply either. The entire
stack stays down until someone starts the backup container by hand — at
which point recovery works immediately (verified).

Suggested fix: document it, and consider trapping `SIGTERM`/`SIGINT` during
the stop window so a graceful stop restarts the application containers on
the way out.

### 8. The staging-volume guard is unreachable (D5)

`dvb` dies with `no volume is mounted at /staging` if the operator forgets
the staging volume — except that can never happen, because the Dockerfile's
`VOLUME /staging` makes docker create an anonymous volume first:

```
started happily without an operator-provided staging volume
an anonymous volume was used instead: f1fa4d872807b7d8fda6...
```

So the check is dead code, and a stack missing its staging volume runs
"fine" while the staging cache and the `.dvb-stopped` crash-recovery marker
live in an untracked anonymous volume that grows without bound and is not
removed by `compose down -v`.

Suggested fix: drop `VOLUME /staging` from the Dockerfile so the existing
guard can fire, or check that the mount is a named volume.

---

## Low / documentation

- **Containers that ignore `SIGTERM` are SIGKILLed and nothing says so (G4).**
  A container trapping `SIGTERM` was killed after `BACKUP_STOP_TIMEOUT` and
  the backup completed (exit 0) with no mention that the volume was captured
  mid-write. Those backups are crash-consistent only. The 30s default may be
  short for a PostgreSQL smart shutdown under load. Worth logging when a
  container had to be killed rather than stopped.

- **dvb reaches outside its own compose project (C3).** Volume users are
  found with `docker ps --filter volume=`, which is not project-scoped. A
  standalone container mounting one of the project's volumes was stopped
  along with the project's own three services and started again afterwards.
  That is right for consistency, but it means the backup container stops and
  starts containers it does not own — including ones that were deliberately
  left stopped. Worth a line in the README.

- **Giving up on an unreachable S3 takes ~3 minutes (A1).** Five `timeout 30`
  probes plus backoff. Bounded and safe (no containers are stopped), but a
  cron backup takes three minutes to fail, and the fresh-deploy restore path
  inherits the same delay before the container restarts.

- **Renaming the project hides existing backups (E6).** Documented in the
  README, and confirmed: scoping is by the compose project name used as the
  restic `--host`. Nothing warns at runtime — a fresh deploy after a rename
  simply starts empty. A warning when the repository contains snapshots for
  other hosts but none for this one would catch it.

---

## What held up well

- **No downtime when S3 is down (A1).** The pre-flight check fired before
  anything was stopped; `StartedAt` on both application containers was
  byte-identical before and after a failed backup.

- **Containers are restarted before the upload (A5).** S3 blackholed
  mid-upload: the upload hung, but the stack was already running again and
  the database was unaffected.

- **Crash recovery (B1, B2, B6).** SIGKILLing the container's init while the
  application containers were stopped left a valid `.dvb-stopped` list on the
  staging volume; the restarted container recovered the stack in ~2s. A
  brand-new container created by `compose up --force-recreate` recovered it
  too. A full docker daemon restart mid-backup also recovered by itself:
  `found containers left stopped by an interrupted backup; starting them`.

- **Health gating (B3, B4).** A restart clears the ready file, so the
  container never reports healthy on a stale marker, and the restore pass
  correctly logs `contains data; skipping restore`.

- **File-level fidelity (E2).** A fixture of 15 entries — nested and
  space-containing directories, a symlink, a hardlink pair, mode 755/600
  files, a file owned by uid 4242, a unicode filename, a 64MB sparse file, an
  empty directory and a FIFO — came back byte-identical after
  `compose down -v` and a redeploy, including inode sharing for the hardlink.
  PostgreSQL restored into a working database that accepted connections in
  ~1s (H2).

- **Multi-project scoping (E1).** Two projects sharing one bucket *and*
  prefix with identically named volumes: neither restored the other's data,
  and project one's `forget --prune` left project two's snapshots untouched.

- **Retention (E1c).** Five extra backups against `BACKUP_RETENTION=3` left
  exactly 3 snapshots.

- **Deletions propagate (E3)**, and **volumes with data are never
  overwritten** (E4), including local changes not present in any backup.

- **Locking (F2, F3).** A concurrent backup was refused and exited 0 so cron
  does not treat it as an error; a `restore` correctly waited for the running
  backup instead of racing it.

- **Staging out of space (D9).** With a 32MB staging volume and 120MB of
  data, rsync failed with code 11 and the `EXIT` trap still restarted every
  application container.

- **Configuration errors are clear and actionable (D1–D4).** Missing bucket,
  missing docker socket, running outside compose, and a custom `hostname:`
  each produced a specific message naming the fix, and exited non-zero.

- **Miscellaneous.** `restic check` passed after the whole crash series;
  `/run/dvb.env` is mode 600; the timezone reaches both the container and the
  cron environment; stale staging directories of excluded volumes are cleaned
  up; `dvb restic`, `dvb restore` and command passthrough all work.
