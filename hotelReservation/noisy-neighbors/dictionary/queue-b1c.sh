#!/bin/bash
# Phase B queue 1c: B1 idle-cost runs at 200 req/s (~5% utilisation, so the process's idle CPU
# baseline is small against the request cost), then the knee from the exploratory sweeps.
cd "$(dirname "$0")"
export SUT=frontend NODE=node-4 CPUSET=2-5 WLGEN_NODE=node-4 WLGEN_CPUS=1,6,7 TAG=${TAG:-gordion2}
log() { echo "=== $(date +%H:%M:%S) $*"; }
while ! grep -q DONE-B1B /local/results/hr/queue-b1b.log; do sleep 10; done
for e in search recommend reserve user; do
  log "B1 idle $e at 200 req/s"
  ./hr.sh run b1c-idle-$e -- -mix single:$e -rate 200 -duration 45 -warmup 5 -k 4
done
log "knee from the exploratory sweeps"
python3 knee.py /local/results/hr/*-b-explore/wlgen.jsonl /local/results/hr/*-b-explore2/wlgen.jsonl > /local/results/hr/KNEE 2> /local/results/hr/knee.txt
cat /local/results/hr/knee.txt; echo "KNEE=$(cat /local/results/hr/KNEE)"
log "DONE-B1C"
