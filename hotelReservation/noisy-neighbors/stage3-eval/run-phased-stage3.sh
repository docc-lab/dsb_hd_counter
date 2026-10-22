#!/bin/bash
# ===========================================================================
# run-phased-stage3.sh
#
# Phase orchestrator for the stage-3 phased sweep. Runs on node-0 from an
# agent-forwarded shell (it hops to the target node with your ssh agent);
# keep the session alive (tmux) for the whole sweep.
#
# Usage:  ARM=<arm> ./run-phased-stage3.sh configs/phased-*.yaml ...
#
#   ARM names an env file in the controller kit on the target node
#   ($MITIG_DIR/arms/<arm>.env, from simple-mitigation-1/deploy/stage3/):
#   none | isolate | horizontal | combined | hc | hc-combined.
#
# Per config (each must have experiment.runs: 1):
#   1. record every node's cpufreq settings     -> node_freq_floors.txt
#   2. (re)start the mitigation controller DISARMED on the target node
#      (run-mitigation.sh <arm> <name>; $MITIG_DIR/ARM removed first)
#   3. run stage3-eval.sh <config> in the background
#   4. every 10 s, label the config's aggressor pods gordion-aggr=true
#      (rollouts replace pods, so a one-shot label would be lost)
#   5. when the run's t0 (started_epoch_ns.txt) appears, touch
#      $MITIG_DIR/ARM at t0 + ARM_OFFSET_S (default 80)
#   6. snapshot pod placement 30 s into p3     -> pod_placement_p3.txt
#   7. after stage3-eval exits: stop the controller (an hc arm releases the
#      aggressors on shutdown) and collect its log, score trace and env
#      into runs/run_1/mitigation/
# Stops at the first config that fails.
#
# Env: ARM (required), MITIG_HOST (default: the config's target_node),
#      MITIG_DIR (default /tmp/mitig), ARM_OFFSET_S (default 80),
#      P3_SNAPSHOT_S (default 30).
# ===========================================================================

set -uo pipefail

S3_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The testbed libs resolve their manifest dirs from this.
STAGE3_EVAL_DIR="$S3_DIR"
source "$S3_DIR/lib/config-parse.sh"
source "$S3_DIR/lib/testbed-hr.sh"
source "$S3_DIR/lib/testbed-sn.sh"
source "$S3_DIR/lib/testbed-ss.sh"

ARM="${ARM:-}"
MITIG_DIR="${MITIG_DIR:-/tmp/mitig}"
ARM_OFFSET_S="${ARM_OFFSET_S:-80}"
P3_SNAPSHOT_S="${P3_SNAPSHOT_S:-30}"
# Aggressor pool: cpuset.cpus written to every aggressor pod on the target
# node (pod-level cgroup, re-applied every 10 s with the label). On a
# 72-core node unpinned aggressors never touch a 2-core victim; the pool
# recreates July's shared-node contention: 10 cores of socket 0 that
# include the victim's (4,6) and HC's Secondary cores (8-14), excluding
# housekeeping (0,2), the controller (24) and the HC daemons (26-30).
# Empty disables the confinement.
AGGR_CPUSET="${AGGR_CPUSET-4,6,8,10,12,14,16,18,20,22}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10)

orch_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [phased] $*" >&2; }
die() { orch_log "FATAL: $*"; exit 1; }

[[ $# -ge 1 ]] || die "usage: ARM=<arm> $0 <config.yaml> [more.yaml ...]"
[[ -n "$ARM" ]] || die "ARM is required (none|isolate|horizontal|combined|hc|hc-combined)"

# on_target <cmd...>: run on the controller host.
on_target() { "${SSH[@]}" "$MITIG_HOST" "$@"; }

# Kill the controller and wait for it to exit; an hc arm restores on
# SIGTERM, which can take a while (Balancer stop + affinity reset).
stop_controller() {
    on_target "sudo pkill -TERM -f '[m]itigation-controller' || true
        for i in \$(seq 1 40); do pgrep -f '[m]itigation-controller' >/dev/null || exit 0; sleep 1; done
        echo 'controller did not exit in 40s; SIGKILL' >&2
        sudo pkill -KILL -f '[m]itigation-controller' || true"
}

record_freq_floors() {
    local out="$1" n
    : > "$out"
    for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
        {
            echo "== $n"
            "${SSH[@]}" "$n" 'c=/sys/devices/system/cpu
                echo "driver=$(cat $c/cpu0/cpufreq/scaling_driver 2>/dev/null)"
                echo "no_turbo=$(cat $c/intel_pstate/no_turbo 2>/dev/null)"
                echo "governor: $(cat $c/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c | tr -s " " | tr "\n" ";")"
                echo "min_freq: $(cat $c/cpu*/cpufreq/scaling_min_freq 2>/dev/null | sort | uniq -c | tr -s " " | tr "\n" ";")"
                echo "max_freq: $(cat $c/cpu*/cpufreq/scaling_max_freq 2>/dev/null | sort | uniq -c | tr -s " " | tr "\n" ";")"
                echo "setspeed: $(cat $c/cpu*/cpufreq/scaling_setspeed 2>/dev/null | sort | uniq -c | tr -s " " | tr "\n" ";")"' \
                2>&1 || echo "(ssh to $n failed)"
        } >> "$out"
    done
}

# Label the config's aggressor pods (all replicas) for the controller's
# AGGRESSOR_SELECTOR. Runs until the given pid exits.
label_loop() {
    local eval_pid="$1" i tb svc ns deploy sel
    local -a sels=()
    for ((i = 0; i < AGGRESSOR_COUNT; i++)); do
        tb=$(aggressor_field "$i" '.testbed')
        svc=$(aggressor_field "$i" '.service')
        case "$tb" in
            hotelReservation) ns="$HR_NAMESPACE"; deploy=$(hr_deployment_for_service "$svc") ;;
            socialNetwork)    ns="$SN_NAMESPACE"; deploy=$(sn_deployment_for_service "$svc") ;;
            sockshop)         ns="$SS_NAMESPACE"; deploy=$(ss_deployment_for_service "$svc") ;;
            *) continue ;;
        esac
        [[ -n "$deploy" ]] && sels+=("$ns|$deploy")
    done
    while kill -0 "$eval_pid" 2>/dev/null; do
        local entry
        for entry in "${sels[@]:-}"; do
            [[ -z "$entry" ]] && continue
            ns="${entry%%|*}"; deploy="${entry#*|}"
            sel=$(kubectl -n "$ns" get deployment "$deploy" -o json 2>/dev/null \
                | jq -r '.spec.selector.matchLabels // {} | to_entries | map("\(.key)=\(.value)") | join(",")')
            [[ -z "$sel" ]] && continue
            kubectl -n "$ns" label pods -l "$sel" gordion-aggr=true --overwrite >/dev/null 2>&1 || true
        done
        confine_aggressors
        sleep 10
    done
}

# Write AGGR_CPUSET into the pod-level cgroup of every labeled aggressor pod
# running on the target node. Pod-level so it survives the hc actuator's
# container-level writes (HC's secondary∪victim set is a subset of the pool
# and HC restores the container value it saved, not ours). Handles both the
# cgroupfs (kubepods/<qos>/pod<uid>) and systemd (…-pod<uid_>.slice) layouts.
confine_aggressors() {
    [[ -n "$AGGR_CPUSET" ]] || return 0
    local uids
    uids=$(kubectl get pods -A -l gordion-aggr=true --field-selector "spec.nodeName=$MITIG_HOST" \
        -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}' 2>/dev/null | sort -u | tr '\n' ' ')
    [[ -n "${uids// /}" ]] || return 0
    on_target "sudo sh -c '
        for u in $uids; do
            u2=\$(echo \$u | tr - _)
            found=0
            for d in \$(find /sys/fs/cgroup -maxdepth 4 -type d \( -name \"pod\$u\" -o -name \"*-pod\$u2.slice\" \) 2>/dev/null); do
                [ -f \$d/cpuset.cpus ] || { echo \"confine: no cpuset.cpus in \$d\" >&2; continue; }
                found=1
                cur=\$(cat \$d/cpuset.cpus)
                [ \"\$cur\" = \"$AGGR_CPUSET\" ] || echo \"$AGGR_CPUSET\" > \$d/cpuset.cpus 2>/dev/null \
                    || echo \"confine: write failed for \$d\" >&2
            done
            [ \$found = 1 ] || echo \"confine: no cgroup dir for pod \$u\" >&2
        done'" 2>&1 | sed 's/^/[phased]   /' >&2 || true
}

# Evidence that the pool (and, for hc arms, the Balancer) actually took
# effect: per aggressor pod on the target, the pod cgroup's cpuset and one
# thread's Cpus_allowed_list; plus the victim's affinity and the CPU% of
# every container on the target node.
snapshot_aggressors() {
    local uids
    uids=$(kubectl get pods -A -l gordion-aggr=true --field-selector "spec.nodeName=$MITIG_HOST" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.metadata.uid}{"\n"}{end}' 2>/dev/null | tr '\n' ' ')
    echo "pool=${AGGR_CPUSET:-none} host=$MITIG_HOST $(date '+%H:%M:%S')"
    on_target "sudo sh -c '
        for e in $uids; do
            n=\${e%%=*}; u=\${e#*=}; u2=\$(echo \$u | tr - _)
            d=\$(find /sys/fs/cgroup -maxdepth 4 -type d \( -name \"pod\$u\" -o -name \"*-pod\$u2.slice\" \) 2>/dev/null | head -1)
            [ -n \"\$d\" ] || { echo \"\$n: no cgroup dir\"; continue; }
            pid=\$(find \$d -name cgroup.procs -exec cat {} + 2>/dev/null | head -1)
            aff=\$([ -n \"\$pid\" ] && awk \"/Cpus_allowed_list/{print \\\$2}\" /proc/\$pid/status 2>/dev/null)
            echo \"\$n: cpuset=[\$(cat \$d/cpuset.cpus 2>/dev/null)] effective=[\$(cat \$d/cpuset.cpus.effective 2>/dev/null)] thread_affinity=[\$aff]\"
        done
        for p in \$(pgrep -x search); do echo \"victim pid \$p: \$(grep Cpus_allowed_list /proc/\$p/status)\"; done
        echo \"-- docker stats (CPU%)\"
        docker stats --no-stream --format \"{{.CPUPerc}}\t{{.Name}}\" 2>/dev/null | grep -v _POD_ | sort -rn | head -25 | cut -c1-90'"
}

preflight() {
    command -v kubectl >/dev/null || die "kubectl missing"
    on_target "test -x $MITIG_DIR/mitigation-controller && test -x $MITIG_DIR/run-mitigation.sh \
        && test -f $MITIG_DIR/arms/common.env && test -f $MITIG_DIR/arms/$ARM.env \
        && test -f $MITIG_DIR/targets.yaml && test -f $MITIG_DIR/policy-formula.yaml \
        && test -f $MITIG_DIR/kubeconfig-admin" \
        || die "controller kit incomplete on $MITIG_HOST:$MITIG_DIR (see deploy/stage3/README.md in simple-mitigation-1)"
    if [[ "$ARM" == hc* ]]; then
        on_target "systemctl is-active --quiet hc-listener && test -r /proc/idlecpu/cpulist \
            && ! systemctl is-active --quiet hc-balancer" \
            || die "hc arm: need hc-listener active, qidlecpu loaded, static hc-balancer stopped on $MITIG_HOST"
    fi
}

run_config() {
    local cfg="$1"
    parse_config "$cfg" || die "config parse failed: $cfg"
    [[ "$EXPERIMENT_RUNS" -eq 1 ]] || die "$cfg: experiment.runs must be 1 for phased runs (got $EXPERIMENT_RUNS)"
    local name="$EXPERIMENT_NAME"
    MITIG_HOST="${MITIG_HOST_OVERRIDE:-$TARGET_NODE}"

    orch_log "=================================================================="
    orch_log " $name  (arm=$ARM, controller on $MITIG_HOST:$MITIG_DIR, aggressor pool=${AGGR_CPUSET:-none})"
    orch_log "=================================================================="
    preflight

    local stage_dir; stage_dir=$(mktemp -d)
    record_freq_floors "$stage_dir/node_freq_floors.txt"

    orch_log "Starting controller DISARMED"
    stop_controller
    # Separate statements: a backgrounded `a && b` list would keep ssh's
    # stdout open and hang the session.
    on_target "sudo rm -f $MITIG_DIR/ARM || exit 1
        sudo setsid nohup $MITIG_DIR/run-mitigation.sh '$ARM' '$name' </dev/null >/dev/null 2>&1 &" \
        || die "failed to launch controller"
    sleep 3
    on_target "pgrep -f '[m]itigation-controller' >/dev/null" \
        || die "controller not running; see $MITIG_HOST:$MITIG_DIR/$name.ctrl.log"

    local started_after; started_after=$(date +%s)
    local eval_log="$S3_DIR/data/.${name}.orchestrator.eval.log"
    mkdir -p "$S3_DIR/data"
    "$S3_DIR/stage3-eval.sh" "$cfg" > "$eval_log" 2>&1 &
    local eval_pid=$!
    orch_log "stage3-eval.sh pid $eval_pid (log: $eval_log)"

    label_loop "$eval_pid" &
    local label_pid=$!

    # Wait for this run's t0: a started_epoch_ns.txt newer than our launch.
    local t0_file="" f
    while kill -0 "$eval_pid" 2>/dev/null && [[ -z "$t0_file" ]]; do
        for f in "$S3_DIR"/data/stage3eval_*/runs/run_1/started_epoch_ns.txt; do
            [[ -f "$f" ]] || continue
            if [[ $(stat -c %Y "$f") -ge "$started_after" ]]; then
                t0_file="$f"
            fi
        done
        [[ -z "$t0_file" ]] && sleep 1
    done

    local run_dir="" armed_ns=""
    if [[ -n "$t0_file" ]]; then
        run_dir=$(dirname "$t0_file")
        local t0_ns t0_s now_s wait_s
        t0_ns=$(cat "$t0_file")
        t0_s=$(( t0_ns / 1000000000 ))
        now_s=$(date +%s)
        wait_s=$(( t0_s + ARM_OFFSET_S - now_s ))
        orch_log "t0 found ($(date -d "@$t0_s" '+%H:%M:%S')); arming in ~${wait_s}s"
        (( wait_s > 0 )) && sleep "$wait_s"
        if kill -0 "$eval_pid" 2>/dev/null; then
            on_target "sudo touch $MITIG_DIR/ARM" || orch_log "WARNING: failed to touch ARM"
            armed_ns=$(date +%s%N)
            orch_log "ARMED at $(date '+%H:%M:%S')"
            sleep "$P3_SNAPSHOT_S"
            kubectl get pods -A -o wide > "$stage_dir/pod_placement_p3.txt" 2>&1 || true
            snapshot_aggressors > "$stage_dir/aggr_affinity_p3.txt" 2>&1 || true
        else
            orch_log "WARNING: stage3-eval exited before the ARM point"
        fi
    else
        orch_log "WARNING: stage3-eval exited before t0; nothing armed"
    fi

    wait "$eval_pid"
    local rc=$?
    kill "$label_pid" 2>/dev/null; wait "$label_pid" 2>/dev/null
    orch_log "stage3-eval.sh exited rc=$rc; stopping controller"
    stop_controller

    if [[ -n "$run_dir" ]]; then
        local mdir="$run_dir/mitigation"
        mkdir -p "$mdir"
        cp "$stage_dir"/* "$mdir/" 2>/dev/null
        cp "$cfg" "$mdir/config-as-run.yaml"
        if [[ -n "$armed_ns" ]]; then
            echo "$armed_ns" > "$mdir/armed_epoch_ns.txt"
            echo "$armed_ns" > "$run_dir/armed_epoch_ns.txt"
        fi
        echo "$ARM" > "$mdir/arm.txt"
        echo "${AGGR_CPUSET:-none}" > "$mdir/aggr_cpuset.txt"
        local ext
        for ext in ctrl.log scores.csv env.txt; do
            "${SSH[@]}" "$MITIG_HOST" "cat $MITIG_DIR/$name.$ext" > "$mdir/$name.$ext" 2>/dev/null \
                || orch_log "WARNING: could not fetch $name.$ext"
        done
        if [[ "$ARM" == hc* ]]; then
            # The newest Balancer work dir (balancer.log, idleMaskChanges.log)
            # plus the Listener log tail.
            on_target "d=\$(ls -1dt /mnt/extra/logs/hc/[0-9]* 2>/dev/null | head -1);
                [ -n \"\$d\" ] && tar -C \"\$d\" -czf - . " > "$mdir/hc-balancer.tgz" 2>/dev/null \
                || rm -f "$mdir/hc-balancer.tgz"
            on_target "tail -n 200 /mnt/extra/logs/hc/listener.log" > "$mdir/hc-listener.tail.log" 2>/dev/null || true
        fi
        orch_log "Collected -> $mdir"
    fi
    rm -rf "$stage_dir"

    [[ $rc -eq 0 ]] || die "$name failed (rc=$rc); see $eval_log"
}

MITIG_HOST_OVERRIDE="${MITIG_HOST:-}"
for cfg in "$@"; do
    [[ -f "$cfg" ]] || die "config not found: $cfg"
    run_config "$cfg"
done
orch_log "Sweep done: $# config(s), arm=$ARM"
