#!/usr/bin/env bash
# Group A — S3 / object-store failures
source "$(dirname "$0")/lib.sh"
COMPOSE_FILE=$LAB/stack.yml
PROJ=dvblaba

cleanup() { nuke $PROJ; minio_rm; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

step "A0 — bring up a healthy stack and take one good backup"
minio_up || exit 1
dc up -d --wait --wait-timeout 120 >/dev/null 2>&1
sleep 4
dc exec -T db psql -U postgres -c "CREATE TABLE t (msg text); INSERT INTO t VALUES ('a-payload');" >/dev/null 2>&1
dc exec -T backup dvb backup >/dev/null 2>&1 \
  && ok "baseline backup succeeded" || bad "baseline backup failed"

# ---------------------------------------------------------------------------
step "A1 — scheduled backup while S3 is down: must NOT stop the application"
db_started_before=$(docker inspect -f '{{.State.StartedAt}}' $PROJ-db-1)
app_started_before=$(docker inspect -f '{{.State.StartedAt}}' $PROJ-app-1)
minio_down
info "MinIO stopped; running 'dvb backup'"
t0=$SECONDS
out=$(dc exec -T backup dvb backup 2>&1); rc=$?
info "exit=$rc after $((SECONDS-t0))s"
[ $rc -ne 0 ] && ok "backup failed loudly (exit $rc) instead of pretending to succeed" \
              || bad "backup reported success with S3 down"
grep -qi "cannot reach or initialize" <<<"$out" \
  && ok "error message names the unreachable repository" \
  || bad "unclear error: $(tail -2 <<<"$out")"

db_started_after=$(docker inspect -f '{{.State.StartedAt}}' $PROJ-db-1)
app_started_after=$(docker inspect -f '{{.State.StartedAt}}' $PROJ-app-1)
check "db was never restarted (zero downtime on S3 outage)" "$db_started_before" "$db_started_after"
check "app was never restarted (zero downtime on S3 outage)" "$app_started_before" "$app_started_after"
check "all app containers still running" "2" "$(running_apps $PROJ)"
[ -n "$(dc exec -T backup ls -A /staging 2>/dev/null | grep -v '^\.' || true)" ] \
  && info "staging still holds the previous copy (expected)"

# ---------------------------------------------------------------------------
step "A2 — recovery: same stack backs up fine once S3 returns"
minio_start
dc exec -T backup dvb backup >/dev/null 2>&1 \
  && ok "backup succeeds again after S3 comes back" || bad "backup still failing after S3 recovery"
n=$(dc exec -T backup dvb restic snapshots --json 2>/dev/null | jq 'length')
info "snapshots in repo: $n"

# ---------------------------------------------------------------------------
step "A3 — wrong S3 credentials"
minio_down; minio_start   # ensure clean
AKID=wrong SECRET=alsowrong dc up -d --force-recreate backup >/dev/null 2>&1
sleep 5
out=$(AKID=wrong SECRET=alsowrong dc exec -T backup dvb backup 2>&1); rc=$?
[ $rc -ne 0 ] && ok "bad credentials fail the backup (exit $rc)" || bad "bad credentials silently accepted"
check "app containers untouched by the credential failure" "2" "$(running_apps $PROJ)"
dc up -d --force-recreate backup >/dev/null 2>&1; sleep 6

# ---------------------------------------------------------------------------
step "A4 — S3 blackholed (packets dropped, not refused): does it hang forever?"
minio_blackhole
t0=$SECONDS
out=$(timeout 420 docker exec $PROJ-backup-1 dvb backup 2>&1); rc=$?
el=$((SECONDS-t0))
info "exit=$rc after ${el}s"
minio_unblackhole
if [ $rc -eq 124 ]; then
  bad "backup hung past 420s against a blackholed endpoint (never gave up)"
  note "A4: a silently-dropping S3 endpoint can wedge a backup run for a very long time"
else
  ok "backup gave up on a blackholed endpoint after ${el}s (exit $rc)"
  [ $el -gt 180 ] && note "A4: giving up took ${el}s — long, but bounded"
fi
check "app containers still running after blackhole test" "2" "$(running_apps $PROJ)"

# ---------------------------------------------------------------------------
step "A5 — S3 dies mid-upload (after containers were already restarted)"
minio_start
docker exec $PROJ-app-1 sh -c 'dd if=/dev/urandom of=/data/big.bin bs=1M count=400 2>/dev/null'
info "wrote 400MB into app-data to make the upload slow"
( sleep 6; minio_blackhole; echo blackholed ) &
killer=$!
t0=$SECONDS
out=$(timeout 300 docker exec $PROJ-backup-1 dvb backup 2>&1); rc=$?
wait $killer 2>/dev/null
info "exit=$rc after $((SECONDS-t0))s"
grep -q "starting .* container(s) again" <<<"$out" \
  && ok "containers were restarted before the upload stage" \
  || info "log did not show a restart line (containers may not have needed stopping)"
check "app containers running despite the failed upload" "2" "$(running_apps $PROJ)"
[ "$(state_of $PROJ-db-1)" = running ] && ok "db survived a mid-upload S3 outage" || bad "db is $(state_of $PROJ-db-1)"
minio_unblackhole; sleep 3
docker exec $PROJ-app-1 rm -f /data/big.bin

step "A6 — repository is left usable after all that"
minio_start
out=$(docker exec $PROJ-backup-1 dvb backup 2>&1); rc=$?
[ $rc -eq 0 ] && ok "clean backup after the outage series" || bad "repo left broken: $(tail -3 <<<"$out")"
got=$(dc exec -T db psql -U postgres -tAc "SELECT msg FROM t;" 2>/dev/null | tr -d '[:space:]')
check "database data intact through all outages" "a-payload" "$got"

summary "GROUP A (S3 failures)"
