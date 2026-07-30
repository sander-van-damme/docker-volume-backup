#!/usr/bin/env bash
# End-to-end test: backup + retention + fresh-deploy restore against a
# local MinIO. Run from the repository root: ./test/run-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

COMPOSE=(docker compose -f docker-compose.test.yml -p dvbtest)
MINIO=dvb-minio
NET=dvb-s3

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*"; exit 1; }
ok()   { printf '\033[32mOK: %s\033[0m\n' "$*"; }

cleanup() {
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$MINIO" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

step "starting MinIO (local S3)"
docker network create "$NET" >/dev/null
docker run -d --name "$MINIO" --network "$NET" --network-alias minio \
  -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
  quay.io/minio/minio server /data >/dev/null

for i in $(seq 1 30); do
  docker run --rm --network "$NET" alpine:3.22 wget -q -O /dev/null http://minio:9000/minio/health/ready 2>/dev/null && break
  [ "$i" = 30 ] && fail "MinIO did not become ready"
  sleep 1
done
ok "MinIO ready"

step "first deploy (empty volumes, empty S3)"
"${COMPOSE[@]}" up -d --build --wait --wait-timeout 180

# seed the database with recognizable data
sleep 5
"${COMPOSE[@]}" exec -T db psql -U postgres -c \
  "CREATE TABLE t (msg text); INSERT INTO t VALUES ('backup-me');" >/dev/null
ok "stack up, test data written"

step "running a backup"
"${COMPOSE[@]}" exec -T backup dvb backup

"${COMPOSE[@]}" exec -T backup dvb restic snapshots | grep -q staging \
  || fail "no snapshots found after backup"
ok "snapshots created"

step "verifying containers were restarted after backup"
[ "$("${COMPOSE[@]}" ps --status running --services | wc -l)" -ge 4 ] \
  || fail "not all services running after backup"
ok "all services running"

step "verifying init marker on intentionally-empty volume"
"${COMPOSE[@]}" exec -T media-user test -f /srv/media/.docker-volume-backup.init \
  || fail "init marker missing on empty media volume"
ok "marker present"

step "running a second backup (incremental)"
"${COMPOSE[@]}" exec -T backup dvb backup

step "simulating disaster: destroying the stack and all volumes"
"${COMPOSE[@]}" down -v

step "fresh deploy: expecting automatic restore from S3"
"${COMPOSE[@]}" up -d --build --wait --wait-timeout 180
sleep 5

got=$("${COMPOSE[@]}" exec -T db psql -U postgres -tAc "SELECT msg FROM t;")
[ "$got" = "backup-me" ] || fail "database not restored (got: '$got')"
ok "database restored from backup"

"${COMPOSE[@]}" exec -T app cat /data/hello.txt | grep -q "hello from app" \
  || fail "app volume not restored"
ok "app volume restored"

"${COMPOSE[@]}" exec -T media-user test -f /srv/media/.docker-volume-backup.init \
  || fail "init marker not restored on media volume"
[ -z "$("${COMPOSE[@]}" exec -T media-user ls -A /srv/media | grep -v '^\.docker-volume-backup.init$')" ] \
  || fail "media volume should only contain the marker"
ok "empty volume restored as intentionally-empty"

step "verifying the marker is removed once real data appears"
"${COMPOSE[@]}" exec -T media-user sh -c 'echo x > /srv/media/file.txt'
"${COMPOSE[@]}" exec -T backup dvb backup
"${COMPOSE[@]}" exec -T media-user test ! -f /srv/media/.docker-volume-backup.init \
  || fail "init marker still present after data appeared in media volume"
ok "marker removed"

step "waiting for a cron-scheduled backup (schedule: every minute)"
before=$("${COMPOSE[@]}" exec -T backup dvb restic snapshots --json | tr -d '[:space:]')
for i in $(seq 1 15); do
  sleep 10
  after=$("${COMPOSE[@]}" exec -T backup dvb restic snapshots --json | tr -d '[:space:]')
  [ "$after" != "$before" ] && break
  [ "$i" = 15 ] && fail "cron did not trigger a backup within 150s"
done
ok "cron-scheduled backup ran"

printf '\n\033[32mALL TESTS PASSED\033[0m\n'
