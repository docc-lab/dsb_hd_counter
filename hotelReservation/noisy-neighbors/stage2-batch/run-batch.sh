#!/bin/bash
# ===========================================================================
# stage2-batch/run-batch.sh
#
# Drive a batch of data-collector.sh experiments end-to-end with pre-flight
# cluster health checks between every run and resume-from-where-we-left-off
# semantics across re-invocations.
#
# This script LIVES in noisy-neighbors/stage2-batch/ but always operates
# with noisy-neighbors/ as its working directory, so relative paths like
# configs/, experiment_data/, batch_logs/, and STOP_BATCH always anchor on
# the noisy-neighbors directory regardless of where you invoke the script
# from.
#
# Usage (from anywhere):
#   ./stage2-batch/run-batch.sh                       # all configs/[0-9]*.conf, resume mode
#   ./stage2-batch/run-batch.sh --no-resume           # also re-run configs that already passed
#   ./stage2-batch/run-batch.sh --pattern 'configs/10s_*.conf'   # custom glob
#   ./stage2-batch/run-batch.sh --dry-run             # show what WOULD run; don't execute
#   ./stage2-batch/run-batch.sh --stop-file PATH      # graceful-stop sentinel (default: ./STOP_BATCH)
#
# Behavior:
#   - Runs stage2-batch/cluster-healthcheck.sh once at the start (must pass).
#   - For each config:
#       * if the stop sentinel exists, exit cleanly BEFORE the next config
#       * skip if a successful run already exists (resume mode, default)
#       * re-run cluster-healthcheck.sh; if it FAILs, abort the batch
#       * invoke ./data-collector.sh "$cfg", tee output to batch_logs/<name>.run.log
#   - At the end, calls extract-failed-exps.sh to produce batch_logs/summary.txt.
#
# Graceful pause / resume:
#   To pause AFTER the current run finishes (no partial exp_* dirs), from
#   another shell, in the noisy-neighbors directory:
#       touch STOP_BATCH
#   The script will exit with code 3 between configs.
#   To resume later, simply re-run ./stage2-batch/run-batch.sh; it'll skip
#   whatever already has metadata/validation_success.txt. Remember to:
#       rm -f STOP_BATCH
#   before the new invocation.
#
# Logs are written under ./batch_logs/ (relative to noisy-neighbors).
# Exit codes: 0 = batch finished (with or without per-run failures),
#             1 = initial preflight failed,
#             2 = mid-batch preflight failed (aborted partway),
#             3 = stopped by --stop-file sentinel.
# ===========================================================================

set -u

# Resolve this script's directory, then anchor cwd on noisy-neighbors/ so
# every relative path below (configs/, experiment_data/, batch_logs/,
# STOP_BATCH, ./data-collector.sh) means the same thing regardless of where
# the user invoked us from.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PARENT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
cd "$PARENT_DIR" || { echo "Cannot cd to $PARENT_DIR" >&2; exit 1; }

if [[ ! -x ./data-collector.sh ]]; then
    echo "ERROR: ./data-collector.sh not found or not executable in $PARENT_DIR" >&2
    echo "       (expected stage2-batch/ to live alongside data-collector.sh)" >&2
    exit 1
fi

PATTERN='configs/[0-9]*.conf'
RESUME=true
DRY_RUN=false
STOP_FILE='./STOP_BATCH'

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-resume) RESUME=false; shift ;;
        --resume)    RESUME=true;  shift ;;
        --pattern)   PATTERN="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --stop-file) STOP_FILE="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,49p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

# Refuse to start with a stale stop sentinel from a previous run.
if [[ -e "$STOP_FILE" ]]; then
    echo "Stop sentinel $STOP_FILE already exists." >&2
    echo "Remove it before starting:  rm $STOP_FILE" >&2
    exit 1
fi

mkdir -p batch_logs

# ---------------------------------------------------------------------------
# Resume helper: return 0 iff some experiment_data/exp_*/metadata/experiment.json
# has experiment_name == "$1" AND that experiment has validation_success.txt.
# Pure bash, no fragile xargs / pipeline-exit-code semantics.
# ---------------------------------------------------------------------------
already_passed() {
    local cfg_name="$1"
    local needle="\"experiment_name\": \"${cfg_name}\""

    shopt -s nullglob
    local found=1
    for exp_dir in experiment_data/exp_*; do
        local meta="$exp_dir/metadata"
        [[ -f "$meta/experiment.json"       ]] || continue
        [[ -f "$meta/validation_success.txt" ]] || continue
        if grep -qF "$needle" "$meta/experiment.json" 2>/dev/null; then
            found=0
            break
        fi
    done
    shopt -u nullglob
    return $found
}

# ---------------------------------------------------------------------------
# Initial cluster gate.
# ---------------------------------------------------------------------------
echo "=== Initial cluster preflight ==="
if ! "$SCRIPT_DIR/cluster-healthcheck.sh"; then
    echo "Aborting: cluster unhealthy at start of batch" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Enumerate configs.
# ---------------------------------------------------------------------------
shopt -s nullglob
# shellcheck disable=SC2206
configs=($PATTERN)
shopt -u nullglob

if [[ ${#configs[@]} -eq 0 ]]; then
    echo "No configs matched pattern: $PATTERN" >&2
    exit 1
fi

echo
echo "Found ${#configs[@]} config(s) matching '$PATTERN'"
$RESUME && echo "Resume mode: ON (configs with a successful run will be skipped)"
$DRY_RUN && echo "Dry-run: ON (data-collector.sh will NOT be invoked)"
echo

# ---------------------------------------------------------------------------
# Batch loop.
# ---------------------------------------------------------------------------
total=${#configs[@]}
ran=0; skipped=0; failed_preflights=0
start_epoch=$(date +%s)

stopped=0
for i in "${!configs[@]}"; do
    cfg="${configs[$i]}"
    name=$(basename "$cfg" .conf)
    idx=$((i + 1))

    # Check the graceful-stop sentinel BETWEEN configs so the current run
    # (if any) is allowed to finish cleanly. Exit code 3 communicates this
    # was an operator-requested pause, not a failure.
    if [[ -e "$STOP_FILE" ]]; then
        echo "=== [$idx/$total] STOP sentinel $STOP_FILE detected; pausing batch ==="
        stopped=1
        break
    fi

    if $RESUME && already_passed "$name"; then
        echo "=== [$idx/$total] SKIP   $name (already has a successful run) ==="
        skipped=$((skipped + 1))
        continue
    fi

    echo "=== [$idx/$total] [$(date -Iseconds)] START  $name ==="

    if $DRY_RUN; then
        echo "  (dry-run: would run ./data-collector.sh $cfg)"
        continue
    fi

    if ! "$SCRIPT_DIR/cluster-healthcheck.sh" > "batch_logs/${name}.preflight.log" 2>&1; then
        echo "  PREFLIGHT FAILED before $name — aborting batch"
        echo "  see batch_logs/${name}.preflight.log"
        failed_preflights=1
        break
    fi

    ./data-collector.sh "$cfg" 2>&1 | tee "batch_logs/${name}.run.log"
    ran=$((ran + 1))
done

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
elapsed=$(( $(date +%s) - start_epoch ))
echo
echo "============================================================"
echo "Batch finished in ${elapsed}s"
echo "  Ran:                $ran"
echo "  Skipped (resume):   $skipped"
echo "  Total configs:      $total"
echo "============================================================"

if [[ -x "$SCRIPT_DIR/extract-failed-exps.sh" ]]; then
    echo "Generating classification summary..."
    "$SCRIPT_DIR/extract-failed-exps.sh" ./experiment_data ./configs > batch_logs/summary.txt 2>&1 || true
    tail -1 batch_logs/summary.txt
    echo "Full summary: batch_logs/summary.txt"
fi

if [[ $failed_preflights -ne 0 ]]; then
    exit 2
fi
if [[ $stopped -ne 0 ]]; then
    echo "Paused. Remove the sentinel and re-run to resume:"
    echo "    rm $STOP_FILE && ./stage2-batch/run-batch.sh"
    exit 3
fi
exit 0
