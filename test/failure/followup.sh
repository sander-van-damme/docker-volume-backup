#!/usr/bin/env bash
# Follow-ups on ambiguous results from groups D, E and F.
source "$(dirname "$0")/lib.sh"
COMPOSE_FILE=$LAB/stack.yml
PROJ=dvblabh

cleanup() { nuke $PROJ; minio_rm; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
minio_up || exit 1

step "H1 — D6 follow-up: what does a mismatched RESTIC_PASSWORD actually do?"
dc up -d --wait --wait-timeout 150 >/dev/null 2>&1
sleep 4
dc exec -T db psql -U postgres -c "CREATE TABLE t (msg text); INSERT INTO t VALUES ('h-payload');" >/dev/null 2>&1
dc exec -T backup dvb backup >/dev/null 2>&1
n0=$(dc exec -T backup dvb restic snapshots --json 2>/dev/null | jq 'length')
info "unencrypted repository has $n0 snapshot(s)"

info "operator now sets RESTIC_PASSWORD on the existing repository"
RPASS=hunter2 dc up -d --force-recreate backup >/dev/null 2>&1
for i in $(seq 1 120); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
h=$(health_of $PROJ-backup-1)
info "backup container health: $h"
if [ "$h" = healthy ]; then
  bad "the container reports HEALTHY even though it cannot open the repository"
else
  ok "the container does not report healthy with a mismatched password"
fi
info "dvb's own view of the repository:"
docker logs $PROJ-backup-1 2>&1 | tail -4 | sed 's/^/       /'

info "now what a scheduled backup would do:"
out=$(docker exec $PROJ-backup-1 dvb backup 2>&1); rc=$?
info "backup exit=$rc"
tail -5 <<<"$out" | sed 's/^/       /'
if [ $rc -ne 0 ]; then
  ok "the backup itself fails loudly (visible in the container log)"
  note "H1: with a mismatched RESTIC_PASSWORD, ensure_repo cannot read the repo config, concludes 'no repository found', runs 'restic init', gets 'config file already exists' and treats that as success. The container therefore goes HEALTHY, dependent services start, and only the actual backup fails — in cron, that failure is a log line nobody is watching. Health, exit codes and depends_on all report a working stack that has not backed anything up since the change"
else
  bad "the backup reported success with a mismatched password"
fi
info "were the application containers stopped by that doomed run?"
check "app containers still running" "2" "$(running_apps $PROJ)"

info "and the restore path on a fresh deploy with the wrong password:"
dc down --timeout 5 >/dev/null 2>&1
docker volume rm -f ${PROJ}_app-data >/dev/null 2>&1
RPASS=hunter2 dc up -d >/dev/null 2>&1
sleep 40
h=$(health_of $PROJ-backup-1); st=$(state_of $PROJ-backup-1)
info "fresh deploy with wrong password: state=$st health=$h"
docker logs $PROJ-backup-1 2>&1 | tail -3 | sed 's/^/       /'
if [ "$h" = healthy ]; then
  bad "a fresh deploy with the wrong password went healthy and started the app on an empty volume"
  note "H1b: on a fresh deploy the empty volume's snapshot lookup fails too, so the volume is treated as 'no backups' territory — dependent services start on empty state while an intact backup sits in the bucket"
else
  ok "a fresh deploy with the wrong password refuses to start the stack"
fi
nuke $PROJ

# ---------------------------------------------------------------------------
step "H2 — E2 follow-up: is postgres genuinely restored (given enough time)?"
minio_rm; minio_up >/dev/null
dc up -d --wait --wait-timeout 150 >/dev/null 2>&1
for i in $(seq 1 60); do dc exec -T db pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
dc exec -T db psql -U postgres -c "CREATE TABLE t (msg text); INSERT INTO t VALUES ('h2-payload');" >/dev/null 2>&1
dc exec -T backup dvb backup >/dev/null 2>&1
dc down -v --timeout 5 >/dev/null 2>&1
dc up -d --wait --wait-timeout 180 >/dev/null 2>&1
ready=no
for i in $(seq 1 90); do dc exec -T db pg_isready -U postgres >/dev/null 2>&1 && { ready=yes; break; }; sleep 1; done
info "postgres accepted connections after ~${i}s"
got=$(dc exec -T db psql -U postgres -tAc "SELECT msg FROM t;" 2>/dev/null | tr -d '[:space:]')
check "postgres data restored after a full wipe" "h2-payload" "$got"
[ "$ready" = yes ] && ok "the restored data directory started cleanly" || bad "postgres never became ready"

# ---------------------------------------------------------------------------
step "H3 — F5 follow-up: cron fires on the configured schedule"
CRON="* * * * *" dc up -d --force-recreate backup >/dev/null 2>&1
for i in $(seq 1 120); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
info "crontab: $(docker exec $PROJ-backup-1 cat /etc/crontabs/root)"
before=$(docker exec $PROJ-backup-1 dvb restic snapshots --json 2>/dev/null | jq 'length')
fired=no
for i in $(seq 1 18); do
  sleep 10
  after=$(docker exec $PROJ-backup-1 dvb restic snapshots --json 2>/dev/null | jq 'length')
  [ "$after" != "$before" ] && { fired=yes; break; }
done
check "a cron-scheduled backup ran unattended" "yes" "$fired"
info "snapshots went $before -> $after"

step "H4 — timezone handling for the schedule"
info "container date:  $(docker exec $PROJ-backup-1 date)"
info "TZ inside cron env: $(docker exec $PROJ-backup-1 sh -c '. /run/dvb.env; echo $TZ')"
z=$(docker exec $PROJ-backup-1 sh -c 'date +%Z')
[ -n "$z" ] && ok "timezone applied inside the container ($z)" || bad "no timezone set"

summary "FOLLOW-UPS"
