#!/usr/bin/env bash
# Failure-injection suite for docker-volume-backup.
#
# Where test/run-test.sh proves the happy path, this suite breaks things on
# purpose: S3 outages, crashes, misconfiguration, depends_on mistakes, and a
# few edge cases that only show up under load. Run from the repository root:
#
#   ./test/failure/run-all.sh            # everything
#   ./test/failure/run-all.sh a c g      # only the named groups
#
# Requirements: a docker daemon this script may drive directly (it SIGKILLs
# container init processes from the host to simulate crashes), and enough
# room for a few GB of scratch volumes. Expect roughly 30-45 minutes: several
# scenarios deliberately wait out multi-minute S3 retry budgets.
#
# Environment:
#   DVB_IMAGE                image under test (default: dvb:test, built here)
#   DVB_TEST_DAEMON_RESTART  set to 1 to include B6, which restarts dockerd
set -uo pipefail
cd "$(dirname "$0")"

IMAGE=${DVB_IMAGE:-dvb:test}
export DVB_IMAGE=$IMAGE

groups=("$@")
[ ${#groups[@]} -eq 0 ] && groups=(a b c d e f g followup)

if [ "$IMAGE" = "dvb:test" ]; then
  printf '\033[1m== building %s ==\033[0m\n' "$IMAGE"
  docker build -t "$IMAGE" ../.. >/dev/null || { echo "build failed"; exit 1; }
fi

rc=0
for g in "${groups[@]}"; do
  script=$([ "$g" = followup ] && echo ./followup.sh || echo "./group-$g.sh")
  [ -x "$script" ] || { echo "no such group: $g"; rc=1; continue; }
  printf '\n\033[1;45m################  %s  ################\033[0m\n' "${script#./}"
  "$script" 2>&1 | tee "result-${g}.log"
done

printf '\n\033[1m================ TOTALS ================\033[0m\n'
grep -h -- '----' result-*.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
printf '\n\033[1mNotes raised:\033[0m\n'
grep -h 'NOTE' result-*.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
exit $rc
