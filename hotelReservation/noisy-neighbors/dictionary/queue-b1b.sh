#!/bin/bash
# Phase B queue 1b (image gordion2 = recorder with per-window core MHz): explore the upper range
# to locate the frontend's knee, then the B1 idle-cost runs. Waits for queue-b1 and the image.
cd "$(dirname "$0")"
export SUT=frontend NODE=node-4 CPUSET=2-5 WLGEN_NODE=node-4 WLGEN_CPUS=1,6,7 TAG=gordion2
log() { echo "=== $(date +%H:%M:%S) $*"; }
while ! grep -q DONE-B1 /local/results/hr/queue-b1.log; do sleep 10; done
while ! curl -s http://10.10.1.1:5000/v2/hr-gordion/tags/list | grep -q gordion2; do sleep 10; done
log "explore2: default mix, 3000..7000 req/s, 20 s steps (gordion2)"
./hr.sh run b-explore2 -- -mix default -warmup 10 -k 4 -schedule "3000:20,4000:20,5000:20,6000:20,7000:20"
for e in search recommend reserve user; do
  log "B1 idle $e (gordion2)"
  ./hr.sh run b1-idle-$e -- -mix single:$e -rate 20 -duration 45 -warmup 5 -k 4
done
log "DONE-B1B"
