#!/bin/bash
# ===========================================================================
# run-collect.sh -- predictor-training collection sweep (ARM=none).
#
# Walks configs/collect/plan.txt (`<AGGR_CPUSET> <config.yaml>` per line,
# from tools/gen_collect_configs.py), runs each point through the phase
# orchestrator with mitigation disabled, and files the result under
# data/<OUT>/<config name>/. Unlike run-phased-stage3.sh it does NOT stop
# at the first failure (the failed point is logged and skipped), and it is
# resumable: points whose output dir already exists are skipped.
#
#   ./run-collect.sh                          # whole plan -> data/collect-smt
#   OUT=collect-smt2 ./run-collect.sh         # different output dir
#   DEADLINE="21:05" ./run-collect.sh         # don't START a point that would
#                                             #   not finish by 21:05 (server time)
#   PLAN=configs/collect/plan.txt
#
# Run on node-0 inside tmux with your ssh agent forwarded (the orchestrator
# hops to node-4). ~5.5 min per point.
# ===========================================================================
set -uo pipefail

S3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$S3_DIR"

PLAN="${PLAN:-configs/collect/plan.txt}"
OUT="${OUT:-collect-smt}"
DEADLINE="${DEADLINE:-}"          # HH:MM server time; empty = no limit
POINT_S="${POINT_S:-420}"         # conservative per-point wall time (s)

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [collect] $*" >&2; }

[[ -f "$PLAN" ]] || { log "no plan at $PLAN (run tools/gen_collect_configs.py)"; exit 1; }
mkdir -p "data/$OUT"
echo "$(date -Iseconds) smt=$(ssh -o BatchMode=yes node-4 cat /sys/devices/system/cpu/smt/active 2>/dev/null)" >> "data/$OUT/sweep.log"

deadline_epoch=""
if [[ -n "$DEADLINE" ]]; then
    deadline_epoch=$(date -d "today $DEADLINE" +%s) || { log "bad DEADLINE '$DEADLINE'"; exit 1; }
fi

ok=0; failed=0; skipped=0
# plan on fd 3: the orchestrator (ssh, kubectl exec) reads stdin and would
# swallow the rest of the plan after the first point.
while read -r -u 3 pool cfg; do
    [[ -z "${pool:-}" || "$pool" == \#* ]] && continue
    name=$(basename "$cfg" .yaml)
    dest="data/$OUT/$name"
    if [[ -d "$dest" ]]; then
        log "skip $name (exists)"; skipped=$((skipped+1)); continue
    fi
    if [[ -n "$deadline_epoch" && $(( $(date +%s) + POINT_S )) -gt "$deadline_epoch" ]]; then
        log "deadline $DEADLINE: not starting $name"; break
    fi
    [[ -f "$cfg" ]] || { log "FAIL $name: config missing"; failed=$((failed+1)); continue; }

    log "=== $name  pool=$pool"
    # any leftover from an interrupted point would be filed under this name
    rm -rf data/stage3eval_* data/.*.orchestrator.eval.log 2>/dev/null
    AGGR_CPUSET="$pool" ARM=none ./run-phased-stage3.sh "$cfg" </dev/null
    rc=$?
    mkdir -p "$dest"
    mv data/stage3eval_* "$dest"/ 2>/dev/null
    mv data/.*.orchestrator.eval.log "$dest"/ 2>/dev/null
    echo "$pool" > "$dest/aggr_cpuset.txt"
    if [[ $rc -eq 0 && -n "$(ls -d "$dest"/stage3eval_* 2>/dev/null)" ]]; then
        ok=$((ok+1))
        echo "$(date -Iseconds) ok   $name pool=$pool" >> "data/$OUT/sweep.log"
        python3 tools/run_data_phases.py "$dest" 2>&1 | head -1 >&2
    else
        failed=$((failed+1))
        echo "$(date -Iseconds) FAIL $name rc=$rc" >> "data/$OUT/sweep.log"
        log "FAIL $name rc=$rc (continuing)"
    fi
done 3< "$PLAN"

log "done: ok=$ok failed=$failed skipped=$skipped -> data/$OUT"
python3 tools/run_data_phases.py "data/$OUT"/* 2>&1 | grep -v "^perf_events" >&2
