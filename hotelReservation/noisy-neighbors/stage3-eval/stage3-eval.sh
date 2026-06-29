#!/bin/bash
# ===========================================================================
# stage3-eval.sh
#
# Stage 3 aggressor + evaluation pipeline orchestrator.
#
# Usage:  ./stage3-eval.sh <config.yaml> [--uninstall-sn]
#
# What this does (in order):
#   1. parse + validate YAML, create data/<experiment_id>/
#   2. apply pre-experiment MSR module load on TARGET_NODE
#   3. deploy testbeds in scope (the victim's testbed + any testbed
#      referenced by an aggressor)
#   4. swap victim image to the configured stage3-predictor build,
#      patch MSR pod capabilities, set GORDION_SCORE_LOG per YAML,
#      apply CPU pinning + nodeSelector
#   5. apply aggressor placement (nodeSelector pins to victim's node)
#      and wait for each to be Ready
#   6. warmup sleep
#   7. for run = 1..N:
#        record start_epoch_ns -> start ONE wrk2 driver per in-scope
#        testbed in the background (each hits its testbed's frontend
#        with the testbed's native mixed workload) -> sleep duration_s
#        -> record end_epoch_ns -> stop all wrk2 drivers ->
#        write per_run.json -> cooldown
#   8. build experiment_manifest.json
#   9. cleanup trap restores nodeSelector/tolerations across testbeds
#
# Load model (changed from earlier ghz-on-victim design):
#   Each in-scope testbed gets exactly ONE wrk2 driver hitting its
#   native frontend (HR's `frontend`, SN's `nginx-thrift`, ...) with
#   its native mixed end-to-end workload. The victim's load is
#   whatever flows through its call chain when that wrk2 runs; we
#   never talk to the victim's gRPC port directly. See
#   configs/schema.md "Loadgen model" for the rationale.
#
# What this deliberately does NOT do:
#   - subscribe to :7900 (ContentionStream) or :7901 (InstrumentationStream)
#   - run perf stat / per-pid /proc monitor (Sample stream has those)
#   - compute correlations or produce a report
# Those are the mitigation-side project's job. See README.md
# "Integration with mitigation side" for the contract.
# ===========================================================================

set -uo pipefail

STAGE3_EVAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$STAGE3_EVAL_DIR/lib"

# ---------------------------------------------------------------------------
# Source helpers
# ---------------------------------------------------------------------------

# Stage 2 helper libraries reused for kubectl heavy lifting. We `source`
# rather than copy so any future fix in those scripts flows through.
# Both scripts `set -e` at their top, which would propagate after source.
# The orchestrator uses explicit `|| die` everywhere, so we clear -e
# after sourcing to avoid surprise exits from kubectl returning non-zero
# on benign races (deployment-already-exists, etc.).
source "$STAGE3_EVAL_DIR/../data-collector.sh"      >/dev/null 2>&1 || true
source "$STAGE3_EVAL_DIR/../step1-characterize.sh"  >/dev/null 2>&1 || true
set +e

# Stage 3 eval pipeline library
# shellcheck source=lib/config-parse.sh
source "$LIB_DIR/config-parse.sh"
# shellcheck source=lib/wrk2-driver.sh
source "$LIB_DIR/wrk2-driver.sh"
# shellcheck source=lib/aggressor-place.sh
source "$LIB_DIR/aggressor-place.sh"
# shellcheck source=lib/testbed-hr.sh
source "$LIB_DIR/testbed-hr.sh"
# shellcheck source=lib/testbed-sn.sh
source "$LIB_DIR/testbed-sn.sh"
# shellcheck source=lib/testbed-ss.sh
source "$LIB_DIR/testbed-ss.sh"
# shellcheck source=lib/write-run-manifest.sh
source "$LIB_DIR/write-run-manifest.sh"

# Re-anchor paths the lib helpers default to relatively (their defaults
# assume CWD == lib/, but the orchestrator's CWD is stage3-eval/ or
# wherever the user invoked it from).
HR_KUBERNETES_DIR="${HR_KUBERNETES_DIR:-$STAGE3_EVAL_DIR/../../kubernetes}"
SN_CHART_DIR="${SN_CHART_DIR:-$STAGE3_EVAL_DIR/../../../socialNetwork/helm-chart/socialnetwork}"
WRK2_BIN="${WRK2_BIN:-$STAGE3_EVAL_DIR/../../../wrk2/wrk}"
WRK2_TESTBED_SCRIPT[hotelReservation]="$STAGE3_EVAL_DIR/../../wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua"
WRK2_TESTBED_SCRIPT[socialNetwork]="$STAGE3_EVAL_DIR/../../../socialNetwork/wrk2/scripts/social-network/mixed-workload.lua"
WRK2_TESTBED_SCRIPT[sockshop]="$STAGE3_EVAL_DIR/../../wrk2/scripts/sockshop/mixed-workload.lua"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
s3_log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [stage3-eval] $*"
    echo "$msg" >&2
    if [[ -n "${EXP_DIR:-}" && -d "$EXP_DIR/logs" ]]; then
        echo "$msg" >> "$EXP_DIR/logs/stage3-eval.log"
    fi
}

die() {
    s3_log "FATAL: $*"
    exit 1
}

# ---------------------------------------------------------------------------
# State carried across functions for the cleanup trap
# ---------------------------------------------------------------------------
RUN_WRK2_PIDFILES=()        # paths to pidfiles started this run
RUN_PLACED_AGGRESSORS=()    # "<namespace>|<deployment>" pairs to unplace at cleanup
DRIVEN_TESTBEDS=()          # testbed names in scope (set by determine_used_testbeds)

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup_trap() {
    local rc=$?
    s3_log "Cleanup trap (rc=$rc) running..."

    local pf
    for pf in "${RUN_WRK2_PIDFILES[@]:-}"; do
        [[ -n "$pf" ]] && stop_wrk2_driver "$pf" 2>/dev/null || true
    done

    local entry ns deploy
    for entry in "${RUN_PLACED_AGGRESSORS[@]:-}"; do
        [[ -z "$entry" ]] && continue
        ns="${entry%%|*}"
        deploy="${entry#*|}"
        unplace_aggressor "$ns" "$deploy" || true
    done

    if [[ -n "${EXP_DIR:-}" ]]; then
        local tb
        for tb in "${DRIVEN_TESTBEDS[@]:-}"; do
            case "$tb" in
                hotelReservation) hr_teardown "$EXP_DIR" 2>/dev/null || true ;;
                socialNetwork)
                    if [[ "${UNINSTALL_SN:-false}" == "true" ]]; then
                        sn_uninstall "$EXP_DIR" 2>/dev/null || true
                    else
                        sn_teardown "$EXP_DIR" 2>/dev/null || true
                    fi
                    ;;
                sockshop) ss_teardown "$EXP_DIR" 2>/dev/null || true ;;
            esac
        done
    fi

    s3_log "Cleanup done."
    exit "$rc"
}

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
usage() {
    cat <<USAGE
Usage: $0 <config.yaml> [--uninstall-sn]

  <config.yaml>        Path to a per-experiment YAML file (see configs/schema.md).
  --uninstall-sn       At cleanup, fully uninstall the socialNetwork helm
                       release + delete its namespace. Default is a soft
                       teardown that leaves the release in place so the
                       next experiment starts fast.

See README.md for end-to-end documentation including the contract this
pipeline exposes to the mitigation-side eval-report fetcher.
USAGE
}

main() {
    if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 1
    fi

    local config_file="$1"
    shift || true
    UNINSTALL_SN=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --uninstall-sn) UNINSTALL_SN=true ; shift ;;
            *) die "Unknown flag: $1 (see --help)" ;;
        esac
    done

    [[ -f "$config_file" ]] || die "config file not found: $config_file"

    parse_config "$config_file" || die "config parse failed"

    local exp_id
    exp_id="stage3eval_$(date +%Y%m%d_%H%M%S)_$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')"
    EXP_DIR="$STAGE3_EVAL_DIR/data/$exp_id"
    mkdir -p "$EXP_DIR/logs" "$EXP_DIR/runs" "$EXP_DIR/metadata"
    cp "$config_file" "$EXP_DIR/input.yaml"
    export EXP_DIR

    # Sidecar JSON dumps for any future subshell that needs them.
    yq -o=json -I=0 '.aggressors // []' "$config_file" > "$EXP_DIR/metadata/aggressors.json"
    yq -o=json -I=0 '.testbeds   // {}' "$config_file" > "$EXP_DIR/metadata/testbeds.json"

    s3_log "Experiment id: $exp_id"
    s3_log "Output dir   : $EXP_DIR"
    s3_log "Config       : $config_file"
    s3_log "Victim       : $VICTIM_SERVICE on $TARGET_NODE (image: $VICTIM_IMAGE; score_log=$VICTIM_SCORE_LOG)"
    s3_log "Aggressors   : $AGGRESSOR_COUNT"
    s3_log "Runs         : $EXPERIMENT_RUNS x ${EXPERIMENT_DURATION_S}s (warmup ${EXPERIMENT_WARMUP_S}s, cooldown ${EXPERIMENT_COOLDOWN_S}s)"

    trap cleanup_trap EXIT INT TERM

    preflight_tools
    determine_used_testbeds
    prep_victim_node
    deploy_testbeds
    # Reset seed-on-boot DB bloat to a clean baseline (cheap no-op when the
    # DBs are already small). clean_hr_databases is sourced from data-collector.sh.
    if declare -F clean_hr_databases >/dev/null 2>&1; then
        clean_hr_databases "$EXP_DIR" || true
    fi
    deploy_victim
    place_all_aggressors
    recover_consul_state

    s3_log "Warmup: sleeping ${EXPERIMENT_WARMUP_S}s before run 1"
    sleep "$EXPERIMENT_WARMUP_S"

    local run_id
    for ((run_id = 1; run_id <= EXPERIMENT_RUNS; run_id++)); do
        run_one_iteration "$run_id"
        if [[ "$run_id" -lt "$EXPERIMENT_RUNS" ]]; then
            s3_log "Cooldown ${EXPERIMENT_COOLDOWN_S}s before next run"
            sleep "$EXPERIMENT_COOLDOWN_S"
        fi
    done

    build_experiment_manifest "$EXP_DIR" || s3_log "WARNING: failed to build experiment_manifest.json"

    s3_log "============================================================"
    s3_log " EXPERIMENT COMPLETE"
    s3_log "============================================================"
    s3_log " Data dir   : $EXP_DIR"
    s3_log " Manifest   : $EXP_DIR/experiment_manifest.json"
    s3_log " Mitigation-side fetcher should walk \$EXP_DIR/runs/run_*/per_run.json"
    s3_log "============================================================"
}

# ---------------------------------------------------------------------------
# Tool preflight
# ---------------------------------------------------------------------------
preflight_tools() {
    s3_log "Tool preflight"
    require_yq_jq || die "yq + jq missing"
    command -v kubectl >/dev/null 2>&1 || die "kubectl missing"
    [[ -x "$WRK2_BIN" || -f "$WRK2_BIN" ]] || die "wrk2 binary missing at WRK2_BIN=$WRK2_BIN"
    # helm is only required if SN is in scope; deferred check happens in sn_deploy.
}

# ---------------------------------------------------------------------------
# Compute DRIVEN_TESTBEDS = victim's testbed + any testbed referenced by
# a non-synthetic aggressor. The orchestrator deploys + drives exactly
# these testbeds.
# ---------------------------------------------------------------------------
determine_used_testbeds() {
    DRIVEN_TESTBEDS=()
    while IFS= read -r tb; do
        [[ -z "$tb" ]] && continue
        # Confirm a loadgen entry exists for it; parse_config already
        # validated this for aggressor-referenced testbeds, so this is
        # belt-and-suspenders for the victim.
        if [[ -z "$(testbed_loadgen_json "$tb")" ]]; then
            die "testbed '$tb' is in scope but has no testbeds.$tb.loadgen entry"
        fi
        DRIVEN_TESTBEDS+=("$tb")
    done < <(driven_testbed_names)

    s3_log "Driven testbeds: ${DRIVEN_TESTBEDS[*]}"
}

# ---------------------------------------------------------------------------
# Pre-experiment node setup (MSR module load).
# ---------------------------------------------------------------------------
prep_victim_node() {
    s3_log "Loading msr kernel module on $TARGET_NODE (best-effort)"
    if declare -F ensure_msr_module_on_node >/dev/null 2>&1; then
        ensure_msr_module_on_node "$TARGET_NODE" "$EXP_DIR" || \
            s3_log "WARNING: ensure_msr_module_on_node failed; freq.ok will be false in samples"
    else
        s3_log "WARNING: ensure_msr_module_on_node not sourced; in-pod MSR reader may fail"
    fi
}

# ---------------------------------------------------------------------------
# Deploy every testbed in DRIVEN_TESTBEDS.
# ---------------------------------------------------------------------------
deploy_testbeds() {
    s3_log "Deploying ${#DRIVEN_TESTBEDS[@]} testbed(s)"
    local tb
    for tb in "${DRIVEN_TESTBEDS[@]}"; do
        case "$tb" in
            hotelReservation) hr_deploy "$EXP_DIR" || die "hr_deploy failed" ;;
            socialNetwork)    sn_deploy "$EXP_DIR" || die "sn_deploy failed" ;;
            sockshop)         ss_deploy "$EXP_DIR" || die "ss_deploy failed (see TODO_SOCKSHOP.md)" ;;
            *) die "unknown testbed '$tb'" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Deploy the victim: override image, set GORDION_SCORE_LOG, apply MSR
# cap, pin to TARGET_NODE. NodePort exposure is intentionally NOT done
# (no ghz; victim load comes via its testbed's wrk2 / frontend chain).
# ---------------------------------------------------------------------------
VICTIM_DEPLOYMENT=""
deploy_victim() {
    s3_log "Deploying victim '$VICTIM_SERVICE' with image $VICTIM_IMAGE"
    VICTIM_DEPLOYMENT=$(hr_deployment_for_service "$VICTIM_SERVICE") || die "unknown victim service: $VICTIM_SERVICE"

    local container_name="hotel-reserv-${VICTIM_SERVICE}"
    if declare -F get_container_name >/dev/null 2>&1; then
        container_name=$(get_container_name "$VICTIM_SERVICE")
    fi
    kubectl set image "deployment/$VICTIM_DEPLOYMENT" \
        "${container_name}=${VICTIM_IMAGE}" >/dev/null 2>&1 \
        || die "failed to set image for $VICTIM_DEPLOYMENT"

    kubectl set env "deployment/$VICTIM_DEPLOYMENT" \
        "GORDION_SCORE_LOG=$VICTIM_SCORE_LOG" >/dev/null 2>&1 \
        || s3_log "WARNING: failed to set GORDION_SCORE_LOG on $VICTIM_DEPLOYMENT"

    if declare -F apply_msr_pod_capabilities >/dev/null 2>&1; then
        apply_msr_pod_capabilities "$VICTIM_DEPLOYMENT" "$EXP_DIR" \
            || s3_log "WARNING: apply_msr_pod_capabilities failed; freq.ok will be false in samples"
    fi

    place_aggressor "default" "$VICTIM_DEPLOYMENT" "$TARGET_NODE" \
        || die "failed to pin victim to $TARGET_NODE"

    kubectl rollout restart "deployment/$VICTIM_DEPLOYMENT" >/dev/null 2>&1 || true
    kubectl rollout status  "deployment/$VICTIM_DEPLOYMENT" --timeout=180s \
        || die "victim rollout did not become Ready"
}

# ---------------------------------------------------------------------------
# Place aggressors. Each YAML entry maps to (namespace, deployment) and
# gets nodeSelector + toleration patched on. Synthetic entries skip
# this (launched per-run instead).
# ---------------------------------------------------------------------------
place_all_aggressors() {
    s3_log "Placing $AGGRESSOR_COUNT aggressor(s) on $TARGET_NODE"

    local i tb svc role ns deploy
    for ((i = 0; i < AGGRESSOR_COUNT; i++)); do
        role=$(aggressor_field "$i" '.role')
        tb=$(aggressor_field   "$i" '.testbed')
        svc=$(aggressor_field  "$i" '.service')
        ns=$(_resolve_ns "$tb")
        deploy=$(_resolve_deploy "$tb" "$svc") || die "aggressor[$i]: cannot resolve $tb/$svc"

        s3_log "  aggressor[$i] role=$role -> $ns/$deploy"
        place_aggressor "$ns" "$deploy" "$TARGET_NODE" \
            || die "place_aggressor failed for $ns/$deploy"
        # Aggressors run unlimited (no cpu/mem caps) at high priority. Recorded
        # in RUN_PLACED_AGGRESSORS below so the cleanup trap's unplace_aggressor
        # also unboosts. Victim placement (place_aggressor above) is deliberately
        # NOT boosted.
        boost_aggressor "$ns" "$deploy" \
            || die "boost_aggressor failed for $ns/$deploy"
        RUN_PLACED_AGGRESSORS+=("${ns}|${deploy}")
    done

    s3_log "Waiting for placed aggressors to be Ready (serial)"
    local entry
    for entry in "${RUN_PLACED_AGGRESSORS[@]:-}"; do
        ns="${entry%%|*}"
        deploy="${entry#*|}"
        if wait_aggressor_ready "$ns" "$deploy" 180; then
            s3_log "  $ns/$deploy rollout converged; aggressor active"
        else
            # `rollout status` timing out is commonly BENIGN: the new
            # nodeSelector'd pod is already Ready, but the prior replica is
            # still terminating (slow SIGTERM handler / default 30s grace),
            # which prevents `rollout status` from reporting full convergence.
            # Check readyReplicas so the log states whether the aggressor is
            # actually active rather than implying it failed.
            local ready
            ready=$(kubectl -n "$ns" get deployment "$deploy" \
                -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
            ready="${ready:-0}"
            if [[ "$ready" -ge 1 ]]; then
                s3_log "  NOTE: $ns/$deploy did not fully converge in 180s, but $ready replica(s) Ready (old replica still terminating) -- aggressor IS active; proceeding"
            else
                s3_log "  WARNING: $ns/$deploy has 0 Ready replicas after 180s -- aggressor is NOT active; this testbed's contention may be absent for the run; proceeding"
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# Heal Consul state after victim + aggressor rolls.
#
# Why: the orchestrator's deploy_victim + place_all_aggressors roll the
# search / geo / profile pods so they get new pod IPs. HR's grpc clients
# (frontend in particular, but also the chained services) use a Consul
# resolver. After Consul itself was ever rolled in this session, the
# resolver's watch is stuck in "bad resolver state" and never re-pulls
# fresh srv-* registrations. Symptom: 100 % non-2xx responses on wrk.
#
# Mitigation, ported from batch-perf's data-collector.sh. We can't call
# data-collector.sh's manual_register_all_services /
# validate_and_ensure_service_registration directly: those use
# `kubectl exec -it`, which SIGTTOUs when stage3-eval.sh is run with `&`
# (Phase 3 backgrounds it for the manual grpcurl subscribe). So we inline
# the SAME logic here, TTY-safe (plain `kubectl exec`, no -t):
#   1. clean_stale_consul_services       - sweep srv-* entries whose
#                                          backing pod IP no longer exists.
#   2. s3_consul_manual_register         - directly (re)register every
#                                          srv-* at its CURRENT pod IP with
#                                          a stable id=manual-<svc> and no
#                                          health check. This is the piece
#                                          that actually heals 'missing
#                                          srv-*': HR services self-register
#                                          only at startup, so a service
#                                          whose stale entry we just swept
#                                          (and whose pod we did NOT roll)
#                                          would otherwise never come back.
#   3. kubectl rollout restart frontend  - force the grpc client to
#                                          re-establish the resolver.
#   4. inline poll without -t            - wait until all expected srv-*
#                                          are in the catalog; if any are
#                                          still missing, one more register
#                                          pass before giving up.
#
# All three are best-effort: warnings, never die. If the cluster is
# already healthy (no stale entries, frontend resolver fine), this is
# essentially a no-op.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# s3_consul_manual_register
#
# TTY-safe port of batch-perf data-collector.sh::manual_register_all_services.
# Registers each HR srv-* into Consul at its CURRENT pod IP with a stable
# id=manual-<svc> and no health check (so Consul won't auto-deregister it).
# Idempotent: re-registering the same id just updates the address. Echoes
# nothing; logs progress. Best-effort -- never dies.
# ---------------------------------------------------------------------------
s3_consul_manual_register() {
    local consul_pod
    consul_pod=$(kubectl get pods -l io.kompose.service=consul \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$consul_pod" ]]; then
        s3_log "  WARNING: no Consul pod found; skipping manual registration"
        return 0
    fi

    # service_name : consul_name : port  (frontend does NOT register itself).
    local services=(
        "search:srv-search:8082"
        "geo:srv-geo:8083"
        "profile:srv-profile:8081"
        "rate:srv-rate:8084"
        "recommendation:srv-recommendation:8085"
        "reservation:srv-reservation:8087"
        "user:srv-user:8086"
    )
    local entry svc cname port ip count=0
    for entry in "${services[@]}"; do
        IFS=':' read -r svc cname port <<< "$entry"
        # Filter to Running pods: right after a roll, the label selector also
        # matches the terminating old replica (which has no podIP), and
        # items[0] ordering is not guaranteed -- without this we'd grab the
        # dead pod's empty IP and skip a service that actually needs
        # re-registering.
        ip=$(kubectl get pod -l io.kompose.service="$svc" \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
        if [[ -z "$ip" ]]; then
            s3_log "    skip $cname (no Running pod IP for '$svc')"
            continue
        fi
        if kubectl exec "$consul_pod" -- consul services register \
            -name="$cname" -port="$port" -address="$ip" -id="manual-$svc" \
            >> "$EXP_DIR/logs/stage3-eval.log" 2>&1; then
            ((count++))
        else
            s3_log "    WARNING: failed to register $cname at $ip:$port"
        fi
    done
    s3_log "  Manual registration: $count/${#services[@]} srv-* registered with current pod IPs"
}

# ---------------------------------------------------------------------------
# _s3_consul_count_registered  -> echoes "<registered> <missing...>"
# TTY-safe catalog read. Sets nothing; caller parses stdout.
# ---------------------------------------------------------------------------
_s3_consul_missing() {
    local expected_services=(srv-search srv-geo srv-profile srv-rate \
                             srv-recommendation srv-reservation srv-user)
    local svc_list expected missing=()
    svc_list=$(kubectl exec deployment/consul -- \
                consul catalog services 2>/dev/null \
                | tr -d '\r' | grep -E '^srv-' || true)
    for expected in "${expected_services[@]}"; do
        echo "$svc_list" | grep -qx "$expected" || missing+=("$expected")
    done
    echo "${missing[*]:-}"
}

recover_consul_state() {
    s3_log "Consul recovery: clean stale srv-* + re-register missing + bounce frontend"

    # 1. Sweep dead srv-* entries (TTY-safe; plain kubectl exec).
    if declare -F clean_stale_consul_services >/dev/null 2>&1; then
        clean_stale_consul_services "$EXP_DIR" \
            >> "$EXP_DIR/logs/stage3-eval.log" 2>&1 || true
    else
        s3_log "  WARNING: clean_stale_consul_services not available (data-collector.sh not sourced?)"
    fi

    # 2. Directly (re)register every srv-* at its current pod IP. This is the
    #    step the old recovery lacked -- swept-but-not-rolled services never
    #    self-register, so without this they stay missing.
    s3_consul_manual_register

    # 3. Bounce frontend so its grpc-consul resolver re-pulls the fresh set.
    s3_log "  Restarting frontend to refresh grpc-consul resolver"
    kubectl rollout restart deployment/frontend >/dev/null 2>&1 || true
    kubectl rollout status  deployment/frontend --timeout=120s >/dev/null 2>&1 \
        || s3_log "  WARNING: frontend rollout did not complete in 120s; proceeding"

    # 4. Poll the catalog; if anything is still missing after the window, do
    #    one more register pass before proceeding.
    local expected_total=7
    local max_wait=60 interval=5 elapsed=0
    local missing
    while (( elapsed < max_wait )); do
        missing=$(_s3_consul_missing)
        if [[ -z "$missing" ]]; then
            s3_log "  All ${expected_total} srv-* registered in Consul (${elapsed}s)"
            break
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done

    missing=$(_s3_consul_missing)
    if [[ -n "$missing" ]]; then
        s3_log "  Still missing after ${max_wait}s: $missing -- one more manual register pass"
        s3_consul_manual_register
        sleep 5
        missing=$(_s3_consul_missing)
    fi

    if [[ -n "$missing" ]]; then
        s3_log "  WARNING: srv-* still missing after recovery: $missing; proceeding anyway"
    fi

    s3_log "Consul recovery complete"
}

# _resolve_ns <testbed-name>     -> namespace
_resolve_ns() {
    case "$1" in
        hotelReservation) echo "$HR_NAMESPACE" ;;
        socialNetwork)    echo "$SN_NAMESPACE" ;;
        sockshop)         echo "$SS_NAMESPACE" ;;
        *) echo "" ;;
    esac
}

# _resolve_deploy <testbed-name> <service-name>  -> deployment name (per-testbed mapping)
_resolve_deploy() {
    case "$1" in
        hotelReservation) hr_deployment_for_service "$2" ;;
        socialNetwork)    sn_deployment_for_service "$2" ;;
        sockshop)         ss_deployment_for_service "$2" ;;
        *) echo ""; return 1 ;;
    esac
}

# _resolve_pod <testbed-name> <deployment-name>  -> live pod name
_resolve_pod() {
    case "$1" in
        hotelReservation) hr_pod_for_deployment "$2" ;;
        socialNetwork)    sn_pod_for_deployment "$2" ;;
        sockshop)         ss_pod_for_deployment "$2" ;;
        *) echo "" ;;
    esac
}

# _resolve_frontend_url <testbed-name>  -> http://...
_resolve_frontend_url() {
    case "$1" in
        hotelReservation) hr_frontend_url "$TARGET_NODE" ;;
        socialNetwork)    sn_frontend_url "$TARGET_NODE" ;;
        sockshop)         ss_frontend_url "$TARGET_NODE" ;;
        *) echo "" ; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Run one iteration: start drivers -> wait -> stop drivers -> manifest
# ---------------------------------------------------------------------------
run_one_iteration() {
    local run_id="$1"
    local run_dir="$EXP_DIR/runs/run_${run_id}"
    mkdir -p "$run_dir/wrk2"
    : > "$run_dir/orchestrator.log"

    RUN_WRK2_PIDFILES=()

    s3_log "------------------------------------------------------------"
    s3_log " Run $run_id / $EXPERIMENT_RUNS"
    s3_log "------------------------------------------------------------"

    local started_ns
    started_ns=$(date +%s%N)
    echo "$started_ns" > "$run_dir/started_epoch_ns.txt"

    # Start ONE wrk2 driver per in-scope testbed (background).
    start_testbed_drivers "$run_id" "$run_dir"

    # Block for the measurement window. wrk2 drivers run in background.
    s3_log "  Drivers active; sleeping ${EXPERIMENT_DURATION_S}s for measurement window"
    sleep "$EXPERIMENT_DURATION_S"

    local ended_ns
    ended_ns=$(date +%s%N)
    echo "$ended_ns" > "$run_dir/ended_epoch_ns.txt"

    # Stop wrk2 drivers (cleanly; SIGTERM with KILL fallback).
    local pf
    for pf in "${RUN_WRK2_PIDFILES[@]:-}"; do
        [[ -n "$pf" ]] && stop_wrk2_driver "$pf" || true
    done
    RUN_WRK2_PIDFILES=()

    # Persist the victim's score stream for this run window so it survives the
    # next run's pod roll (kubectl logs is lost on restart).
    capture_victim_score_log "$run_dir" "$started_ns"

    write_per_run_manifest "$run_id" "$run_dir" "$started_ns" "$ended_ns"

    s3_log "  Run $run_id complete ($(( (ended_ns - started_ns) / 1000000 )) ms)"
}

# ---------------------------------------------------------------------------
# capture_victim_score_log <run_dir> <started_ns>
#
# Dumps the victim's `score_event` zerolog lines for this run window into
# <run_dir>/score_events.log. Requires the run to have score_log=true (sets
# GORDION_SCORE_LOG=true so the in-binary LogSink writes one line per
# ScoreEvent). Best-effort: never dies, and writes a note instead of an
# empty file when scores aren't available.
# ---------------------------------------------------------------------------
capture_victim_score_log() {
    local run_dir="$1"
    local started_ns="$2"
    local out="$run_dir/score_events.log"

    if [[ "${VICTIM_SCORE_LOG:-false}" != "true" ]]; then
        s3_log "  Score capture skipped (victim.score_log=false). Live stream: grpcurl :7900 ContentionStream/Subscribe"
        echo "# score_log disabled for this run (victim.score_log=false)" > "$out"
        return 0
    fi

    # kubectl --since-time wants RFC3339 UTC; derive it from the run start.
    local since
    since=$(date -u -d "@$(( started_ns / 1000000000 ))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

    if [[ -n "$since" ]]; then
        kubectl logs "deployment/$VICTIM_DEPLOYMENT" --since-time="$since" 2>/dev/null \
            | grep 'score_event' > "$out" 2>/dev/null || true
    else
        # Fallback if date math failed: capture the whole window by duration.
        kubectl logs "deployment/$VICTIM_DEPLOYMENT" --since="$(( EXPERIMENT_DURATION_S + 10 ))s" 2>/dev/null \
            | grep 'score_event' > "$out" 2>/dev/null || true
    fi

    local n
    n=$(wc -l < "$out" 2>/dev/null | tr -d ' ')
    n="${n:-0}"
    if [[ "$n" -gt 0 ]]; then
        s3_log "  Captured $n score_event line(s) -> runs/run_$(basename "$run_dir" | sed 's/run_//')/score_events.log"
    else
        s3_log "  WARNING: 0 score_event lines captured (victim emitted none in window; check GORDION_SCORE_SOURCE/model wiring)"
    fi
}

# ---------------------------------------------------------------------------
# Start one wrk2 driver per in-scope testbed.
# ---------------------------------------------------------------------------
start_testbed_drivers() {
    local run_id="$1"
    local run_dir="$2"

    local tb rps shape url script pf out
    for tb in "${DRIVEN_TESTBEDS[@]}"; do
        rps=$(testbed_loadgen_rps "$tb")
        shape=$(testbed_loadgen_shape_json "$tb")
        out="$run_dir/wrk2/${tb}.txt"
        pf="$run_dir/wrk2/${tb}.pid"

        script=$(resolve_wrk2_script "$tb") || die "no wrk2 script for testbed $tb"
        url=$(_resolve_frontend_url "$tb")  || die "could not resolve frontend URL for $tb"

        # WRK2_FIXED_RPS is read by start_wrk2_driver for the "fixed" shape.
        WRK2_FIXED_RPS="$rps" start_wrk2_driver \
            "$tb" "$url" "$shape" "$EXPERIMENT_DURATION_S" "$out" "$pf" "$script" \
            || die "start_wrk2_driver failed for testbed $tb"
        RUN_WRK2_PIDFILES+=("$pf")
        s3_log "  driver: $tb rps=$rps shape=$shape url=$url"
    done
}

# ---------------------------------------------------------------------------
# Write the per_run.json manifest for this iteration.
# ---------------------------------------------------------------------------
write_per_run_manifest() {
    local run_id="$1"
    local run_dir="$2"
    local started_ns="$3"
    local ended_ns="$4"

    # Victim block (live pod resolution at run time).
    local victim_pod
    victim_pod=$(_resolve_pod "$VICTIM_TESTBED" "$VICTIM_DEPLOYMENT" 2>/dev/null || echo "")
    local victim_json
    victim_json=$(jq -n \
        --arg svc    "$VICTIM_SERVICE" \
        --arg image  "$VICTIM_IMAGE" \
        --arg pod    "$victim_pod" \
        --arg node   "$TARGET_NODE" \
        --arg tb     "$VICTIM_TESTBED" \
        --argjson sl "$([[ "$VICTIM_SCORE_LOG" == "true" ]] && echo true || echo false)" \
        '{ service:$svc, image:$image, pod:$pod, node:$node, testbed:$tb, score_log_enabled:$sl }')

    # Aggressors block (resolve live pod name per entry).
    local agg_tmp="$run_dir/.aggressors.tmp.json"
    echo "[]" > "$agg_tmp"
    local i tb svc role ns deploy pod entry
    for ((i = 0; i < AGGRESSOR_COUNT; i++)); do
        role=$(aggressor_field "$i" '.role')
        tb=$(aggressor_field   "$i" '.testbed')
        svc=$(aggressor_field  "$i" '.service')
        ns=$(_resolve_ns "$tb")
        deploy=$(_resolve_deploy "$tb" "$svc" 2>/dev/null || echo "")
        pod=$(_resolve_pod "$tb" "$deploy" 2>/dev/null || echo "")
        entry=$(jq -n \
            --arg tb "$tb" --arg svc "$svc" --arg role "$role" \
            --arg ns "$ns" --arg deploy "$deploy" --arg pod "$pod" \
            --arg node "$TARGET_NODE" \
            '{ testbed:$tb, service:$svc, role:$role,
               namespace:$ns, deployment:$deploy, pod:$pod, node:$node }')
        jq --argjson e "$entry" '. + [$e]' "$agg_tmp" > "${agg_tmp}.new" && mv "${agg_tmp}.new" "$agg_tmp"
    done

    # Testbed loadgens block (one entry per driven testbed; ground truth
    # for what wrk2 RPS / shape was in effect during this run).
    local tl_tmp="$run_dir/.testbed_loadgens.tmp.json"
    echo "{}" > "$tl_tmp"
    local tb_name
    for tb_name in "${DRIVEN_TESTBEDS[@]}"; do
        local lg
        lg=$(testbed_loadgen_json "$tb_name")
        jq --arg k "$tb_name" --argjson v "$lg" '. + {($k): $v}' "$tl_tmp" > "${tl_tmp}.new" \
            && mv "${tl_tmp}.new" "$tl_tmp"
    done

    # Artifacts block: per-testbed wrk2 output paths.
    local art_tmp="$run_dir/.artifacts.tmp.json"
    {
        echo '{'
        echo '  "wrk2_outputs": {'
        local first=true
        for tb_name in "${DRIVEN_TESTBEDS[@]}"; do
            [[ "$first" == "true" ]] && first=false || echo ','
            printf '    "%s": "runs/run_%s/wrk2/%s.txt"' "$tb_name" "$run_id" "$tb_name"
        done
        echo
        echo '  }'
        echo '}'
    } > "$art_tmp"

    write_run_manifest \
        "$(basename "$EXP_DIR")" \
        "$EXPERIMENT_NAME" \
        "$run_id" \
        "$run_dir" \
        "$EXP_DIR/input.yaml" \
        "$TARGET_NODE" \
        "$started_ns" \
        "$ended_ns" \
        "$victim_json" \
        "$agg_tmp" \
        "$art_tmp" \
        "$tl_tmp" \
        || s3_log "WARNING: write_run_manifest failed for run $run_id"

    rm -f "$agg_tmp" "$art_tmp" "$tl_tmp"
}

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
