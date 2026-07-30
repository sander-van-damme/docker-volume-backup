#!/usr/bin/env bash
# Group D — misconfiguration and operator error
source "$(dirname "$0")/lib.sh"
COMPOSE_FILE=$LAB/stack.yml
PROJ=dvblabd
SOCK=/var/run/docker.sock

cleanup() {
  nuke $PROJ
  docker rm -f dvbd1 dvbd2 dvbd3 dvbd4 dvbd5 >/dev/null 2>&1 || true
  docker volume rm -f dvbd-staging dvbd-tiny >/dev/null 2>&1 || true
  minio_rm; docker network rm $NET >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
minio_up || exit 1
docker volume create dvbd-staging >/dev/null

runlog() { # runlog <name> <docker run args...>  -> prints logs, sets RC
  local n=$1; shift
  docker rm -f "$n" >/dev/null 2>&1
  docker run --name "$n" "$@" >/dev/null 2>&1
  RC=$(docker inspect -f '{{.State.ExitCode}}' "$n" 2>/dev/null || echo "?")
  LOGS=$(docker logs "$n" 2>&1)
}

step "D1 — no S3_BUCKET and no RESTIC_REPOSITORY"
runlog dvbd1 -l com.docker.compose.project=dvbd -v $SOCK:$SOCK -v dvbd-staging:/staging "$IMAGE" start
info "exit=$RC | $(tail -1 <<<"$LOGS")"
grep -q "S3_BUCKET (or RESTIC_REPOSITORY) must be set" <<<"$LOGS" \
  && ok "clear error for a missing bucket" || bad "unhelpful error for missing bucket"
[ "$RC" != 0 ] && ok "exits non-zero" || bad "exited 0 on a fatal misconfiguration"

step "D2 — docker socket not mounted"
t0=$SECONDS
runlog dvbd2 -l com.docker.compose.project=dvbd -e S3_BUCKET=x -e RESTIC_REPOSITORY=s3:http://minio:9000/x \
  --network $NET -v dvbd-staging:/staging "$IMAGE" start
info "exit=$RC after $((SECONDS-t0))s | $(tail -1 <<<"$LOGS")"
grep -q "mount /var/run/docker.sock" <<<"$LOGS" \
  && ok "clear error telling the operator to mount the socket" || bad "unclear socket error"

step "D3 — not started by docker compose (no project label)"
runlog dvbd3 -e S3_BUCKET=x -e RESTIC_REPOSITORY=s3:http://minio:9000/x --network $NET \
  -v $SOCK:$SOCK -v dvbd-staging:/staging "$IMAGE" start
info "exit=$RC | $(tail -1 <<<"$LOGS")"
grep -q "must be started by docker compose" <<<"$LOGS" \
  && ok "clear error when run outside compose" || bad "unclear error outside compose"

step "D4 — a custom 'hostname:' on the backup service (documented footgun)"
runlog dvbd4 --hostname totally-custom -l com.docker.compose.project=dvbd \
  -e S3_BUCKET=x -e RESTIC_REPOSITORY=s3:http://minio:9000/x --network $NET \
  -v $SOCK:$SOCK -v dvbd-staging:/staging "$IMAGE" start
info "exit=$RC | $(tail -1 <<<"$LOGS")"
grep -q "hostname" <<<"$LOGS" \
  && ok "error points at the hostname setting" || bad "custom hostname produced an unclear failure"

step "D5 — operator forgets the staging volume entirely"
docker rm -f dvbd5 >/dev/null 2>&1
docker run -d --name dvbd5 -l com.docker.compose.project=dvbd5 \
  -e S3_BUCKET=dvblab -e S3_PREFIX=d5 -e S3_ENDPOINT=http://minio:9000 \
  -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
  --network $NET -v $SOCK:$SOCK "$IMAGE" start >/dev/null
sleep 25
st=$(state_of dvbd5); lg=$(docker logs dvbd5 2>&1)
info "state=$st | $(tail -1 <<<"$lg")"
if grep -q "no volume is mounted at /staging" <<<"$lg"; then
  ok "refuses to run without a staging volume"
else
  bad "started happily without an operator-provided staging volume"
  anon=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/staging"}}{{.Name}}{{end}}{{end}}' dvbd5)
  info "an anonymous volume was used instead: ${anon:0:20}..."
  note "D5: the Dockerfile's 'VOLUME /staging' makes docker create an anonymous volume, so the 'no volume is mounted at /staging' guard in dvb can never fire. Forgetting the staging volume is silently tolerated, and the staging cache (plus the .dvb-stopped crash-recovery marker) then lives in a volume nobody tracks"
fi
docker rm -f dvbd5 >/dev/null 2>&1

step "D6 — encryption password added to an existing unencrypted repository"
dc up -d --wait --wait-timeout 120 >/dev/null 2>&1
dc exec -T backup dvb backup >/dev/null 2>&1 && ok "unencrypted repo works" || bad "setup backup failed"
out=$(RPASS=hunter2 dc up -d --force-recreate backup 2>&1)
sleep 20
st=$(state_of $PROJ-backup-1); lg=$(docker logs $PROJ-backup-1 2>&1 | tail -3)
info "state=$st | $(tail -1 <<<"$lg")"
if [ "$st" = running ] && [ "$(health_of $PROJ-backup-1)" != healthy ]; then
  ok "password mismatch keeps the container from going healthy (dependents stay down)"
elif grep -qi "wrong password\|cannot reach or initialize" <<<"$(docker logs $PROJ-backup-1 2>&1)"; then
  ok "password mismatch is reported and fatal"
else
  bad "adding a password to an existing repo did not fail loudly (state=$st health=$(health_of $PROJ-backup-1))"
  note "D6: changing RESTIC_PASSWORD against an existing repository behaved unexpectedly — check what it did to the repo"
fi
docker logs $PROJ-backup-1 2>&1 | tail -4 | sed 's/^/       /'
dc up -d --force-recreate backup >/dev/null 2>&1
for i in $(seq 1 90); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
check "removing the password again restores service" "healthy" "$(health_of $PROJ-backup-1)"

step "D7 — BACKUP_EXCLUDE_VOLUMES"
out=$(EXCLUDE=db-data dc up -d --force-recreate backup 2>&1)
for i in $(seq 1 90); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
out=$(dc exec -T backup dvb backup 2>&1)
grep -q "volume 'db-data' excluded" <<<"$out" && ok "excluded volume is skipped and logged" || bad "exclusion not honoured"
grep -q "volumes: app-data$" <<<"$out" && ok "only the remaining volume is backed up" || info "$(grep 'volumes:' <<<"$out")"
sleep 2
staged=$(dc exec -T backup ls /staging 2>/dev/null | tr -d '\r' | sort | tr '\n' ' ')
info "staging now contains: $staged"
grep -q db-data <<<"$staged" && bad "stale staging dir for the excluded volume was not cleaned up" \
                             || ok "stale staging directory of the excluded volume was removed"
dc up -d --force-recreate backup >/dev/null 2>&1
for i in $(seq 1 90); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done

step "D8 — an invalid BACKUP_CRON expression"
out=$(CRON="not a cron" dc up -d --force-recreate backup 2>&1)
sleep 20
st=$(state_of $PROJ-backup-1); h=$(health_of $PROJ-backup-1)
info "state=$st health=$h"
docker logs $PROJ-backup-1 2>&1 | tail -3 | sed 's/^/       /'
if [ "$h" = healthy ]; then
  bad "container reports healthy with a garbage cron schedule — backups will never run"
  note "D8: BACKUP_CRON is written to the crontab unvalidated. A malformed expression leaves the container healthy and dependent services happily running, but no backup is ever scheduled — a silent, open-ended failure"
else
  ok "invalid cron is caught before the container reports healthy"
fi
dc up -d --force-recreate backup >/dev/null 2>&1
for i in $(seq 1 90); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done

step "D9 — staging volume too small for the data"
docker volume create --driver local --opt type=tmpfs --opt device=tmpfs --opt o=size=32m dvbd-tiny >/dev/null
docker exec $PROJ-app-1 sh -c 'dd if=/dev/urandom of=/data/big.bin bs=1M count=120 2>/dev/null'
docker rm -f dvbd-small >/dev/null 2>&1
docker run -d --name dvbd-small -l com.docker.compose.project=$PROJ \
  -e S3_BUCKET=dvblab -e S3_PREFIX=small -e S3_ENDPOINT=http://minio:9000 \
  -e AWS_ACCESS_KEY_ID=minioadmin -e AWS_SECRET_ACCESS_KEY=minioadmin \
  -e BACKUP_CRON="0 4 * * *" \
  --network $NET -v $SOCK:$SOCK -v dvbd-tiny:/staging "$IMAGE" start >/dev/null
docker network connect ${PROJ}_default dvbd-small >/dev/null 2>&1
for i in $(seq 1 90); do [ "$(health_of dvbd-small)" = healthy ] && break; sleep 1; done
info "small-staging backup container health: $(health_of dvbd-small)"
out=$(docker exec dvbd-small dvb backup 2>&1); rc=$?
info "exit=$rc"
grep -qi "no space left\|error" <<<"$out" && ok "the out-of-space failure is visible in the output" || info "no explicit space error"
tail -3 <<<"$out" | sed 's/^/       /'
[ $rc -ne 0 ] && ok "backup exits non-zero when staging runs out of space" || bad "out-of-space backup reported success"
sleep 3
check "app containers were started again despite the staging failure" "2" "$(running_apps $PROJ)"
docker rm -f dvbd-small >/dev/null 2>&1
docker exec $PROJ-app-1 rm -f /data/big.bin

summary "GROUP D (misconfiguration)"
