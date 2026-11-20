#!/bin/bash
# ===========================================================================
# run-motiv3.sh -- motivation experiment, pass 3 (2026-11-08, sm110p "icelake-perf")
#
# Same idea as run-motiv2.sh (one phased run per CELL, resumable) with the
# pass-3 protocol:
#   * configs/motiv3-sm110p.yaml: bursts cover ~10 % of the time (6 s on / 54 s
#     off, two per phase), p1 0-30, p2 30-120, enabled at 120 (ARM_OFFSET_S),
#     p3 120-260;
#   * replicas always on node-3 (motiv2/overflow-node3clean.yaml: threads 18-29,
#     node tainted, 2.4 GHz, SMT on), whose load level is a controlled dial:
#     a busy-loop pod on the replica threads' SMT siblings 2-13
#     (motiv2/node3-load.yaml) at quiet (none) / medium (50 % duty) /
#     contended (100 % duty);
#   * intrinsic scenario (CFG=configs/motiv3-sm110p-int.yaml ARM_OFFSET_S=2
#     BURNER=1): a best-effort HC Secondary tenant on node-4
#     (motiv2/burner-node4.yaml, or BURNER_MANIFEST=...) in every arm, HC enabled from the start.
#
# Cells = arm[:load], load in quiet|medium|contended (default quiet):
#   none  hc-bang  hc-hold  rep1f:quiet rep3f:contended ...  hc-int  rep6f ...
# Output: $OUT/<arm>-<load>/ with the stage3eval dir, cpu_usage-node-3.csv,
# placement.txt, load.txt, arm_offset.txt.
#
# Usage (node-0, detached or tmux):
#   ./run-motiv3.sh
#   CELLS="rep3f:quiet rep3f:medium rep3f:contended" OUT=data/motiv3 ./run-motiv3.sh
#   CFG=configs/motiv3-sm110p-int.yaml ARM_OFFSET_S=2 BURNER=1 OUT=data/motiv3-int CELLS="none hc-int rep1f" ./run-motiv3.sh
# ===========================================================================
set -uo pipefail
S3="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$S3"
CFG="${CFG:-configs/motiv3-sm110p.yaml}"
OUT="${OUT:-data/motiv3}"
export AGGR_CPUSET="${AGGR_CPUSET-0-13,16-29}"
export ARM_OFFSET_S="${ARM_OFFSET_S:-120}"
# 2-P victim in both scenarios (the 3-P victim cannot be overloaded through the chain).
export STAGE3_VICTIM_GOMAXPROCS="${STAGE3_VICTIM_GOMAXPROCS:-2}"
# intrinsic config: the extra driver offers 15.2k rps; the default 256-connection cap
# would throttle it once the victim queues (conns >= rate x tolerated latency).
[[ "$CFG" == *-int* ]] && export WRK2_CONNS_CAP="${WRK2_CONNS_CAP:-640}"
OVF_DST="$S3/../../kubernetes/search/search-overflow-deployment.yaml"
OVF_SRC="motiv2/${OVF:-overflow-node3clean}.yaml"
CELLS="${CELLS:-none hc-bang hc-hold rep1f:quiet rep3f:quiet rep6f:quiet rep1f:medium rep3f:medium rep6f:medium rep1f:contended rep3f:contended rep6f:contended}"
OTHER_NODE="${OTHER_NODE:-node-3}"
SAMPLER="${SAMPLER:-/local/simple-mitigation-1/deploy/stage3/cpu-sampler.sh}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [motiv3] $*" >&2; }
other_sampler_start() {
    ssh -o BatchMode=yes "$OTHER_NODE" "sudo pkill -f '[c]pu-sampler' ; sudo rm -rf /tmp/overflow-data; sudo mkdir -p /tmp/overflow-data; true"
    scp -q "$SAMPLER" "$OTHER_NODE:/tmp/cpu-sampler.sh" || return 0
    ssh -o BatchMode=yes "$OTHER_NODE" "chmod +x /tmp/cpu-sampler.sh; sudo rm -f /tmp/motiv3.cpu.csv
        sudo setsid nohup /tmp/cpu-sampler.sh /tmp/motiv3.cpu.csv 1 </dev/null >/dev/null 2>&1 &" || true
}
other_sampler_stop() {   # <cell dir>
    ssh -o BatchMode=yes "$OTHER_NODE" "sudo pkill -f '[c]pu-sampler' ; true"
    ssh -o BatchMode=yes "$OTHER_NODE" "cat /tmp/motiv3.cpu.csv" > "$1/cpu_usage-$OTHER_NODE.csv" 2>/dev/null || rm -f "$1/cpu_usage-$OTHER_NODE.csv"
}
fetch_overflow_data() {   # <cell dir>: every replica's run file from the node-3 host-path dir (incl. scaled-in pods)
    local run_dir n=0
    run_dir=$(ls -d "$1"/stage3eval_*/runs/run_1 2>/dev/null | head -1); [[ -n "$run_dir" ]] || return 0
    # wait for the last replicas to terminate (SIGTERM -> StopRun writes the file)
    for _ in $(seq 1 30); do   # the preStop hold is 32 s
        [[ -z "$(kubectl get pods -l overflow=true --no-headers 2>/dev/null)" ]] && break; sleep 2
    done
    for pod in $(ssh -o BatchMode=yes "$OTHER_NODE" "ls /tmp/overflow-data 2>/dev/null"); do
        if ssh -o BatchMode=yes "$OTHER_NODE" "sudo cat /tmp/overflow-data/$pod/run_data_search_iter1.json" > "$run_dir/run_data-overflow-$pod.json" 2>/dev/null                 && [[ -s "$run_dir/run_data-overflow-$pod.json" ]]; then n=$((n+1)); else rm -f "$run_dir/run_data-overflow-$pod.json"; fi
    done
    log "overflow run data fetched from $OTHER_NODE: $n replica file(s)"
}
set_load() {   # quiet | medium | contended
    local duty
    case "$1" in
        quiet)     kubectl scale deployment node3-load --replicas=0 >/dev/null 2>&1; return 0 ;;
        medium)    duty=50 ;;
        contended) duty=100 ;;
        *) log "FATAL: unknown load level '$1' (quiet|medium|contended)"; exit 1 ;;
    esac
    kubectl apply -f "${LOAD_MANIFEST:-motiv2/node3-load.yaml}" >/dev/null || return 1   # *-c6320.yaml on the Clemson c6320
    kubectl set env deployment/node3-load DUTY="$duty" >/dev/null
    kubectl scale deployment node3-load --replicas=1 >/dev/null
    kubectl rollout status deployment/node3-load --timeout=120s >/dev/null || log "WARNING: node3-load not ready"
    sleep 3
}
set_burner() {
    if [[ "${BURNER:-0}" == 1 ]]; then
        # Always start the cell with a FRESH burner pod: the burner pins its workers itself
        # (sched_setaffinity to CPUS at start-up) and the hc actuator's Restore resets every
        # Secondary thread's affinity to the whole aggressor pool on shutdown, so a pod that
        # survives an hc-* cell would spread over 8 CPUs (incl. the victim's) in later cells.
        kubectl delete deployment hc-secondary-burner --ignore-not-found --wait=true >/dev/null 2>&1
        kubectl apply -f "${BURNER_MANIFEST:-motiv2/burner-node4.yaml}" >/dev/null
        kubectl rollout status deployment/hc-secondary-burner --timeout=120s >/dev/null || log "WARNING: burner not ready"
    else
        kubectl delete deployment hc-secondary-burner --ignore-not-found --wait=false >/dev/null 2>&1
    fi
}

name=$(yq -r '.experiment.name' "$CFG")
ls -d data/stage3eval_* >/dev/null 2>&1 && { log "FATAL: data/stage3eval_* exists; move it out first"; exit 1; }
mkdir -p "$OUT"
for cell in $CELLS; do
    arm="${cell%%:*}"; load="${cell#*:}"; [[ "$load" == "$cell" ]] && load=quiet
    dir="$OUT/${arm}-${load}"
    if [[ -d "$dir" ]]; then log "skip $cell ($dir exists)"; continue; fi
    if [[ -n "${DEADLINE:-}" ]] && (( $(date +%s) + 420 > $(date -d "$DEADLINE" +%s) )); then
        log "deadline $DEADLINE: stopping before $cell"; exit 0
    fi
    cp "$OVF_SRC" "$OVF_DST"
    kubectl apply -f "$OVF_DST" >/dev/null || { log "FATAL: overflow manifest apply failed"; exit 1; }
    kubectl scale deployment search-overflow --replicas=0 >/dev/null 2>&1
    set_load "$load"
    set_burner
    log "=== $cell -> $dir   (arm=$arm overflow=${OVF:-overflow-node3clean} node-3 load=$load burner=${BURNER:-0} enable=+${ARM_OFFSET_S}s pool=$AGGR_CPUSET)"
    other_sampler_start
    ARM="$arm" ./run-phased-stage3.sh "$CFG" 2>&1 </dev/null | tee "data/.motiv3-${arm}-${load}.orch.log"
    rc=${PIPESTATUS[0]}
    mkdir -p "$dir"
    other_sampler_stop "$dir"
    mv data/stage3eval_* "$dir"/ 2>/dev/null
    kubectl scale deployment search-overflow --replicas=0 >/dev/null 2>&1
    fetch_overflow_data "$dir"
    cp "data/.${name}.orchestrator.eval.log" "$dir/" 2>/dev/null
    mv "data/.motiv3-${arm}-${load}.orch.log" "$dir/" 2>/dev/null
    echo "${OVF:-overflow-node3clean}" > "$dir/placement.txt"
    echo "$load" > "$dir/load.txt"
    echo "$ARM_OFFSET_S" > "$dir/arm_offset.txt"
    kubectl scale deployment search-overflow --replicas=0 >/dev/null 2>&1
    if [[ $rc -ne 0 ]]; then log "FAILED $cell rc=$rc (see $dir)"; exit 1; fi
done
set_load quiet
BURNER=0 set_burner
cp "motiv2/overflow-samecores.yaml" "$OVF_DST"
log "all cells done -> $OUT"
