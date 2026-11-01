#!/bin/bash
# ===========================================================================
# run-motiv2.sh -- motivation experiment, pass 2 (2026-11-01, sm110p, SMT ON)
#
# "Cores needed to reach the same SLO": one phased config
# (configs/motiv-sm110p.yaml, July's sm110p layout: victim 3600 rps, GOMAXPROCS
# 3 on threads 18,19,20, bursty SN/SS aggressors unpinned over the node;
# contention reaches the handler through the siblings 2,3,4), one run per
# CELL. Cells = arm[:placement]:
#
#   none                        reference
#   hc-bang                     harvesting: the victim gets its three physical
#                               cores back (siblings reclaimed), aggressors on
#                               the rest of the node + idle victim threads
#   rep{1,2,3}:samecores        1-3 overflow replicas on the victim's threads 18-20
#   rep{1,2,3}:othercores       ... on threads 21-29 of the same node
#   rep{1,2,3}:othernode        ... on node-3
#
# Per cell: copy the placement's overflow manifest over
# kubernetes/search/search-overflow-deployment.yaml (hr_deploy re-applies that
# file every run), make sure search-overflow is at 0, run
# run-phased-stage3.sh, move the stage3eval dir to $OUT/<cell>/. Resumable:
# a cell whose dir exists is skipped. Each run leaves run_data.json (+ one
# run_data-overflow-<pod>.json per replica), wrk2/*.txt (victim e2e and the
# aggressors' own latency/throughput), mitigation/cpu_usage.csv (per-CPU
# and per-pod core-seconds), pod_uids_*.txt, scores.csv, ctrl.log.
#
# Usage (node-0, tmux, agent-forwarded):
#   ./run-motiv2.sh                      # all 11 cells, ~65 min
#   CELLS="none hc-bang" ./run-motiv2.sh
#   OUT=data/motiv2-t2 ./run-motiv2.sh   # second trial
#   DEADLINE="HH:MM" ./run-motiv2.sh     # stop before the reservation ends
# ===========================================================================
set -uo pipefail
S3="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$S3"
CFG="${CFG:-configs/motiv-sm110p.yaml}"
OUT="${OUT:-data/motiv2}"
# July-like: aggressors roam the whole node except the HC Balancer/Monitor cores
# (14,15 and their siblings 30,31). Empty = fully unconfined.
export AGGR_CPUSET="${AGGR_CPUSET-0-13,16-29}"
OVF="$S3/../../kubernetes/search/search-overflow-deployment.yaml"
CELLS="${CELLS:-none hc-bang rep1:samecores rep2:samecores rep3:samecores rep1:othercores rep2:othercores rep3:othercores rep1:othernode rep2:othernode rep3:othernode}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [motiv2] $*" >&2; }

name=$(yq -r '.experiment.name' "$CFG")
ls -d data/stage3eval_* >/dev/null 2>&1 && { log "FATAL: data/stage3eval_* exists; move it out first"; exit 1; }
mkdir -p "$OUT"
for cell in $CELLS; do
    arm="${cell%%:*}"; place="${cell#*:}"; [[ "$place" == "$cell" ]] && place=""
    dir="$OUT/${arm}${place:+-$place}"
    if [[ -d "$dir" ]]; then log "skip $cell ($dir exists)"; continue; fi
    if [[ -n "${DEADLINE:-}" ]] && (( $(date +%s) + 330 > $(date -d "$DEADLINE" +%s) )); then
        log "deadline $DEADLINE: stopping before $cell"; exit 0
    fi
    cp "motiv2/overflow-${place:-samecores}.yaml" "$OVF"
    kubectl apply -f "$OVF" >/dev/null || { log "FATAL: overflow manifest apply failed"; exit 1; }
    kubectl scale deployment search-overflow --replicas=0 >/dev/null 2>&1
    log "=== $cell -> $dir   (arm=$arm overflow=${place:-samecores} pool=$AGGR_CPUSET)"
    ARM="$arm" ./run-phased-stage3.sh "$CFG" 2>&1 </dev/null | tee "data/.motiv2-${arm}${place:+-$place}.orch.log"
    rc=${PIPESTATUS[0]}
    mkdir -p "$dir"
    mv data/stage3eval_* "$dir"/ 2>/dev/null
    cp "data/.${name}.orchestrator.eval.log" "$dir/" 2>/dev/null
    mv "data/.motiv2-${arm}${place:+-$place}.orch.log" "$dir/" 2>/dev/null
    echo "${place:-samecores}" > "$dir/placement.txt"
    kubectl scale deployment search-overflow --replicas=0 >/dev/null 2>&1
    if [[ $rc -ne 0 ]]; then log "FAILED $cell rc=$rc (see $dir)"; exit 1; fi
done
cp "motiv2/overflow-samecores.yaml" "$OVF"
log "all cells done -> $OUT"
