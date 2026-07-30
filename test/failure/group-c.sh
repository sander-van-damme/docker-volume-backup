#!/usr/bin/env bash
# Group C — depends_on misconfiguration
source "$(dirname "$0")/lib.sh"
COMPOSE_FILE=$LAB/depends.yml
PROJ=dvblabc

cleanup() { nuke $PROJ; docker rm -f dvblab-outsider >/dev/null 2>&1 || true; minio_rm; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

step "C0 — first deploy: three services, one wired correctly, two not"
minio_up || exit 1
dc up -d >/dev/null 2>&1
for i in $(seq 1 120); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
check "backup healthy" "healthy" "$(health_of $PROJ-backup-1)"
sleep 3
for s in good nodep weakdep; do
  docker exec $PROJ-$s-1 sh -c "echo REAL-DATA-$s > /data/payload" 2>/dev/null
done
dc exec -T backup dvb backup >/dev/null 2>&1 && ok "backup of all three volumes ok" || bad "backup failed"
for s in good nodep weakdep; do
  info "$s payload before disaster: $(docker exec $PROJ-$s-1 cat /data/payload 2>/dev/null)"
done

# ---------------------------------------------------------------------------
step "C1 — disaster: wipe everything, redeploy, see which volumes get restored"
dc down -v --timeout 5 >/dev/null 2>&1
dc up -d >/dev/null 2>&1
for i in $(seq 1 150); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
sleep 5

g=$(docker exec $PROJ-good-1 cat /data/payload 2>/dev/null | tr -d '\r')
n=$(docker exec $PROJ-nodep-1 cat /data/payload 2>/dev/null | tr -d '\r')
w=$(docker exec $PROJ-weakdep-1 cat /data/payload 2>/dev/null | tr -d '\r')
info "good    (depends_on: service_healthy) -> '$g'"
info "nodep   (no depends_on)               -> '$n'"
info "weakdep (depends_on without condition)-> '$w'"

check "correctly-wired service got its data back" "REAL-DATA-good" "$g"

if [ "$n" = "REAL-DATA-nodep" ]; then
  ok "nodep happened to be restored anyway (won the race this time)"
  note "C1: the no-depends_on service survived only by luck of timing — not a guarantee"
else
  bad "nodep was NOT restored: got '$n' instead of the backed-up data"
  note "C1: a service without depends_on can initialize its own empty volume before the restore pass sees it; dvb then reads the volume as 'contains data' and silently skips the restore — the backup is still in S3 but the running stack is a fork"
fi
if [ "$w" = "REAL-DATA-weakdep" ]; then
  ok "weakdep restored (won the race this time)"
else
  bad "weakdep was NOT restored: got '$w'"
  note "C1: 'depends_on: [backup]' without 'condition: service_healthy' gives no protection — compose only waits for the container to start, not for the restore to finish"
fi

step "C1b — what does dvb's own log say it decided?"
docker logs $PROJ-backup-1 2>&1 | grep -E "volume '(good|nodep|weakdep)-data'" | sed 's/^/       /'

step "C1c — the backups themselves are still intact in S3"
for v in good-data nodep-data weakdep-data; do
  c=$(docker exec $PROJ-backup-1 dvb restic snapshots --json --path /staging/$v 2>/dev/null | jq 'length')
  info "$v: $c snapshot(s) in the repository"
done
ok "no backup data was lost — only the running stack diverged"

# ---------------------------------------------------------------------------
step "C2 — dependent services when the backup container never becomes healthy"
dc down -v --timeout 5 >/dev/null 2>&1
minio_down
dc up -d >/dev/null 2>&1
sleep 45
info "backup: state=$(state_of $PROJ-backup-1) health=$(health_of $PROJ-backup-1)"
info "good:   state=$(state_of $PROJ-good-1)"
info "nodep:  state=$(state_of $PROJ-nodep-1)"
[ "$(state_of $PROJ-good-1)" != running ] \
  && ok "correctly-gated service stayed down while S3 was unreachable (no forked data)" \
  || bad "gated service started even though the backup container is not healthy"
if [ "$(state_of $PROJ-nodep-1)" = running ]; then
  bad "ungated service started and initialized its volume while S3 was unreachable"
  note "C2: with S3 down on a fresh deploy, an ungated service writes fresh state into a volume that has a backup — exactly the data fork the design is meant to prevent"
else
  ok "ungated service is not running"
fi
minio_start

# ---------------------------------------------------------------------------
step "C3 — a container from ANOTHER project mounting one of our volumes"
dc down -v --timeout 5 >/dev/null 2>&1
dc up -d >/dev/null 2>&1
for i in $(seq 1 150); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
docker run -d --name dvblab-outsider -v ${PROJ}_good-data:/shared alpine:3.22 \
  sh -c 'while true; do echo tick >> /shared/outsider.log; sleep 1; done' >/dev/null
sleep 3
out=$(dc exec -T backup dvb backup 2>&1)
info "$(grep 'stopping' <<<"$out")"
sleep 2
check "the outside container was restarted after the backup" "running" "$(state_of dvblab-outsider)"
if grep -q "stopping 4 container(s)" <<<"$out"; then
  ok "dvb stopped the foreign container along with its own three services"
  note "C3: volume users are found with 'docker ps --filter volume=', which is not scoped to the compose project. Any container mounting one of the project's volumes — from another compose project, or a plain 'docker run' — is stopped for the backup and then started again with 'docker start'. That is what you want for a consistent copy, but it means the backup container reaches outside its own project, and a foreign container that was deliberately left stopped mid-backup comes back running"
else
  bad "expected 4 containers to be stopped, got: $(grep -o 'stopping [0-9]* container' <<<"$out")"
fi
docker rm -f dvblab-outsider >/dev/null 2>&1

summary "GROUP C (depends_on)"
