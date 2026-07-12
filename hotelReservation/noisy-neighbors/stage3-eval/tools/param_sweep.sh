#!/bin/bash
# ===========================================================================
# param_sweep.sh -- loadgen parameter sweep for the spike question.
#
# Rotates five load arms against the pinned victim, ~2 min per arm, for
# SWEEP_HOURS (default 6). Each cycle: 90s wrk2 with that arm's lua +
# 75s in-pod probe, logging processing- and blocking-time spike counts.
#
# Arms:
#   mixed       -- the original randomized mixed workload (control)
#   fixed_cheap -- one constant cheap request (2-day span, center coords)
#   fixed_heavy -- one constant heavy request (15-day span, corner coords)
#   rand_dates  -- random dates only
#   rand_latlon -- random coords only
#
# Interpretation after many cycles per arm:
#   - all arms converge to the same spike rate  -> parameters irrelevant;
#     spikes track TIME (environment episodes), not inputs.
#   - fixed_heavy >> fixed_cheap consistently    -> parameter-dependent load
#     is real; bisect further on dates vs coords via the rand_* arms.
#   - blocking-spikes ~ 0 while proc-spikes > 0  -> downstream/DB exonerated.
#
# Usage:  SWEEP_HOURS=8 nohup tools/param_sweep.sh > /tmp/sweep.out 2>&1 &
#         (from the stage3-eval dir; victim must already be pinned)
# Log:    /tmp/param_sweep.log ; summary printed at the end and on demand:
#         python3 tools/sweep_summary.py
# ===========================================================================
set -u
cd "$(dirname "$0")/.."
TOOLS="$(cd "$(dirname "$0")" && pwd)"
LOG=/tmp/param_sweep.log
WRK=/local/dsb_hd_counter/wrk2/wrk
URL="${SWEEP_URL:-http://10.10.1.5:27434}"
DEADLINE=$(( $(date +%s) + ${SWEEP_HOURS:-6} * 3600 ))

declare -A ARMS=(
    [mixed]="../../wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua"
    [fixed_cheap]="$TOOLS/luas/fixed_cheap.lua"
    [fixed_heavy]="$TOOLS/luas/fixed_heavy.lua"
    [rand_dates]="$TOOLS/luas/rand_dates.lua"
    [rand_latlon]="$TOOLS/luas/rand_latlon.lua"
)
ORDER=(mixed fixed_cheap fixed_heavy rand_dates rand_latlon)

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

log "=== param sweep start (budget ${SWEEP_HOURS:-6}h, url $URL) ==="
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    for arm in "${ORDER[@]}"; do
        [ "$(date +%s)" -ge "$DEADLINE" ] && break
        "$WRK" -D exp -t 4 -c 256 -d 90 -L -R 2400 -s "${ARMS[$arm]}" "$URL" >/dev/null 2>&1 &
        W=$!
        sleep 8
        POD=$(kubectl get pods -l io.kompose.service=search \
              --field-selector=status.phase=Running \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        kubectl port-forward "$POD" 7901:7901 >/dev/null 2>&1 &
        PF=$!
        sleep 2
        timeout 75 grpcurl -plaintext -d '{}' localhost:7901 \
            gordion.instrumentation.InstrumentationStream/Subscribe 2>/dev/null \
            | jq -c . > /tmp/sweep_probe.ndjson
        kill "$PF" 2>/dev/null
        wait "$W" 2>/dev/null
        read PN BN T <<< "$(python3 "$TOOLS/ap_count2.py")"
        log "arm=$arm proc_spikes=$PN blocking_spikes=$BN windows=$T"
    done
done
log "=== sweep done ==="
python3 "$TOOLS/sweep_summary.py" >> "$LOG"
