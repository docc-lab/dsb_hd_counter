#!/bin/bash
# Phase B queue 4 (reservation SUT): B4 mix ramp without aggressor, the stressed default-mix sweep
# (ground truth), B5 ramp with the stage-3 style aggressor (search+geo+rate colocated and pinned on
# the SUT's cores). KNEE from /local/results/hr/KNEE-r unless given.
# Run on node-0:  nohup ./queue-b4.sh > /local/results/hr/queue-b4.log 2>&1 < /dev/null &
cd "$(dirname "$0")"
export SUT=${SUT:-reservation} NODE=node-4 CPUSET=${CPUSET:-2-3} WLGEN_NODE=node-4 WLGEN_CPUS=${WLGEN_CPUS:-1,4,5,6,7} TAG=${TAG:-gordion2}
K=${K:-2}; STEP=${STEP:-45}
KNEE=${KNEE:-$(cat /local/results/hr/KNEE-r)}
HEAVY=${HEAVY:-weights:search=0.2,recommend=0.2,reserve=0.5,user=0.1}
RAMP_RATE=$(python3 -c "print(int($KNEE*0.6))")
log() { echo "=== $(date +%H:%M:%S) $*"; }
sched() { python3 -c "k=$KNEE; print(','.join(f'{int(k*f)}:$STEP' for f in [0.05,0.15,0.25,0.35,0.45,0.55,0.65,0.72,0.8,0.86,0.92,0.98,1.05]))"; }

log "B4 ramp, no aggressor: $RAMP_RATE req/s (0.6 x knee $KNEE), default -> $HEAVY over 300 s (70 s before, 50 s after)"
STRESSOR=none ./hr.sh run r4-ramp -- -mix default -ramp-to "$HEAVY" -ramp-start 70 -ramp-seconds 300 -rate $RAMP_RATE -duration 420 -warmup 10 -k $K

log "B5 ground truth: stressed default-mix sweep, aggressors search geo rate on the SUT cores"
STRESSOR=aggressor AGGR="search geo rate" ./hr.sh run r5-stress-sweep -- -mix default -warmup 10 -k $K -schedule "$(sched)"

log "B5 ramp with aggressor"
STRESSOR=aggressor AGGR="search geo rate" ./hr.sh run r5-ramp-stress -- -mix default -ramp-to "$HEAVY" -ramp-start 70 -ramp-seconds 300 -rate $RAMP_RATE -duration 420 -warmup 10 -k $K
log "DONE-B4"
