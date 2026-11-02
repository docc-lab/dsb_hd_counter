#!/bin/bash
# Phase C SocialNetwork queue (PHASEC-HANDOFF.md section 2 A3 and section 3 B-SN), node-0.
#   1. Q1: three single-endpoint runs (compose / home / utl at 200 req/s) with every instrumented service
#      recording -> c_e per endpoint per service (home-timeline, user-timeline, post-storage); the SUT is
#      the service whose two endpoints differ most in c_e (picked by analysis, SUT env for the rest)
#   2. explore sweeps per mix -> knee -> 10-step sweeps (45 s) for the compose-heavy and read-heavy mixes
#   3. B-SN ramp: read-heavy -> compose-heavy at the read-heavy rho/k 0.5 rate (30 s hold, 60 s ramp, 30 s hold)
# Env: SUT (default home-timeline-service), K=2 (CPUSET=2-3), TAG=g1; STAGE=q1|sweeps|ramp runs one part.
set -u
cd "$(dirname "$0")"
export SUT=${SUT:-home-timeline-service} NODE=node-4 CPUSET=${CPUSET:-2-3} WLGEN_NODE=node-4 WLGEN_CPUS=${WLGEN_CPUS:-8-15} TAG=${TAG:-g1}
K=${K:-2}; STEP=${STEP:-45}; STAGE=${STAGE:-all}; SUF=${SUFFIX:-}  # SUFFIX=-k1 for the one-core pass
R=/local/results/sn
COMPOSE_HEAVY="weights:compose=0.6,home=0.3,utl=0.1"
READ_HEAVY="weights:compose=0.05,home=0.8,utl=0.15"
log() { echo "=== $(date +%H:%M:%S) $*"; }
SN=${SNSH:-/local/sn/sn.clean.sh}
# clock pin (HWP min 0x1f = 3.1 GHz on the service and generator cores; see queue-c1.sh)
ssh -o BatchMode=yes node-4 "sudo modprobe msr; for c in 2 3 4 5 8 9 10 11 12 13 14 15; do sudo wrmsr -p \$c 0x774 0x001f1f1f; done; echo node-4 ratio=\$(( (0x\$(sudo rdmsr -p 2 0x198) >> 8) & 0xff ))"

if [ "$STAGE" = all ] || [ "$STAGE" = q1 ]; then
  for e in compose home utl; do
    log "Q1 single:$e 200 req/s (SUT $SUT pinned, all instrumented services recording)"
    $SN run q1-$e$SUF -- -mix single:$e -rate 200 -duration 45 -warmup 5 -k $K 2>&1 | tail -1
  done
fi

sched() { python3 -c "k=$1; print(','.join(f'{int(k*f)}:$STEP' for f in [0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0]))"; }
if [ "$STAGE" = all ] || [ "$STAGE" = sweeps ]; then
  for mix in compose-heavy read-heavy; do
    w=$COMPOSE_HEAVY; [ $mix = read-heavy ] && w=$READ_HEAVY
    if [ ! -s $R/KNEE-$mix ]; then
      log "explore $mix"
      $SN run x-$mix$SUF -- -mix "$w" -warmup 5 -k $K -schedule "100:15,200:15,400:15,600:15,800:15,1000:15,1300:15,1600:15,2000:15,2500:15,3000:15,4000:15,5000:15,6000:15,8000:15" 2>&1 | tail -1
      python3 /local/hr/hotelReservation/noisy-neighbors/dictionary/knee.py $R/*-x-$mix/wlgen.jsonl > $R/KNEE-$mix 2> $R/knee-$mix.txt; cat $R/knee-$mix.txt
    fi
    knee=$(cat $R/KNEE-$mix); log "A3 sweep $mix knee=$knee: $(sched $knee)"
    $SN run a3-$mix$SUF -- -mix "$w" -warmup 10 -k $K -schedule "$(sched $knee)" 2>&1 | tail -1
  done
fi

if [ "$STAGE" = all ] || [ "$STAGE" = ramp ]; then
  # handoff direction: read-heavy -> compose-heavy at the read-heavy rho/k 0.5 rate (RAMP_RATE; default = half the
  # read-heavy explore knee of the whole app). On post-storage read-heavy is the COSTLIER mix (ReadPosts 0.72 ms vs
  # StorePost 0.15 ms), so the direction that makes D(lambda) fail is the reverse one (RAMP_RATE_REV = the
  # compose-heavy rho/k 0.5 rate); both are run. 60 s hold before the ramp (fresh pod warm-up, see c-ramp2).
  knee=$(cat $R/KNEE-read-heavy); rate=${RAMP_RATE:-$(python3 -c "print(int($knee*0.5))")}
  log "B-SN ramp read-heavy -> compose-heavy at $rate req/s"
  $SN run b-sn-ramp$SUF -- -mix "$READ_HEAVY" -ramp-to "$COMPOSE_HEAVY" -ramp-start 60 -ramp-seconds 60 -rate $rate -duration 150 -warmup 10 -k $K 2>&1 | tail -1
  rate2=${RAMP_RATE_REV:-$rate}
  log "B-SN ramp (reverse) compose-heavy -> read-heavy at $rate2 req/s"
  $SN run b-sn-ramp-rev$SUF -- -mix "$COMPOSE_HEAVY" -ramp-to "$READ_HEAVY" -ramp-start 60 -ramp-seconds 60 -rate $rate2 -duration 150 -warmup 10 -k $K 2>&1 | tail -1
fi
log "DONE-SN"
