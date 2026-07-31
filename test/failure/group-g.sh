#!/usr/bin/env bash
# Group G — deeper failure modes found by reading the script
source "$(dirname "$0")/lib.sh"
COMPOSE_FILE=$LAB/stack.yml
PROJ=dvblabg

cleanup() {
  nuke $PROJ "$LAB/stack.yml"; nuke dvblabgx "$LAB/external.yml"
  docker rm -f dvbg-pg dvbg-stubborn >/dev/null 2>&1 || true
  docker volume rm -f dvblab-important >/dev/null 2>&1 || true
  minio_rm; docker network rm $NET >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
minio_up || exit 1

# ---------------------------------------------------------------------------
step "G1 — 'external: true' volumes are out of scope (documented behaviour)"
docker volume create dvblab-important >/dev/null
COMPOSE_FILE=$LAB/external.yml; PROJ=dvblabgx
dc up -d --wait --wait-timeout 150 >/dev/null 2>&1
docker exec $PROJ-app-1 sh -c 'echo IRREPLACEABLE > /ext/payload; echo ORDINARY > /own/payload'
out=$(dc exec -T backup dvb backup 2>&1)
info "$(grep 'volumes:' <<<"$out")"
info "volume labels on the external volume: $(docker volume inspect dvblab-important -f '{{.Labels}}')"
if grep -q "important" <<<"$out"; then
  bad "the external volume was backed up; the documented contract is that it is skipped"
else
  ok "the external volume is skipped, as documented"
  note "G1: an unlabelled external volume is skipped silently — the log lists the volumes that were found, never the ones that were not. Coverage is worth checking against that log line after any change to a stack's volumes"
fi
snaps=$(dc exec -T backup dvb restic snapshots --json 2>/dev/null | jq -r '[.[].paths[]]|unique|join(" ")')
info "paths actually present in the repository: $snaps"

step "G1b — the documented opt-in: labelling an external volume brings it in"
nuke dvblabgx "$LAB/external.yml"; docker volume rm -f dvblab-important >/dev/null 2>&1
docker volume create \
  --label com.docker.compose.project=dvblabgx \
  --label com.docker.compose.volume=important dvblab-important >/dev/null
dc up -d --wait --wait-timeout 150 >/dev/null 2>&1
docker exec $PROJ-app-1 sh -c 'echo IRREPLACEABLE > /ext/payload'
out=$(dc exec -T backup dvb backup 2>&1)
info "$(grep 'volumes:' <<<"$out")"
grep -q "important" <<<"$out" \
  && ok "a labelled external volume is discovered and backed up" \
  || bad "labelling the external volume did not bring it into the backup"
nuke dvblabgx "$LAB/external.yml"; docker volume rm -f dvblab-important >/dev/null 2>&1

# ---------------------------------------------------------------------------
COMPOSE_FILE=$LAB/stack.yml; PROJ=dvblabg
step "G2 — init marker written into the empty volume of a service that has not started yet"
dc up -d --wait --wait-timeout 150 >/dev/null 2>&1
info "adding a volume for a database service that is declared but not deployed yet"
docker volume create -d local \
  --label com.docker.compose.project=$PROJ \
  --label com.docker.compose.volume=newdb-data ${PROJ}_newdb-data >/dev/null
out=$(dc exec -T backup dvb backup 2>&1)
grep "newdb-data" <<<"$out" | sed 's/^/       /'
marker=$(docker run --rm -v ${PROJ}_newdb-data:/v alpine:3.22 sh -c 'ls -A /v | tr "\n" " "')
info "contents of the not-yet-used volume after the backup: '$marker'"
info "now deploying the database onto that volume"
docker rm -f dvbg-pg >/dev/null 2>&1
docker run -d --name dvbg-pg -e POSTGRES_PASSWORD=example \
  -v ${PROJ}_newdb-data:/var/lib/postgresql/data postgres:17-alpine >/dev/null
for i in $(seq 1 30); do
  [ "$(state_of dvbg-pg)" != running ] && break
  docker exec dvbg-pg pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
st=$(state_of dvbg-pg)
info "postgres state: $st"
docker logs dvbg-pg 2>&1 | grep -i "not empty\|error\|initdb" | head -3 | sed 's/^/       /'
if [ "$st" = running ] && docker exec dvbg-pg pg_isready -U postgres >/dev/null 2>&1; then
  ok "the database still initialized fine despite the marker file"
else
  bad "the database could not initialize: the backup container had planted a marker file in its empty data directory"
  note "G2: the init marker is written to any volume that is empty at backup time, including volumes whose service has not been deployed yet (declared-but-not-started, scaled to 0, crash-looping, or a partial 'compose up <service>'). PostgreSQL's initdb refuses a non-empty data directory, so the very first backup after adding a database service can prevent that service from ever starting. The README states the marker 'never interferes with applications that require an empty directory to initialize', which holds only while every such service is already running"
fi
docker rm -f dvbg-pg >/dev/null 2>&1
docker volume rm -f ${PROJ}_newdb-data >/dev/null 2>&1

# ---------------------------------------------------------------------------
step "G3 — stale restic lock after a crash during the upload phase"
docker exec $PROJ-app-1 sh -c 'dd if=/dev/urandom of=/data/big.bin bs=1M count=500 2>/dev/null'
dc exec -T backup dvb backup >/dev/null 2>&1
docker exec $PROJ-app-1 sh -c 'dd if=/dev/urandom of=/data/big2.bin bs=1M count=500 2>/dev/null'
docker exec -d $PROJ-backup-1 dvb backup
info "waiting for the upload phase to start, then killing dvb"
for i in $(seq 1 300); do
  docker logs $PROJ-backup-1 2>&1 | tail -5 | grep -q "uploading snapshot" && break
  docker exec $PROJ-backup-1 sh -c 'ls /staging' >/dev/null 2>&1
  sleep 0.5
done
pid=$(docker exec $PROJ-backup-1 sh -c "pgrep -f 'restic.*backup' | head -1")
info "restic upload pid inside the container: ${pid:-none}"
docker exec $PROJ-backup-1 sh -c "kill -9 $pid" 2>/dev/null
sleep 2
locks=$(docker exec $PROJ-backup-1 dvb restic list locks 2>/dev/null | wc -l | tr -d ' ')
info "restic locks left in the repository: $locks"
for i in $(seq 1 60); do docker exec $PROJ-backup-1 sh -c 'flock -n 9 9>/tmp/dvb.lock' 2>/dev/null && break; sleep 2; done
out=$(docker exec $PROJ-backup-1 dvb backup 2>&1); rc=$?
info "next backup exit=$rc"
tail -4 <<<"$out" | sed 's/^/       /'
if [ $rc -eq 0 ]; then
  ok "the next backup ran cleanly despite the interrupted upload"
else
  bad "the next backup failed after an interrupted upload"
  grep -qi "locked" <<<"$out" && note "G3: an interrupted upload leaves a restic lock in the repository. The next run uploads fine but 'forget --prune' needs an exclusive lock and fails, so the whole backup exits non-zero until the stale lock ages out (restic ignores locks older than 30 minutes). Retention silently stops being applied in the meantime"
fi
docker exec $PROJ-app-1 sh -c 'rm -f /data/big.bin /data/big2.bin'

# ---------------------------------------------------------------------------
step "G4 — a container that ignores SIGTERM (BACKUP_STOP_TIMEOUT)"
docker rm -f dvbg-stubborn >/dev/null 2>&1
docker volume create -d local --label com.docker.compose.project=$PROJ \
  --label com.docker.compose.volume=stubborn-data ${PROJ}_stubborn-data >/dev/null
docker run -d --name dvbg-stubborn -v ${PROJ}_stubborn-data:/data alpine:3.22 \
  sh -c 'trap "" TERM; while true; do date >> /data/writes.log; sleep 0.2; done' >/dev/null
sleep 2
t0=$SECONDS
out=$(STOP_TIMEOUT=5 docker exec $PROJ-backup-1 dvb backup 2>&1); rc=$?
el=$((SECONDS-t0))
info "backup exit=$rc, took ${el}s (BACKUP_STOP_TIMEOUT default is 10 in this stack)"
check "the SIGTERM-ignoring container was started again" "running" "$(state_of dvbg-stubborn)"
[ $rc -eq 0 ] && ok "the backup completed despite having to SIGKILL a container" || bad "backup failed: $(tail -1 <<<"$out")"
note "G4: containers that do not exit on SIGTERM within BACKUP_STOP_TIMEOUT are SIGKILLed by 'docker stop'. The volume is then captured mid-write, so the backup is only crash-consistent. For PostgreSQL the default 30s may be too short for a smart shutdown under load, and nothing in the log flags that a container had to be killed rather than stopped"
docker rm -f dvbg-stubborn >/dev/null 2>&1
docker volume rm -f ${PROJ}_stubborn-data >/dev/null 2>&1

# ---------------------------------------------------------------------------
step "G6 — upgrade path: a volume left holding an old .docker-volume-backup.init marker"
docker volume create -d local --label com.docker.compose.project=$PROJ \
  --label com.docker.compose.volume=legacy-data ${PROJ}_legacy-data >/dev/null
docker run --rm -v ${PROJ}_legacy-data:/v alpine:3.22 touch /v/.docker-volume-backup.init
out=$(docker exec $PROJ-backup-1 dvb backup 2>&1)
grep -q "legacy-data" <<<"$out" && ok "the legacy volume is picked up for backup" \
                                || bad "legacy volume not discovered"
staged=$(docker exec $PROJ-backup-1 sh -c 'ls -A /staging/legacy-data | wc -l' | tr -d ' ')
check "the old marker is not carried into new backups" "0" "$staged"
out=$(docker exec $PROJ-backup-1 dvb restore 2>&1)
grep "legacy-data" <<<"$out" | sed 's/^/       /'
grep -q "volume 'legacy-data' contains data" <<<"$out" \
  && bad "a marker-only volume is still mistaken for a volume holding real data" \
  || ok "a marker-only volume is treated as empty, not as data"
docker volume rm -f ${PROJ}_legacy-data >/dev/null 2>&1

step "G5 — 'dvb restic' escape hatch and the docs' manual-operations commands"
for c in "snapshots" "stats" "check"; do
  docker exec $PROJ-backup-1 dvb restic $c >/dev/null 2>&1 \
    && ok "dvb restic $c works" || bad "dvb restic $c failed"
done
docker exec $PROJ-backup-1 dvb restore >/dev/null 2>&1 \
  && ok "dvb restore (manual re-run) works" || bad "dvb restore failed"
docker exec $PROJ-backup-1 sh -c 'echo passthrough-ok' 2>/dev/null | grep -q passthrough-ok \
  && ok "arbitrary command passthrough works" || bad "passthrough broken"

summary "GROUP G (deeper failure modes)"
