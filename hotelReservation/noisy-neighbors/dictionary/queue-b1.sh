#!/bin/bash
# Phase B, first queue: node hygiene (F8), exploratory sweep to locate the frontend's knee, B1 idle runs.
# Run on node-0:  nohup ./queue-b1.sh > /local/results/hr/queue-b1.log 2>&1 < /dev/null &
cd "$(dirname "$0")"
export SUT=frontend NODE=node-4 CPUSET=2-5 WLGEN_NODE=node-4 WLGEN_CPUS=1,6,7
log() { echo "=== $(date +%H:%M:%S) $*"; }

# F8: no SCHED_IDLE busy loops; operational governor (schedutil, as on the other workers)
ssh -o BatchMode=yes node-4 'sudo pkill -f "while :; do :; done" ; sleep 1; pgrep -c -f "while :; do :; done" || true;
  for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do echo schedutil | sudo tee $c/scaling_governor >/dev/null; done;
  cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_governor; cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq'

log "explore: default mix, 200..3500 req/s, 20 s steps"
./hr.sh run b-explore -- -mix default -warmup 10 -k 4 -schedule "200:20,500:20,1000:20,1500:20,2000:20,2500:20,3000:20,3500:20"

for e in search recommend reserve user; do
  log "B1 idle $e"
  ./hr.sh run b1-idle-$e -- -mix single:$e -rate 20 -duration 45 -warmup 5 -k 4
done
log "DONE-B1"
