#!/bin/bash
# ===========================================================================
# capture_sweep.sh -- long-running stage-3 sweep with :7901 sample capture
# attached to every run, so score_replay.py can evaluate ANY score model
# (Gordion k/sigma variants + the comparison-table competitors) over every
# run afterwards, offline.
#
# Cycles through ARMS repeatedly until SWEEP_HOURS expires. Each run's raw
# sample stream is saved INSIDE its experiment dir:
#     data/<exp>/runs/run_1/samples.ndjson
# next to score_events.log, keeping capture and run provenance together.
#
# One full pass (baseline + 5 aggressor arms) ~ 33 min -> ~12 replicates
# per arm in 7h.
#
# Usage:
#   SWEEP_HOURS=7 nohup tools/capture_sweep.sh > /tmp/capture_sweep.out 2>&1 &
#   tail -f /tmp/capture_sweep.log
# Override arms:  ARMS="baseline-search-2400 mildB-mixed-2400" ...
#
# Afterwards, replay everything (see log tail for the loop, or):
#   for f in data/*/runs/run_1/samples.ndjson; do
#     python3 score-verify/score_replay.py --samples $f \
#       --variant k1=1.0 --variant kg=0.025 --competitors \
#       --out-prefix ${f%/samples.ndjson}/replay
#   done
# ===========================================================================
set -u
cd "$(dirname "$0")/.."

LOG=/tmp/capture_sweep.log
DEADLINE=$(( $(date +%s) + ${SWEEP_HOURS:-7} * 3600 ))
ARMS="${ARMS:-baseline-search-2400 mildA-mixed-2400 mildB-mixed-2400 mildC-mixed-2400 moderate-mixed-2400 severe-mixed-2400}"

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

log "=== capture sweep start: budget ${SWEEP_HOURS:-7}h, arms: $ARMS ==="
PASS=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    PASS=$((PASS + 1))
    for ARM in $ARMS; do
        [ "$(date +%s)" -ge "$DEADLINE" ] && break
        if [ ! -f "configs/$ARM.yaml" ]; then
            log "pass $PASS: SKIP $ARM (configs/$ARM.yaml missing)"
            continue
        fi
        RUNLOG="/tmp/cs_run.log"
        ./stage3-eval.sh "configs/$ARM.yaml" > "$RUNLOG" 2>&1 &
        H=$!
        until grep -q "Drivers active" "$RUNLOG" 2>/dev/null; do
            sleep 3
            kill -0 "$H" 2>/dev/null || break
        done
        POD=$(kubectl get pods -l io.kompose.service=search \
              --field-selector=status.phase=Running \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        kubectl port-forward "$POD" 7901:7901 >/dev/null 2>&1 &
        PF=$!
        sleep 3
        timeout 105 grpcurl -plaintext -d '{}' localhost:7901 \
            gordion.instrumentation.InstrumentationStream/Subscribe 2>/dev/null \
            | jq -c . > /tmp/cs_samples.ndjson
        kill "$PF" 2>/dev/null
        wait "$H" 2>/dev/null
        D=$(ls -td data/*/ | head -1)
        N=$(wc -l < /tmp/cs_samples.ndjson)
        if [ "$N" -gt 200 ]; then
            mv /tmp/cs_samples.ndjson "${D}runs/run_1/samples.ndjson"
            log "pass $PASS: $ARM -> $D (samples: $N)"
        else
            log "pass $PASS: $ARM -> $D CAPTURE THIN ($N lines) -- run kept, no samples file"
        fi
    done
done
TOTAL=$(ls data/*/runs/run_1/samples.ndjson 2>/dev/null | wc -l)
log "=== sweep done: $PASS passes, $TOTAL runs with sample captures ==="
