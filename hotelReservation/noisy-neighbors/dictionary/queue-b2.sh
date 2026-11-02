#!/bin/bash
# Phase B queue 2 (frontend SUT on k = 2 cores, since on 4 cores the frontend did not saturate at
# 7000 req/s): exploratory sweep at k = 2 -> knee -> B0 overhead pair -> B2 default-mix sweep ->
# B3 contrasting-mix sweep. Waits for queue 1c (idle costs). Automatic; log = queue-b2.log.
cd "$(dirname "$0")"
export SUT=frontend NODE=node-4 CPUSET=${CPUSET:-2-3} WLGEN_NODE=node-4 WLGEN_CPUS=${WLGEN_CPUS:-1,4,5,6,7} TAG=${TAG:-gordion2}
K=${K:-2}
STEP=${STEP:-45}
COSTS=${COSTS:-/local/results/hr/costs-frontend.json}
CO=""; [ -f "$COSTS" ] && CO="-costs $COSTS"
HEAVY=${HEAVY:-weights:search=0.2,recommend=0.2,reserve=0.5,user=0.1}
log() { echo "=== $(date +%H:%M:%S) $*"; }
while ! grep -q DONE-B1C /local/results/hr/queue-b1c.log; do sleep 10; done

log "explore3: default mix on k=$K cores, 500..6000 req/s, 20 s steps"
./hr.sh run b-explore3 -- -mix default -warmup 10 -k $K -schedule "500:20,1000:20,1500:20,2000:20,2500:20,3000:20,3500:20,4000:20,4500:20,5000:20,6000:20"
KNEE=${KNEE:-$(python3 knee.py /local/results/hr/*-b-explore3/wlgen.jsonl 2> /local/results/hr/knee3.txt)}
cat /local/results/hr/knee3.txt; echo "KNEE=$KNEE"; echo $KNEE > /local/results/hr/KNEE
sched() { python3 -c "k=$KNEE; print(','.join(f'{int(k*f)}:$STEP' for f in [0.05,0.15,0.25,0.35,0.45,0.55,0.65,0.72,0.8,0.86,0.92,0.98,1.05]))"; }
B0RATE=$(python3 -c "print(int($KNEE*0.5))")

log "B0 overhead: recorder off vs on at $B0RATE req/s, default mix, 60 s"
DISABLE=1 ./hr.sh run b0-off -- -mix default -rate $B0RATE -duration 60 -warmup 10 -k $K $CO
DISABLE=0 ./hr.sh run b0-on  -- -mix default -rate $B0RATE -duration 60 -warmup 10 -k $K $CO

log "B2 default-mix sweep: $(sched)"
./hr.sh run b2-default -- -mix default -warmup 10 -k $K $CO -schedule "$(sched)"

log "B3 contrasting-mix sweep ($HEAVY): $(sched)"
./hr.sh run b3-heavy -- -mix "$HEAVY" -warmup 10 -k $K $CO -schedule "$(sched)"
log "DONE-B2"
