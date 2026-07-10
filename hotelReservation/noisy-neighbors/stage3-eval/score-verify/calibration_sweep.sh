#!/bin/bash
# calibration_sweep.sh — one-shot Gordion calibration sweep: for each
# rate level, drive the victim with wrk2 (mixed workload, NO aggressors)
# and record the InstrumentationStream, then run calibrate_from_stream.py.
#
# Run from score-verify/ with the victim deployed (fixed image, clean
# node, no aggressors) and nothing else loading the cluster:
#
#   ./calibration_sweep.sh
#   ./calibration_sweep.sh --url http://10.10.1.4:27434 --rates "300 600 1200 1800 2400 3000"
#
# Produces rate_<R>.ndjson per level + curve.csv + gordion.json, and
# prints the ConfigMap apply command. Review the calibrator's level
# table BEFORE applying (sanity: arrival_mean scales with rate; ~1000
# windows/level; sigma in the tens of kcyc).
set -euo pipefail

# ── defaults (override via flags) ────────────────────────────────────
RATES="300 600 1200 1800 2400 3000"
URL="http://10.10.1.4:27434"
DURATION=120      # recording window per level (s)
WARMUP=20         # wrk2 settle time before recording starts (s)
OPERATING_RPS=2400
THREADS=4
CONNS=256

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rates)  RATES="$2"; shift 2 ;;
        --url)    URL="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --warmup) WARMUP="$2"; shift 2 ;;
        --operating-rps) OPERATING_RPS="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ── path resolution (script may be invoked from anywhere) ────────────
SV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../stage3-eval/score-verify
HR_DIR="$(cd "$SV_DIR/../../.." && pwd)"                  # .../hotelReservation
REPO_ROOT="$(cd "$HR_DIR/.." && pwd)"                     # repo root
WRK_BIN="$REPO_ROOT/wrk2/wrk"
LUA="$HR_DIR/wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua"

for c in kubectl grpcurl jq python3; do
    command -v "$c" >/dev/null || { echo "ERROR: $c not found" >&2; exit 1; }
done
[[ -x "$WRK_BIN" ]] || { echo "ERROR: wrk2 binary not found at $WRK_BIN" >&2; exit 1; }
[[ -f "$LUA" ]]     || { echo "ERROR: lua script not found at $LUA" >&2; exit 1; }

cd "$SV_DIR"

log() { echo "[calibration-sweep $(date +%H:%M:%S)] $*"; }

# ── cleanup handling: never leave wrk2 / port-forwards behind ─────────
WRK_PID=""
cleanup() {
    [[ -n "$WRK_PID" ]] && kill "$WRK_PID" 2>/dev/null || true
    pkill -f "kubectl port-forward.*7901" 2>/dev/null || true
}
trap cleanup EXIT

# ── preflight: kill stale stream clients + stale forwards ────────────
pkill -f "InstrumentationStream/Subscribe" 2>/dev/null || true
pkill -f "kubectl port-forward.*7901" 2>/dev/null || true
sleep 1

POD=$(kubectl get pods -l io.kompose.service=search -o jsonpath='{.items[0].metadata.name}')
[[ -n "$POD" ]] || { echo "ERROR: no search pod found" >&2; exit 1; }
log "victim pod: $POD"
kubectl port-forward "$POD" 7901:7901 >/dev/null 2>&1 &
sleep 2

# ── the sweep ─────────────────────────────────────────────────────────
LEVEL_ARGS=()
for R in $RATES; do
    OUT="rate_${R}.ndjson"
    WRK_D=$(( WARMUP + DURATION + 15 ))

    log "level $R rps: starting wrk2 (${WRK_D}s total: ${WARMUP}s warmup + ${DURATION}s recording)"
    "$WRK_BIN" -D exp -t "$THREADS" -c "$CONNS" -d "$WRK_D" \
        -s "$LUA" "$URL" -R "$R" > "wrk2_rate_${R}.txt" 2>&1 &
    WRK_PID=$!

    sleep "$WARMUP"

    # Guard: wrk2 must still be alive or the capture measures idle.
    kill -0 "$WRK_PID" 2>/dev/null || { echo "ERROR: wrk2 died during warmup at $R rps (see wrk2_rate_${R}.txt)" >&2; exit 1; }

    ./record_samples.sh localhost:7901 "$OUT" "$DURATION"

    kill "$WRK_PID" 2>/dev/null || true
    wait "$WRK_PID" 2>/dev/null || true
    WRK_PID=""
    LEVEL_ARGS+=(--level "${R}:${OUT}")

    # Let in-flight requests drain so the next level starts clean.
    sleep 5
done

pkill -f "kubectl port-forward.*7901" 2>/dev/null || true

# ── calibrate (does NOT apply the ConfigMap -- review first) ─────────
log "running calibrate_from_stream.py"
python3 calibrate_from_stream.py "${LEVEL_ARGS[@]}" \
    --operating-rps "$OPERATING_RPS" \
    --out-curve curve.csv --out-config gordion.json

cat <<'EOF'

Review the level table above (arrival_mean must scale with rate; sigma
in the tens of kcyc). If sane, apply:

  kubectl create configmap gordion-search --from-file=gordion.json --from-file=curve.csv \
      --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deployment/search
EOF
