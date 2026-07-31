#!/usr/bin/env bash
# Group E — data fidelity, retention, and multi-project scoping
source "$(dirname "$0")/lib.sh"
COMPOSE_FILE=$LAB/stack.yml
PROJ=dvblabe
P1=dvbproj-one
P2=dvbproj-two

cleanup() {
  nuke $PROJ "$LAB/stack.yml"
  nuke $P1 "$LAB/multi.yml"; nuke $P2 "$LAB/multi.yml"
  minio_rm; docker network rm $NET >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
minio_up || exit 1

# ---------------------------------------------------------------------------
step "E1 — two projects share one bucket AND prefix, with identically named volumes"
COMPOSE_FILE=$LAB/multi.yml
PROJ=$P1; dc up -d --wait --wait-timeout 120 >/dev/null 2>&1
docker exec $P1-worker-1 sh -c 'echo PROJECT-ONE-SECRET > /data/payload'
dc exec -T backup dvb backup >/dev/null 2>&1 && ok "project one backed up" || bad "project one backup failed"

PROJ=$P2; dc up -d --wait --wait-timeout 120 >/dev/null 2>&1
sleep 2
p2=$(docker exec $P2-worker-1 cat /data/payload 2>/dev/null | tr -d '\r')
info "project two's fresh volume contains: '$p2'"
check "project two did NOT inherit project one's data" "FRESH" "$p2"
docker logs $P2-backup-1 2>&1 | grep "volume 'data'" | sed 's/^/       /'

docker exec $P2-worker-1 sh -c 'echo PROJECT-TWO-SECRET > /data/payload'
dc exec -T backup dvb backup >/dev/null 2>&1 && ok "project two backed up into the same repository" || bad "project two backup failed"

info "snapshot hosts in the shared repository:"
docker exec $P2-backup-1 dvb restic snapshots --json 2>/dev/null \
  | jq -r 'group_by(.hostname)[] | "       \(.[0].hostname): \(length) snapshot(s)"'

step "E1b — destroy project one and redeploy: it must get ITS OWN data back"
PROJ=$P1; dc down -v --timeout 5 >/dev/null 2>&1
dc up -d --wait --wait-timeout 150 >/dev/null 2>&1
sleep 3
got=$(docker exec $P1-worker-1 cat /data/payload 2>/dev/null | tr -d '\r')
check "project one restored its own snapshot, not project two's" "PROJECT-ONE-SECRET" "$got"

step "E1c — retention in a shared repository prunes only your own snapshots"
PROJ=$P1
before2=$(docker exec $P2-backup-1 dvb restic snapshots --json --host $P2 2>/dev/null | jq 'length')
for i in 1 2 3 4 5; do
  docker exec $P1-worker-1 sh -c "echo rev-$i >> /data/payload"
  dc exec -T backup dvb backup >/dev/null 2>&1
done
after1=$(docker exec $P1-backup-1 dvb restic snapshots --json --host $P1 2>/dev/null | jq 'length')
after2=$(docker exec $P2-backup-1 dvb restic snapshots --json --host $P2 2>/dev/null | jq 'length')
info "project one snapshots after 5 more backups (retention 3): $after1"
info "project two snapshots: $before2 before -> $after2 after"
check "retention capped project one at its limit" "3" "$after1"
check "project two's snapshots were untouched by project one's prune" "$before2" "$after2"
nuke $P1 "$LAB/multi.yml"; nuke $P2 "$LAB/multi.yml"

# ---------------------------------------------------------------------------
COMPOSE_FILE=$LAB/stack.yml
PROJ=dvblabe
step "E2 — file-level fidelity through a full backup/disaster/restore cycle"
dc up -d --wait --wait-timeout 150 >/dev/null 2>&1
for i in $(seq 1 90); do dc exec -T db pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec $PROJ-app-1 sh -c '
  set -e
  mkdir -p "/data/nested/deep dir" /data/emptydir
  echo content > /data/nested/regular.txt
  ln -s ../regular.txt "/data/nested/deep dir/link-to-regular"
  ln /data/nested/regular.txt /data/nested/hardlink.txt
  echo exe > /data/runme.sh && chmod 755 /data/runme.sh
  echo secret > /data/private.txt && chmod 600 /data/private.txt
  echo "unicode ok" > "/data/naïve file — ünïcode.txt"
  dd if=/dev/zero of=/data/sparse.bin bs=1M count=0 seek=64 2>/dev/null
  adduser -D -u 4242 testowner 2>/dev/null || true
  echo owned > /data/owned.txt && chown 4242:4242 /data/owned.txt
  mkfifo /data/afifo
'
sig() { docker exec $PROJ-app-1 sh -c '
  cd /data
  find . -mindepth 1 | sort | while read -r f; do
    printf "%s|%s|%s|%s\n" "$f" "$(stat -c %f%a "$f")" "$(stat -c %u:%g "$f")" "$(readlink "$f" 2>/dev/null)"
  done
  echo "hardlink-inodes-match:$([ "$(stat -c %i nested/regular.txt)" = "$(stat -c %i nested/hardlink.txt)" ] && echo yes || echo no)"
  echo "sparse-apparent:$(stat -c %s sparse.bin)"
'; }
before=$(sig)
info "captured $(wc -l <<<"$before") filesystem entries"
dc exec -T db psql -U postgres -c "CREATE TABLE t (msg text); INSERT INTO t VALUES ('e-payload');" >/dev/null \
  || bad "could not seed the database"
dc exec -T backup dvb backup >/dev/null 2>&1 && ok "backup of the fidelity fixture ok" || bad "backup failed"

dc down -v --timeout 5 >/dev/null 2>&1
dc up -d --wait --wait-timeout 180 >/dev/null 2>&1
for i in $(seq 1 90); do dc exec -T db pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
after=$(sig)
if [ "$before" = "$after" ]; then
  ok "every file, mode, owner, symlink, hardlink and fifo survived the round trip"
else
  bad "filesystem differences after restore:"
  diff <(echo "$before") <(echo "$after") | head -25 | sed 's/^/       /'
fi
got=$(dc exec -T db psql -U postgres -tAc "SELECT msg FROM t;" 2>/dev/null | tr -d '[:space:]')
check "postgres data directory restored into a working database" "e-payload" "$got"

step "E3 — deletions propagate (a deleted file must not come back)"
docker exec $PROJ-app-1 rm -f /data/private.txt
dc exec -T backup dvb backup >/dev/null 2>&1
dc down -v --timeout 5 >/dev/null 2>&1
dc up -d --wait --wait-timeout 180 >/dev/null 2>&1
sleep 3
docker exec $PROJ-app-1 test -e /data/private.txt \
  && bad "a deleted file reappeared after restore" \
  || ok "deleted file stayed deleted through backup and restore"
docker exec $PROJ-app-1 test -e /data/runme.sh \
  && ok "other files are still there" || bad "restore lost unrelated files"

step "E4 — a volume that already has data is never overwritten by a restore"
docker exec $PROJ-app-1 sh -c 'echo LOCAL-CHANGES-NOT-IN-BACKUP > /data/hello.txt'
dc restart backup >/dev/null 2>&1
for i in $(seq 1 90); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
sleep 2
check "local, un-backed-up changes were left alone" "LOCAL-CHANGES-NOT-IN-BACKUP" \
      "$(docker exec $PROJ-app-1 cat /data/hello.txt | tr -d '\r')"

step "E5 — a volume added to the project after backups exist"
docker volume create -d local --label com.docker.compose.project=$PROJ \
  --label com.docker.compose.volume=brand-new ${PROJ}_brand-new >/dev/null
dc restart backup >/dev/null 2>&1
for i in $(seq 1 90); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
docker logs $PROJ-backup-1 2>&1 | grep "brand-new" | tail -2 | sed 's/^/       /'
docker logs $PROJ-backup-1 2>&1 | grep -q "volume 'brand-new' is empty and has no backups" \
  && ok "an unknown empty volume is left for the application to initialize" \
  || bad "new empty volume handled unexpectedly"

step "E6 — renaming the project hides existing backups (documented caveat)"
dc exec -T backup dvb backup >/dev/null 2>&1
hosts=$(dc exec -T backup dvb restic snapshots --json 2>/dev/null | jq -r '[.[].hostname]|unique|join(",")')
info "snapshot hosts: $hosts"
grep -q "$PROJ" <<<"$hosts" && ok "snapshots are tagged with the compose project name (restore scoping key)" \
                            || bad "snapshots are not scoped by project"
note "E6: because scoping is by project name, renaming the project or its directory makes existing backups invisible to the automatic restore — a fresh deploy after a rename starts empty while the data sits in the bucket under the old host. This is documented in the README, but nothing warns at runtime."

summary "GROUP E (data fidelity & scoping)"
