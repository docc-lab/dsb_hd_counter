#!/bin/bash
# ===========================================================================
# autopilot.sh -- unattended pursuit of the two open stage-3 goals:
#
#   1. Two CLEAN harness baseline runs (metronome-quiet on node-3),
#      collected opportunistically whenever two consecutive probe cycles
#      read zero spikes. Clean dirs accumulate in
#      /tmp/ap_clean_baselines.txt for the 5-phase stitch.
#   2. One capture suite fired INSIDE a live metronome episode (>=5
#      spikes in a probe cycle): bare-core jitter (node-3 cores 19+5),
#      in-pod jitter, system-wide perf, sched_switch trace -- all
#      concurrent with an in-pod probe, saved to /tmp/tripwire_<HHMMSS>/.
#
# Runs until both goals are met or the 6h budget expires. Logs every
# cycle's spike count to /tmp/autopilot.log (doubles as node-3's
# activity timeline).
#
# Prereqs: /tmp/jitter2.bin on node-0 (CLOCK_REALTIME jitter probe,
# compiled on node-3); passwordless ssh+sudo to node-3; wrk2 built.
#
# Usage:  nohup tools/autopilot.sh > /tmp/autopilot.out 2>&1 &
#         (invoke from the stage3-eval directory)
# ===========================================================================
set -u
cd "$(dirname "$0")/.."   # stage3-eval dir, wherever we were invoked from

TOOLS="$(cd "$(dirname "$0")" && pwd)"
LOG=/tmp/autopilot.log
WRK=/local/dsb_hd_counter/wrk2/wrk
LUA=../../wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua
URL=http://10.10.1.4:27434
NGOOD=0
CAPTURED=0
DEADLINE=$(( $(date +%s) + 21600 ))
PIN='{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"node-3"},"tolerations":[{"key":"dedicated","operator":"Equal","value":"special","effect":"NoSchedule"}]}}}}'

log() { echo "$(date +%H:%M:%S) $*" >> "$LOG"; }

repin() {
    kubectl patch deployment search --type=merge -p "$PIN" >/dev/null 2>&1
    kubectl rollout status deployment/search --timeout=120s >/dev/null 2>&1
}

search_pod() {
    kubectl get pods -l io.kompose.service=search \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# 90s wrk2 + 75s probe; echoes spike count (or -1 on short capture).
probe_cycle() {
    "$WRK" -D exp -t 4 -c 256 -d 90 -L -R 2400 -s "$LUA" "$URL" >/dev/null 2>&1 &
    local W=$!
    sleep 8
    local POD; POD=$(search_pod)
    kubectl port-forward "$POD" 7901:7901 >/dev/null 2>&1 &
    local PF=$!
    sleep 2
    timeout 75 grpcurl -plaintext -d '{}' localhost:7901 \
        gordion.instrumentation.InstrumentationStream/Subscribe 2>/dev/null \
        | jq -c . > /tmp/ap_probe.ndjson
    kill "$PF" 2>/dev/null
    wait "$W" 2>/dev/null
    python3 "$TOOLS/ap_count.py"
}

capture_suite() {
    local TS; TS=$(date +%H%M%S)
    mkdir -p "/tmp/tripwire_$TS"
    local POD; POD=$(search_pod)
    kubectl cp /tmp/jitter2.bin "default/$POD:/tmp/jitter2" 2>/dev/null
    kubectl exec "$POD" -- chmod +x /tmp/jitter2 2>/dev/null

    "$WRK" -D exp -t 4 -c 256 -d 110 -L -R 2400 -s "$LUA" "$URL" >/dev/null 2>&1 &
    local W=$!
    sleep 5
    kubectl port-forward "$POD" 7901:7901 >/dev/null 2>&1 &
    local PF=$!
    sleep 2
    timeout 95 grpcurl -plaintext -d '{}' localhost:7901 \
        gordion.instrumentation.InstrumentationStream/Subscribe 2>/dev/null \
        | jq -c . > "/tmp/tripwire_$TS/probe.ndjson" &
    local GP=$!
    ssh node-3 "(timeout 95 taskset -c 19 /tmp/jitter2 > /tmp/tw_jit19.txt & \
                 timeout 95 taskset -c 5  /tmp/jitter2 > /tmp/tw_jit5.txt & wait)" &
    local SJ=$!
    kubectl exec "$POD" -- sh -c 'timeout 95 /tmp/jitter2 > /tmp/tw_jitpod.txt; true' &
    local PJ=$!
    ssh node-3 'sudo perf record -a -g -o /tmp/tw_perf.data -- sleep 45' >/dev/null 2>&1
    ssh node-3 'sudo perf record -e sched:sched_switch -a -o /tmp/tw_sw.data -- sleep 25' >/dev/null 2>&1
    wait "$GP" "$SJ" "$PJ" "$W" 2>/dev/null
    kill "$PF" 2>/dev/null

    scp node-3:/tmp/tw_jit19.txt node-3:/tmp/tw_jit5.txt "/tmp/tripwire_$TS/" >/dev/null 2>&1
    kubectl exec "$POD" -- cat /tmp/tw_jitpod.txt > "/tmp/tripwire_$TS/jitpod.txt" 2>/dev/null
    ssh node-3 'sudo perf script -i /tmp/tw_sw.data 2>/dev/null' | gzip > "/tmp/tripwire_$TS/sw.txt.gz"
    log "capture saved: /tmp/tripwire_$TS (perf profile stays on node-3:/tmp/tw_perf.data)"
}

log "=== autopilot start (budget 6h) ==="
repin
QUIET=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    [ "$NGOOD" -ge 2 ] && [ "$CAPTURED" -ge 1 ] && break
    SP=$(probe_cycle)
    log "cycle spikes=$SP quiet=$QUIET good=$NGOOD captured=$CAPTURED"
    if [ "$SP" = "-1" ]; then sleep 30; continue; fi

    if [ "$SP" -ge 5 ] && [ "$CAPTURED" -eq 0 ]; then
        log "ACTIVE EPISODE -- firing capture suite"
        capture_suite
        CAPTURED=1
        QUIET=0
        continue
    fi

    if [ "$SP" -eq 0 ]; then QUIET=$((QUIET+1)); else QUIET=0; fi
    if [ "$QUIET" -ge 2 ] && [ "$NGOOD" -lt 2 ]; then
        log "quiet x2 -- harness baseline attempt"
        ./stage3-eval.sh configs/baseline-search-2400.yaml >> "$LOG" 2>&1
        D=$(ls -td data/*/ | head -1)
        BAD=$(python3 "$TOOLS/ap_ybad.py" "$D")
        log "baseline $D pinned=$BAD"
        if [ "$BAD" -lt 20 ]; then
            NGOOD=$((NGOOD+1))
            echo "$D" >> /tmp/ap_clean_baselines.txt
        fi
        QUIET=0
        repin   # harness cleanup unpins search
    fi
done
log "=== DONE good=$NGOOD captured=$CAPTURED clean_dirs: $(tr '\n' ' ' < /tmp/ap_clean_baselines.txt 2>/dev/null) ==="
