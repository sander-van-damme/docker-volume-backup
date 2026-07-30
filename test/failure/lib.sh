#!/usr/bin/env bash
# Shared helpers for the docker-volume-backup failure-injection suite.
#
# Every group script sources this, then drives a real compose stack against a
# real (local) S3 and breaks something specific. Run them through run-all.sh.
set -uo pipefail

LAB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$LAB/../.." && pwd)
NET=dvblab-s3
MINIO=dvblab-minio
IMAGE=${DVB_IMAGE:-dvb:test}
export DVB_IMAGE=$IMAGE

PASS=0; FAIL=0; NOTES=()

step() { printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '\033[32m  PASS\033[0m %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '\033[31m  FAIL\033[0m %s\n' "$*"; }
note() { NOTES+=("$*"); printf '\033[33m  NOTE\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }

check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

summary() {
  printf '\n\033[1m---- %s: %d passed, %d failed ----\033[0m\n' "${1:-summary}" "$PASS" "$FAIL"
  if ((${#NOTES[@]})); then
    printf '\033[33mNotes:\033[0m\n'
    printf '  - %s\n' "${NOTES[@]}"
  fi
}

minio_up() {
  docker network create "$NET" >/dev/null 2>&1 || true
  docker rm -f "$MINIO" >/dev/null 2>&1 || true
  docker run -d --name "$MINIO" --network "$NET" --network-alias minio \
    -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
    quay.io/minio/minio server /data >/dev/null
  local i
  for i in $(seq 1 40); do
    docker run --rm --network "$NET" alpine:3.22 \
      wget -q -O /dev/null http://minio:9000/minio/health/ready 2>/dev/null && return 0
    sleep 1
  done
  echo "MinIO never became ready" >&2; return 1
}

minio_down()  { docker stop -t 1 "$MINIO" >/dev/null 2>&1; }
minio_start() { docker start "$MINIO" >/dev/null 2>&1; sleep 3; }
minio_rm()    { docker rm -f "$MINIO" >/dev/null 2>&1 || true; }

# Detach MinIO from the stack network without stopping it: packets are then
# silently dropped rather than refused, which simulates a hung/blackholed
# endpoint — the failure mode that exposes missing timeouts.
minio_blackhole()   { docker network disconnect -f "$NET" "$MINIO" >/dev/null 2>&1; }
minio_unblackhole() { docker network connect --alias minio "$NET" "$MINIO" >/dev/null 2>&1; }

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJ" "$@"; }

nuke() { # nuke <project> [compose-file]
  docker compose -f "${2:-$COMPOSE_FILE}" -p "$1" down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
}

# Count running application containers of a compose project: everything with
# the project label except the backup service and the suite's own scratch
# containers (which are labelled into the project on purpose).
running_apps() {
  docker ps --format '{{.Names}}' --filter "label=com.docker.compose.project=$1" \
    | grep -v -- '-backup-' \
    | grep -vE '^dvb[a-z]*-(small|stubborn|pg|badcreds)$' \
    | wc -l | tr -d ' '
}

health_of() { docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo missing; }
state_of()  { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo missing; }

# A genuine crash: SIGKILL the container's init process from the host. Going
# through `docker kill` instead flags the container as manually stopped, which
# suppresses its restart policy (that variant is covered separately in B1b).
crash() {
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$1")
  kill -9 "$pid" 2>/dev/null
}

# Healthy AND not holding the backup lock — i.e. genuinely idle.
wait_ready() {
  local i
  for i in $(seq 1 180); do
    if [ "$(health_of "$PROJ-backup-1")" = healthy ] \
       && docker exec "$PROJ-backup-1" sh -c 'flock -n 9 9>/tmp/dvb.lock' 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  info "WARNING: backup container not idle after 180s (health=$(health_of "$PROJ-backup-1"))"
}
