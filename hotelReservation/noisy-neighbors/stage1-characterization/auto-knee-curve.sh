#!/bin/bash
# ===========================================================================
# auto-knee-curve.sh — automated two-pass latency-vs-arrival-rate curve
#
#   Pass 1 (COARSE):  sweep wide with a fixed coarse step to LOCATE the knee.
#   Detect:           knee K = last non-saturated, delivery-verified level of
#                     pass 1's curve.csv (svc_p99-based `saturated` column,
#                     i.e. the interceptor signal, not ghz e2e).
#   Align:            write a progressive-fineness SATURATION_SEGMENTS
#                     (coarse -> finer -> finest-through-knee -> coarse tail)
#                     centered on K INTO THE CONF FILE (knee_segments.py).
#   Pass 2 (PROFILE): re-run the curve with the aligned segments.
#
# If pass 1 never saturates (knee above the ceiling), the conf is updated with
# a suggested 2x-taller coarse schedule and the script exits so you can re-run.
#
# Usage (from noisy-neighbors/):
#   ./stage1-characterization/auto-knee-curve.sh configs/curve-search.conf
#
# Env knobs:
#   COARSE_SEGMENTS   pass-1 schedule           (default '100-4500:250')
#   KNEE_STEP         finest step through knee  (default 20)
#   SKIP_COARSE=1     reuse newest existing run as pass 1 (detect+align+profile)
# ===========================================================================
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:?usage: auto-knee-curve.sh <conf_file>}"
[[ -f "$CONF" ]] || { echo "ERROR: conf not found: $CONF"; exit 1; }

COARSE_SEGMENTS="${COARSE_SEGMENTS:-100-4500:250}"
KNEE_STEP="${KNEE_STEP:-20}"

# Observed service (for locating experiment dirs); read from the conf in a
# subshell so sourcing it can't pollute this script's environment.
SVC=$(bash -c "source '$CONF' >/dev/null 2>&1; echo \"\${OBSERVED_SERVICE:-search}\"")

newest_run() {
    ls -dt experiment_data/curve_${SVC}_* 2>/dev/null | head -1
}

log() { echo "[auto-knee $(date '+%H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# Pass 1 — coarse locate (env SATURATION_SEGMENTS overrides the conf default,
# which uses the ${SATURATION_SEGMENTS:-...} form).
# ---------------------------------------------------------------------------
if [[ "${SKIP_COARSE:-0}" != "1" ]]; then
    log "PASS 1 (coarse): SATURATION_SEGMENTS='$COARSE_SEGMENTS'"
    if ! SATURATION_SEGMENTS="$COARSE_SEGMENTS" "$DIR/latency-rate-curve.sh" "$CONF"; then
        log "ERROR: coarse pass failed"; exit 1
    fi
else
    log "SKIP_COARSE=1: reusing newest run as the coarse pass"
fi

RUN=$(newest_run)
[[ -n "$RUN" && -f "$RUN/curve.csv" ]] || { log "ERROR: no curve.csv under experiment_data/curve_${SVC}_*"; exit 1; }
log "coarse curve: $RUN/curve.csv"

# Sanity: warn if the final level's sampler coverage looks clipped (the single
# window closing early truncates the tail levels' active_windows).
python3 - "$RUN/curve.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if rows:
    counts = [int(float(r["active_windows"] or 0)) for r in rows]
    peak = max(counts) if counts else 0
    if peak and counts[-1] < 0.5 * peak:
        sys.stderr.write("WARNING: last level has %d active_windows vs peak %d "
                         "-- sampler window may have closed early; its point is "
                         "untrustworthy\n" % (counts[-1], peak))
PY

# ---------------------------------------------------------------------------
# Detect knee + align the conf.
# ---------------------------------------------------------------------------
SEGMENTS=$(python3 "$DIR/knee_segments.py" "$RUN" --knee-step "$KNEE_STEP" --write-conf "$CONF")
rc=$?
if [[ $rc -eq 2 ]]; then
    log "knee ABOVE ceiling. Wrote suggested taller coarse schedule into stderr above."
    log "Re-run with: COARSE_SEGMENTS='$SEGMENTS' $0 $CONF"
    exit 2
elif [[ $rc -ne 0 ]]; then
    log "ERROR: knee detection failed (rc=$rc)"; exit $rc
fi
log "knee-aligned segments written to $CONF:"
log "  SATURATION_SEGMENTS='$SEGMENTS'"

# ---------------------------------------------------------------------------
# Pass 2 — fine profiling with the aligned conf.
# ---------------------------------------------------------------------------
log "PASS 2 (profile): running with knee-aligned segments"
# env -u: a SATURATION_SEGMENTS exported in the operator's shell must not
# shadow the knee-aligned default just written into the conf.
if ! env -u SATURATION_SEGMENTS "$DIR/latency-rate-curve.sh" "$CONF"; then
    log "ERROR: profiling pass failed"; exit 1
fi

RUN2=$(newest_run)
log "DONE. coarse=$RUN  profile=$RUN2"
log "read the curve from $RUN2/curve.csv (svc_* columns; x=arrival_rps_mean)"
