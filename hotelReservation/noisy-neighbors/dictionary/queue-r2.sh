#!/bin/bash
# Phase B queue r2 (reservation SUT, image gordion3 = negative caller-stamp offsets kept):
# exploratory sweep (if no knee yet), knee, B2 default-mix sweep, B3 reserve-heavy sweep.
cd "$(dirname "$0")"
export SUT=reservation NODE=node-4 CPUSET=${CPUSET:-2-3} WLGEN_NODE=node-4 WLGEN_CPUS=${WLGEN_CPUS:-1,4,5,6,7} TAG=${TAG:-gordion3}
K=${K:-2}; STEP=${STEP:-45}
HEAVY=${HEAVY:-weights:search=0.2,recommend=0.2,reserve=0.5,user=0.1}
log() { echo "=== $(date +%H:%M:%S) $*"; }
while ! curl -s http://10.10.1.1:5000/v2/hr-gordion/tags/list | grep -q "\"$TAG\""; do sleep 10; done
if [ ! -s /local/results/hr/KNEE-r ]; then
  log "explore: default mix, 500..6000 req/s, 20 s steps"
  ./hr.sh run r-explore -- -mix default -warmup 10 -k $K -schedule "500:20,1000:20,1500:20,2000:20,2500:20,3000:20,3500:20,4000:20,4500:20,5000:20,6000:20"
  python3 knee.py /local/results/hr/*-r-explore/wlgen.jsonl > /local/results/hr/KNEE-r 2> /local/results/hr/knee-r.txt
  cat /local/results/hr/knee-r.txt
fi
KNEE=${KNEE:-$(cat /local/results/hr/KNEE-r)}; echo "KNEE=$KNEE"
sched() { python3 -c "k=$KNEE; print(','.join(f'{int(k*f)}:$STEP' for f in [0.05,0.15,0.25,0.35,0.45,0.55,0.65,0.72,0.8,0.86,0.92,0.98,1.05]))"; }
for e in search reserve; do
  log "B1 idle $e at 200 req/s (reservation SUT, $TAG)"
  ./hr.sh run r1-idle-$e -- -mix single:$e -rate 200 -duration 45 -warmup 5 -k $K
done
log "B2 default-mix sweep (reservation): $(sched)"
./hr.sh run r2-default -- -mix default -warmup 10 -k $K -schedule "$(sched)"
log "B3 reserve-heavy sweep ($HEAVY): $(sched)"
./hr.sh run r3-heavy -- -mix "$HEAVY" -warmup 10 -k $K -schedule "$(sched)"
log "DONE-R2"
