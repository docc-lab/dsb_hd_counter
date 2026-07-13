#!/bin/bash
# ===========================================================================
# rps_sweep_calibrate.sh -- multi-level rate sweep to derive the REAL
# baseline curve + operating-point stats for the fixed (v2.2.5+) binary.
#
# Why: the pre-fix curve/baseline carried the per-request perf syscall
# tax (~2/3 of measured handler time: 105 -> 38 kcyc) and the old
# single-level calibration only covers a fixed 2400-rps victim. This
# sweep records one clean :7901 capture per rate level and prints the
# calibrate_from_stream.py invocation that turns them into
# curve.csv + gordion.json.
#
# Prereqs: victim pinned to the (floored, dedicated) target node on the
# FIXED image; no other load on the cluster; run from stage3-eval/.
#
# Usage:  tools/rps_sweep_calibrate.sh
#         SWEEP_URL=http://10.10.1.5:27434 LEVELS="300 1200 2400" tools/rps_sweep_calibrate.sh
# Output: /tmp/cal_lv_<rps>.ndjson per level + a summary + the calibrate cmd.
# ===========================================================================
set -u
cd "$(dirname "$0")/.."

WRK=/local/dsb_hd_counter/wrk2/wrk
LUA=../../wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua
URL="${SWEEP_URL:-http://10.10.1.5:27434}"
LEVELS="${LEVELS:-300 600 900 1200 1800 2400 3000}"
DUR="${LEVEL_DURATION_S:-200}"     # wrk2 run per level; probe covers DUR-20s
LOG=/tmp/rps_sweep.log

echo "rate sweep: levels [$LEVELS], ${DUR}s each, url $URL" | tee "$LOG"
POD=$(kubectl get pods -l io.kompose.service=search \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}')
kubectl get pod "$POD" -o wide | tee -a "$LOG"   # eyeball: correct node!

ARGS=""
for R in $LEVELS; do
    echo "--- level $R rps ---" | tee -a "$LOG"
    "$WRK" -D exp -t 4 -c 256 -d "$DUR" -L -R "$R" -s "$LUA" "$URL" >/dev/null 2>&1 &
    W=$!
    sleep 12
    kubectl port-forward "$POD" 7901:7901 >/dev/null 2>&1 &
    PF=$!
    sleep 3
    timeout $((DUR - 20)) grpcurl -plaintext -d '{}' localhost:7901 \
        gordion.instrumentation.InstrumentationStream/Subscribe 2>/dev/null \
        | jq -c . > "/tmp/cal_lv_$R.ndjson"
    kill "$PF" 2>/dev/null
    wait "$W" 2>/dev/null
    python3 - "$R" <<'EOF' | tee -a /tmp/rps_sweep.log
import json, sys
r = sys.argv[1]
vals = []
for line in open(f'/tmp/cal_lv_{r}.ndjson'):
    try: s = json.loads(line)
    except Exception: continue
    sec = (s.get('timingWindow') or {}).get('processingTime') or {}
    if int(sec.get('p50Ns') or 0) > 0:
        vals.append((int(sec.get('p50Ns'))/1000, int(sec.get('maxNs') or 0)/1e6))
p = sorted(v for v, _ in vals)
frz = sum(1 for _, m in vals if m > 10)
med = p[len(p)//2] if p else -1
print(f"  level {r}: {len(vals)} windows | p50 median {med:.0f}us | freezes>10ms: {frz}"
      + ("   <-- DIRTY, re-run this level" if frz > 0 else ""))
EOF
done

echo ""
echo "=== all levels captured. Calibrate with: ==="
CMD="python3 score-verify/calibrate_from_stream.py"
for R in $LEVELS; do CMD="$CMD --level $R:/tmp/cal_lv_$R.ndjson"; done
CMD="$CMD --operating-rps 2400 --out-curve score-verify/curve.csv --out-config score-verify/gordion.json"
echo "$CMD" | tee -a "$LOG"
echo "then: kubectl create configmap gordion-search --from-file=score-verify/gordion.json --from-file=score-verify/curve.csv --dry-run=client -o yaml | kubectl apply -f -"
