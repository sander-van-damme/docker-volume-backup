#!/usr/bin/env bash
# Group F — concurrency, the scheduler, and the credentials re-test
source "$(dirname "$0")/lib.sh"
COMPOSE_FILE=$LAB/stack.yml
PROJ=dvblabf

cleanup() { nuke $PROJ; minio_rm; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
minio_up || exit 1

step "F0 — stack up"
CRON="* * * * *" dc up -d --wait --wait-timeout 150 >/dev/null 2>&1
sleep 3
dc exec -T db psql -U postgres -c "CREATE TABLE t (msg text); INSERT INTO t VALUES ('f-payload');" >/dev/null 2>&1
docker exec $PROJ-app-1 sh -c 'dd if=/dev/urandom of=/data/big.bin bs=1M count=500 2>/dev/null'
dc exec -T backup dvb backup >/dev/null 2>&1 && ok "baseline backup ok" || bad "baseline failed"

step "F1 — bad S3 credentials, re-tested in isolation"
docker rm -f dvbf-badcreds >/dev/null 2>&1
docker run -d --name dvbf-badcreds -l com.docker.compose.project=$PROJ \
  -e S3_BUCKET=dvblab -e S3_ENDPOINT=http://minio:9000 \
  -e AWS_ACCESS_KEY_ID=totally-wrong -e AWS_SECRET_ACCESS_KEY=also-wrong \
  -e BACKUP_CRON="0 4 * * *" \
  --network $NET -v /var/run/docker.sock:/var/run/docker.sock \
  -v dvbf-badstaging:/staging "$IMAGE" start >/dev/null
t0=$SECONDS
for i in $(seq 1 240); do [ "$(state_of dvbf-badcreds)" != running ] && break; sleep 1; done
info "container state after $((SECONDS-t0))s: $(state_of dvbf-badcreds), exit=$(docker inspect -f '{{.State.ExitCode}}' dvbf-badcreds)"
lg=$(docker logs dvbf-badcreds 2>&1)
tail -3 <<<"$lg" | sed 's/^/       /'
if grep -qi "cannot reach or initialize" <<<"$lg"; then
  ok "wrong credentials are fatal and clearly reported"
else
  bad "wrong credentials did not produce the expected fatal error"
  note "F1: check how bad credentials are surfaced"
fi
docker rm -f dvbf-badcreds >/dev/null 2>&1; docker volume rm -f dvbf-badstaging >/dev/null 2>&1

step "F2 — two backups at once: the second must not run"
docker exec -d $PROJ-backup-1 dvb backup
sleep 2
out=$(docker exec $PROJ-backup-1 dvb backup 2>&1); rc=$?
info "second run: exit=$rc | $(tail -1 <<<"$out")"
grep -q "still in progress; skipping" <<<"$out" \
  && ok "the concurrent run was refused by the lock" || bad "no lock protection between concurrent backups"
check "the skipped run exits 0 (so cron does not treat it as an error)" "0" "$rc"
for i in $(seq 1 180); do docker exec $PROJ-backup-1 sh -c 'flock -n 9 9>/tmp/dvb.lock' 2>/dev/null && break; sleep 1; done
sleep 2

step "F3 — a restore while a backup is running waits instead of racing"
docker exec -d $PROJ-backup-1 dvb backup
sleep 2
t0=$SECONDS
out=$(timeout 300 docker exec $PROJ-backup-1 dvb restore 2>&1); rc=$?
el=$((SECONDS-t0))
info "restore returned exit=$rc after ${el}s"
[ $rc -eq 0 ] && [ $el -ge 3 ] \
  && ok "restore waited for the running backup to finish (${el}s) instead of racing it" \
  || info "restore exit=$rc elapsed=${el}s"
check "app containers healthy after the interleaved run" "2" "$(running_apps $PROJ)"

step "F4 — a hung upload starves the scheduler"
info "blackholing S3 during an upload and leaving the run hung, as cron would"
docker exec -d $PROJ-backup-1 dvb backup
sleep 6
minio_blackhole
sleep 20
out=$(docker exec $PROJ-backup-1 dvb backup 2>&1)
info "a subsequent (cron-equivalent) run says: $(tail -1 <<<"$out")"
if grep -q "still in progress; skipping" <<<"$out"; then
  bad "scheduled backups are being skipped because the earlier run is wedged on S3"
  note "F4: 'restic backup' during the upload phase has no timeout. If the S3 endpoint blackholes traffic (drops packets rather than refusing), the run hangs holding /tmp/dvb.lock, and every later cron backup logs 'another backup or restore is still in progress; skipping' and exits 0. Backups then stop happening indefinitely with no unhealthy container and no non-zero exit anywhere"
else
  ok "the scheduler was not blocked by the hung run"
fi
info "checking how long the hung run persists (sampling for 120s)"
still=yes
for i in $(seq 1 24); do
  docker exec $PROJ-backup-1 sh -c 'flock -n 9 9>/tmp/dvb.lock' 2>/dev/null && { still=no; break; }
  sleep 5
done
[ "$still" = yes ] && info "still holding the lock after 120s of blackholed S3" \
                   || info "the hung run gave up after ~$((i*5))s"
minio_unblackhole
sleep 5
for i in $(seq 1 60); do
  docker exec $PROJ-backup-1 sh -c 'flock -n 9 9>/tmp/dvb.lock' 2>/dev/null && break
  sleep 5
done
info "lock free again: $(docker exec $PROJ-backup-1 sh -c 'flock -n 9 9>/tmp/dvb.lock' 2>/dev/null && echo yes || echo no)"

step "F5 — cron actually fires on schedule"
docker exec $PROJ-app-1 rm -f /data/big.bin
CRON="* * * * *" dc up -d --force-recreate backup >/dev/null 2>&1
for i in $(seq 1 120); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
info "crontab in the container:"
docker exec $PROJ-backup-1 cat /etc/crontabs/root | sed 's/^/       /'
before=$(docker exec $PROJ-backup-1 dvb restic snapshots --json 2>/dev/null | jq 'length')
fired=no
for i in $(seq 1 18); do
  sleep 10
  after=$(docker exec $PROJ-backup-1 dvb restic snapshots --json 2>/dev/null | jq 'length')
  [ "$after" != "$before" ] && { fired=yes; break; }
done
check "a cron-scheduled backup ran on its own" "yes" "$fired"

step "F6 — the persisted cron environment file"
info "$(docker exec $PROJ-backup-1 stat -c '%n mode=%a owner=%u' /run/dvb.env)"
docker exec $PROJ-backup-1 sh -c 'grep -c AWS_SECRET_ACCESS_KEY /run/dvb.env' >/dev/null 2>&1 \
  && info "the file contains the S3 credentials (expected: cron jobs need them)"
m=$(docker exec $PROJ-backup-1 stat -c '%a' /run/dvb.env)
check "credential file is mode 600" "600" "$m"

summary "GROUP F (concurrency & scheduling)"
