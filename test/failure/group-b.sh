#!/usr/bin/env bash
# Group B — backup container crashes / restarts
source "$(dirname "$0")/lib.sh"
COMPOSE_FILE=$LAB/stack.yml
PROJ=dvblabb

cleanup() { nuke $PROJ; minio_rm; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

step "B0 — healthy stack with enough data to make staging take a few seconds"
minio_up || exit 1
dc up -d --wait --wait-timeout 120 >/dev/null 2>&1
sleep 4
dc exec -T db psql -U postgres -c "CREATE TABLE t (msg text); INSERT INTO t VALUES ('b-payload');" >/dev/null 2>&1
docker exec $PROJ-app-1 sh -c 'dd if=/dev/urandom of=/data/big.bin bs=1M count=600 2>/dev/null'
dc exec -T backup dvb backup >/dev/null 2>&1 && ok "baseline backup ok" || bad "baseline backup failed"

# ---------------------------------------------------------------------------
step "B1 — SIGKILL the backup container while the app containers are stopped"
info "starting a backup in the background, then killing dvb the moment db is down"
docker exec -d $PROJ-backup-1 dvb backup
killed=no
for i in $(seq 1 200); do
  if [ "$(state_of $PROJ-db-1)" = exited ]; then
    crash $PROJ-backup-1
    killed=yes; break
  fi
  sleep 0.2
done
check "reached the vulnerable window (app containers stopped)" "yes" "$killed"
info "db=$(state_of $PROJ-db-1) app=$(state_of $PROJ-app-1) backup=$(state_of $PROJ-backup-1)"

# The stopped-containers list must survive on the staging volume.
sf=$(docker run --rm -v ${PROJ}_backup-staging:/s alpine:3.22 sh -c 'cat /s/.dvb-stopped 2>/dev/null | wc -l')
[ "$sf" -ge 1 ] && ok "stopped-container list persisted to the staging volume ($sf entries)" \
                || bad "no .dvb-stopped file left behind — crash recovery has nothing to work from"

info "waiting for docker's restart policy to bring dvb back and recover"
recovered=no
for i in $(seq 1 120); do
  [ "$(running_apps $PROJ)" = "2" ] && { recovered=yes; break; }
  sleep 1
done
check "app containers were started again after the crash" "yes" "$recovered"
info "recovery took ~${i}s; backup health=$(health_of $PROJ-backup-1)"
docker logs $PROJ-backup-1 2>&1 | grep -q "interrupted backup" \
  && ok "recovery path logged it was cleaning up after an interrupted backup" \
  || bad "no 'interrupted backup' log line"
lf=$(docker run --rm -v ${PROJ}_backup-staging:/s alpine:3.22 sh -c 'test -e /s/.dvb-stopped && echo present || echo gone')
check "stopped-list cleaned up after recovery" "gone" "$lf"


# ---------------------------------------------------------------------------
wait_ready
step "B1b — operator runs 'docker kill'/'docker stop' on dvb mid-backup"
docker exec -d $PROJ-backup-1 dvb backup
killed=no
for i in $(seq 1 200); do
  if [ "$(state_of $PROJ-db-1)" = exited ]; then
    docker kill -s KILL $PROJ-backup-1 >/dev/null 2>&1
    killed=yes; break
  fi
  sleep 0.2
done
check "reached the vulnerable window" "yes" "$killed"
sleep 25
info "after 25s: backup=$(state_of $PROJ-backup-1) restartcount=$(docker inspect -f '{{.RestartCount}}' $PROJ-backup-1) apps running=$(running_apps $PROJ)"
if [ "$(state_of $PROJ-backup-1)" = running ]; then
  ok "docker restarted the backup container and the stack recovered"
else
  bad "the whole stack is down: docker treats 'docker kill' as a manual stop, so 'restart: unless-stopped' does not fire"
  note "B1b: dvb stops the application containers with 'docker stop', which clears their own restart policies. If the backup container then goes away in a way docker considers manual (docker kill / docker stop / compose stop / compose down on just that service), nothing brings the application back — the entire stack stays down until someone starts the backup container again. The recovery logic is correct; it just never gets to run"
fi
info "starting the backup container again by hand"
docker start $PROJ-backup-1 >/dev/null 2>&1
for i in $(seq 1 120); do [ "$(running_apps $PROJ)" = "2" ] && break; sleep 1; done
check "manual start of dvb recovers the stopped app containers" "2" "$(running_apps $PROJ)"

# ---------------------------------------------------------------------------
wait_ready
step "B2 — same crash, but the container is REPLACED rather than restarted"
docker exec -d $PROJ-backup-1 dvb backup
killed=no
for i in $(seq 1 200); do
  if [ "$(state_of $PROJ-db-1)" = exited ]; then
    docker update --restart=no $PROJ-backup-1 >/dev/null 2>&1
    crash $PROJ-backup-1
    killed=yes; break
  fi
  sleep 0.2
done
check "reached the vulnerable window again" "yes" "$killed"
sleep 5
info "with restart disabled: db=$(state_of $PROJ-db-1) app=$(state_of $PROJ-app-1)"
[ "$(running_apps $PROJ)" -lt 2 ] \
  && ok "as expected, nothing recovers while the backup container stays down" \
  || note "B2: containers came back without dvb restarting (unexpected)"
info "now recreating the backup service from compose (fresh container, same staging volume)"
dc up -d --force-recreate backup >/dev/null 2>&1
recovered=no
for i in $(seq 1 120); do
  [ "$(running_apps $PROJ)" = "2" ] && { recovered=yes; break; }
  sleep 1
done
check "a brand-new backup container also recovers the stopped app containers" "yes" "$recovered"

# ---------------------------------------------------------------------------
step "B3 — plain restart of a healthy backup container"
before=$(docker exec $PROJ-app-1 cat /data/hello.txt)
dc restart backup >/dev/null 2>&1
for i in $(seq 1 90); do [ "$(health_of $PROJ-backup-1)" = healthy ] && break; sleep 1; done
check "backup container returns to healthy" "healthy" "$(health_of $PROJ-backup-1)"
check "app data untouched by the restart" "$before" "$(docker exec $PROJ-app-1 cat /data/hello.txt)"
docker logs $PROJ-backup-1 2>&1 | tail -30 | grep -q "contains data; skipping restore" \
  && ok "restore pass correctly skipped volumes that already hold data" \
  || bad "restart did not log a 'skipping restore' decision"
check "db still running through the restart" "running" "$(state_of $PROJ-db-1)"

# ---------------------------------------------------------------------------
step "B4 — health gating: is the container ever 'healthy' before restore finished?"
info "checking that the ready file is cleared on restart (stale-health guard)"
docker exec $PROJ-backup-1 rm -f /tmp/dvb-ready
docker restart -t 2 $PROJ-backup-1 >/dev/null 2>&1
sawunhealthy=no
for i in $(seq 1 40); do
  h=$(health_of $PROJ-backup-1)
  [ "$h" = starting ] || [ "$h" = unhealthy ] && sawunhealthy=yes
  [ "$h" = healthy ] && break
  sleep 0.5
done
check "container reported not-yet-healthy while restoring" "yes" "$sawunhealthy"

step "B5 — repository still consistent after the crash series"
docker exec $PROJ-backup-1 dvb restic check >/dev/null 2>&1 \
  && ok "'restic check' passes on the repository" || bad "restic check reported problems"
got=$(dc exec -T db psql -U postgres -tAc "SELECT msg FROM t;" 2>/dev/null | tr -d '[:space:]')
check "database data survived the crash series" "b-payload" "$got"


wait_ready
if [ "${DVB_TEST_DAEMON_RESTART:-0}" != 1 ]; then
  step "B6 — docker daemon restart mid-backup (skipped)"
  info "set DVB_TEST_DAEMON_RESTART=1 to run this; it restarts the host's docker daemon"
else
step "B6 — docker daemon restart in the middle of a backup (host reboot)"
docker exec -d $PROJ-backup-1 dvb backup
hit=no
for i in $(seq 1 200); do
  [ "$(state_of $PROJ-db-1)" = exited ] && { hit=yes; break; }
  sleep 0.2
done
check "reached the vulnerable window" "yes" "$hit"
info "restarting dockerd..."
dpid=$(pgrep -x dockerd | head -1)
kill "$dpid" 2>/dev/null
for i in $(seq 1 60); do kill -0 "$dpid" 2>/dev/null || break; sleep 1; done
kill -9 "$dpid" 2>/dev/null; sleep 2
rm -f /var/run/docker.pid
( dockerd > "$LAB/dockerd2.log" 2>&1 & ) ; sleep 2
for i in $(seq 1 60); do docker info >/dev/null 2>&1 && break; sleep 1; done
info "daemon back after ~${i}s"
recovered=no
for i in $(seq 1 180); do
  [ "$(running_apps $PROJ)" = "2" ] && { recovered=yes; break; }
  sleep 1
done
check "the stack recovered by itself after a daemon restart mid-backup" "yes" "$recovered"
info "backup=$(state_of $PROJ-backup-1) health=$(health_of $PROJ-backup-1)"
n=$(docker logs $PROJ-backup-1 2>&1 | grep -c "interrupted backup")
info "'interrupted backup' recovery ran $n time(s) in this container's life"
fi

summary "GROUP B (crash recovery)"
