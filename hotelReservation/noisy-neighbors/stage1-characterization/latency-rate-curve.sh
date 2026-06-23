#!/bin/bash
# ===========================================================================
# latency-rate-curve.sh
#
# Capture a latency-vs-arrival-rate curve for ONE HR service under NO
# contention, with the in-pod interceptor / windowed sampler ENABLED.
#
#   * direct gRPC load (ghz against the service's NodePort) -- NOT the e2e
#     wrk2 frontend loadgen;
#   * windowed instrumentation image deployed (ENABLE_WINDOWED_SAMPLING=true),
#     so each RPS level yields the interceptor's per-window samples;
#   * NO stressor / no contention -- this is the clean baseline curve.
#
# The curve's X-AXIS is the INTERCEPTOR-MEASURED arrival rate
# (timing_window.arrival_rps_1s), not ghz's send rate. ghz's numbers are
# kept only as secondary sanity columns.
#
# Design: per-RPS-level windowed run (see LATENCY-RATE-CURVE-PLAN.md). For
# each level we redeploy the victim with a fresh ITERATION_ID via
# update_iteration_id (one rollout, with the rollout-pause fix), drive ghz
# at that rate, wait for the sampler window to close, then retrieve one
# run_data_iter<level>.json and aggregate it into a curve row.
#
# Reuses helpers from step1-characterize.sh (ghz path, NodePort, payload,
# parsers, cleanup) and data-collector.sh (windowed deploy + retrieval),
# both pulled in by the single source line below.
#
# Usage (run from noisy-neighbors/):
#   ./stage1-characterization/latency-rate-curve.sh configs/curve-search.conf
# (The script anchors its CWD to noisy-neighbors/ itself, so it also works
#  when invoked from elsewhere; the config arg is resolved before the cd.)
#
# Output: experiment_data/curve_<svc>_<ts>/
#   curve.csv             one row per RPS level (plot latency vs arrival_rps_mean)
#   curve_summary.json    run-level metadata
#   saturation/           per-level ghz JSON
#   raw/windowed/<svc>/    per-level run_data_iter<level>.json
#   logs/                  step1.log + collector.log
# ===========================================================================

CURVE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sourcing step1-characterize.sh transitively sources data-collector.sh
# (which runs `set -e`) and contention-shapes.sh, and gives us every
# step1_* and data-collector helper. step1's own `main` is BASH_SOURCE
# guarded, so this does not run a characterization.
# shellcheck source=/dev/null
source "$CURVE_SCRIPTS_DIR/step1-characterize.sh"

# ---------------------------------------------------------------------------
# Per-level windowed-sample aggregator.
#
# Reads ONE filtered run_data_iter<level>.json and prints a single CSV
# fragment computed over the "active" windows (timing_window.request_count
# > 0), so the idle warmup that precedes ghz never dilutes the numbers:
#
#   arrival_rps_mean,arrival_rps_p50,arrival_rps_p99,
#   svc_mean_us,svc_p50_us,svc_p99_us,ipc,llc_mpki,
#   freq_mhz,freq_util_pct,active_windows,total_requests
#
# Arrival rate is the interceptor's trailing-1s sliding window
# (timing_window.arrival_rps_1s). Service time uses aggregates.timing_overall
# (a true pooled percentile over completed requests; warmup contributes none)
# with a window-weighted fallback. IPC/LLC-MPKI are summed from per-window
# perf_deltas over active windows.
# ===========================================================================
curve_aggregate_level() {
    python3 - "$1" <<'PYEOF'
import json, sys

def pct(xs, q):
    if not xs:
        return 0.0
    xs = sorted(xs)
    if len(xs) == 1:
        return float(xs[0])
    pos = (len(xs) - 1) * q
    lo = int(pos); hi = min(lo + 1, len(xs) - 1); frac = pos - lo
    return xs[lo] * (1 - frac) + xs[hi] * frac

def mean(xs):
    return (sum(xs) / len(xs)) if xs else 0.0

try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    # Emit a zero row so the sweep still records the level.
    print("0,0,0,0,0,0,0,0,0,0,0,0")
    sys.exit(0)

samples = d.get("samples") or []
active = [s for s in samples
          if s.get("timing_window") and (s["timing_window"].get("request_count") or 0) > 0]

arr = [(s["timing_window"].get("arrival_rps_1s") or 0.0) for s in active]

# Service time: prefer the binary's pooled aggregate; fall back to a
# request-weighted mean of per-window processing_time.
agg = (d.get("aggregates") or {}).get("timing_overall") or {}
def us(ns): return (ns or 0) / 1000.0
svc_mean = us(agg.get("mean_ns"))
svc_p50  = us(agg.get("p50_ns"))
svc_p99  = us(agg.get("p99_ns"))
if not agg and active:
    wsum = sum((s["timing_window"]["processing_time"].get("count") or 0) for s in active)
    if wsum:
        svc_mean = us(sum((s["timing_window"]["processing_time"].get("mean_ns") or 0) *
                          (s["timing_window"]["processing_time"].get("count") or 0)
                          for s in active) / wsum)
    svc_p50 = us(pct([s["timing_window"]["processing_time"].get("p50_ns") or 0 for s in active], 0.5))
    svc_p99 = us(pct([s["timing_window"]["processing_time"].get("p99_ns") or 0 for s in active], 0.99))

def perf_sum(key):
    return sum((s.get("perf_deltas") or {}).get(key, 0) for s in active)
instr = perf_sum("instructions")
cyc   = perf_sum("cycles")
llcm  = perf_sum("LLC-load-misses")
ipc      = (instr / cyc) if cyc else 0.0
llc_mpki = (llcm / instr * 1000.0) if instr else 0.0

fr = [s["freq"]["actual_freq_mhz"] for s in active if s.get("freq", {}).get("ok")]
fu = [s["freq"]["freq_util_pct"]   for s in active if s.get("freq", {}).get("ok")]
freq_mhz  = mean(fr)
freq_util = mean(fu)

total_req = sum((s["timing_window"].get("request_count") or 0) for s in active)

print("%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%.3f,%.2f,%.0f,%.1f,%d,%d" % (
    mean(arr), pct(arr, 0.5), pct(arr, 0.99),
    svc_mean, svc_p50, svc_p99, ipc, llc_mpki,
    freq_mhz, freq_util, len(active), total_req))
PYEOF
}

# ---------------------------------------------------------------------------
# Create the curve experiment directory + metadata.
# ---------------------------------------------------------------------------
curve_create_exp_dir() {
    local exp_id="curve_${OBSERVED_SERVICE}_$(date +%Y%m%d_%H%M%S)_$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')"
    local exp_dir="${CURVE_DATA_DIR:-./experiment_data}/$exp_id"
    mkdir -p "$exp_dir"/{logs,metadata,saturation} "$exp_dir/raw/windowed/$OBSERVED_SERVICE"

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " Instrumented latency-vs-arrival-rate curve"
    step1_log "$exp_dir" " Experiment: $EXPERIMENT_NAME"
    step1_log "$exp_dir" " ID: $exp_id"
    step1_log "$exp_dir" " Service: $OBSERVED_SERVICE   Node: $TARGET_NODE"
    step1_log "$exp_dir" "=========================================="

    cat > "$exp_dir/metadata/experiment.json" <<-EOJSON
	{
	    "experiment_id": "$exp_id",
	    "experiment_name": "$EXPERIMENT_NAME",
	    "experiment_type": "instrumented_latency_rate_curve",
	    "target_node": "$TARGET_NODE",
	    "observed_service": "$OBSERVED_SERVICE",
	    "contention": "none",
	    "loadgen": {
	        "tool": "ghz",
	        "method": "$LOADGEN_METHOD",
	        "transport": "direct_grpc_nodeport",
	        "loop_mode": "$([[ "${LOADGEN_ASYNC:-true}" == "true" ]] && echo open_loop_async || echo closed_loop_sync)"
	    },
	    "sweep": {
	        "start_rps": $SATURATION_START_RPS,
	        "step_rps": $SATURATION_STEP_RPS,
	        "max_rps": $SATURATION_MAX_RPS,
	        "ghz_duration_per_level_s": $SATURATION_DURATION,
	        "sampler_window_per_level_s": $((SATURATION_DURATION + CURVE_LEVEL_PAD)),
	        "force_full_sweep": $FORCE_FULL_SWEEP
	    },
	    "instrumentation": {
	        "interceptor": true,
	        "windowed_sampling": true,
	        "window_interval_ms": ${WINDOW_INTERVAL_MS},
	        "perf_events": "$PERF_EVENTS",
	        "x_axis": "interceptor arrival_rps_1s (NOT ghz send rate)"
	    },
	    "timestamp": "$(date -Iseconds)"
	}
	EOJSON

    echo "$exp_dir"
}

# ---------------------------------------------------------------------------
# Deploy the INSTRUMENTED victim (windowed image) + expose NodePort + payload.
# Mirrors step1_deploy but uses data-collector's deploy_timing_service
# (windowed) instead of the vanilla deploy_victim_services.
# ---------------------------------------------------------------------------
curve_deploy() {
    local exp_dir="$1"

    step1_log "$exp_dir" "Deploying INSTRUMENTED $OBSERVED_SERVICE (windowed image, no contention)"

    local all_deps
    all_deps=$(kubectl get deployments -n default \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)
    if [[ -n "$all_deps" ]]; then
        remove_anti_affinity "$all_deps" "$exp_dir"
        sleep 5
    fi

    # Reset every non-victim service to its default image; the victim is
    # deployed with the windowed/interceptor image by deploy_timing_service.
    reset_non_victim_services "" "$exp_dir"

    # Windowed deploy: canonical YAML + taskset pin + taint/toleration, then
    # windowed image + ENABLE_WINDOWED_SAMPLING + perf events + MSR caps,
    # applied under a single rollout (rollout-pause fix).
    if ! deploy_timing_service "$OBSERVED_SERVICE" "$TARGET_NODE" "$exp_dir"; then
        step1_log "$exp_dir" "ERROR: windowed deploy of $OBSERVED_SERVICE failed"
        exit 1
    fi

    step1_log "$exp_dir" "Waiting 30s for services to stabilize ..."
    sleep 30

    configure_jaeger_tracing "$exp_dir"

    step1_log "$exp_dir" "Validating readiness ..."
    if ! step1_validate_readiness "$exp_dir"; then
        step1_log "$exp_dir" "WARNING: validation failed — attempting Consul re-registration ..."
        manual_register_all_services "$exp_dir" 2>/dev/null || true
        sleep 15
        if ! step1_validate_readiness "$exp_dir"; then
            step1_log "$exp_dir" "ERROR: readiness failed after recovery. Aborting."
            exit 1
        fi
    fi
    step1_log "$exp_dir" "System ready"

    if ! step1_expose_nodeport "$OBSERVED_SERVICE" "$exp_dir"; then
        step1_log "$exp_dir" "ERROR: failed to expose $OBSERVED_SERVICE via NodePort"
        exit 1
    fi
    STEP1_EXPOSED_SERVICE="$OBSERVED_SERVICE"
    export STEP1_EXPOSED_SERVICE

    if ! step1_prepare_payload "$exp_dir"; then
        step1_log "$exp_dir" "ERROR: failed to prepare loadgen payload"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Run ONE RPS level: redeploy with a fresh sampler window, drive ghz, wait
# for the run_data file to be written, retrieve + aggregate it, and append a
# curve.csv row. Writes the level's saturation verdict to a sentinel file.
#
# Called as `if ! curve_run_level ...` so `set -e` is disabled inside (the
# same idiom step1 uses for its NodePort/poll helpers).
#
# Args: exp_dir level rps csv_file baseline_p99_var(name)
# ---------------------------------------------------------------------------
curve_run_level() {
    local exp_dir="$1" level="$2" rps="$3" csv_file="$4"
    local svc="$OBSERVED_SERVICE"
    local sweep_dir="$exp_dir/saturation"
    local sat_file="$sweep_dir/.last_saturated"
    echo "false" > "$sat_file"

    step1_log "$exp_dir" "=== Level $level: target ${rps} RPS ==="

    # Sampler window must comfortably bracket the warmup + ghz run. The
    # binary writes /data/run_data_*_iter<level>.json when this window
    # closes; we poll for it before retrieving.
    export EXPERIMENT_DURATION=$((SATURATION_DURATION + CURVE_LEVEL_PAD))

    # Fresh pod for this level (ITERATION_ID=level). update_iteration_id does
    # one paused rollout + a 15s stabilize sleep.
    update_iteration_id "$exp_dir" "$level" "$svc" "$EXPERIMENT_DURATION"
    sleep 3

    # Bracket the ghz traffic window so retrieve_windowed_run_data can filter
    # samples to exactly this level's steady state.
    local workload_start ghz_out iteration_end
    workload_start=$(date +%s)
    echo "$workload_start" > "$exp_dir/metadata/iteration_${level}_workload_start.txt"

    ghz_out="$sweep_dir/L${level}_rps${rps}.json"
    step1_run_ghz "$exp_dir" "$rps" "$SATURATION_DURATION" "$ghz_out"

    iteration_end=$(date +%s)
    echo "$iteration_end" > "$exp_dir/metadata/iteration_${level}_end.txt"

    # ghz-side (secondary) metrics
    local ghz_p99 ghz_p50 ghz_actual ghz_errors
    ghz_p99=$(step1_parse_ghz_p99 "$ghz_out")
    ghz_p50=$(step1_parse_ghz_p50 "$ghz_out")
    ghz_actual=$(step1_parse_ghz_actual_rps "$ghz_out")
    ghz_errors=$(step1_parse_ghz_errors "$ghz_out")
    : "${ghz_p99:=0}" "${ghz_p50:=0}" "${ghz_actual:=0}" "${ghz_errors:=0}"

    # Wait for the sampler window to close and write the run_data file.
    local run_file="/data/run_data_${svc}_iter${level}.json"
    local pod deadline=$((SECONDS + CURVE_FILE_POLL_TIMEOUT))
    step1_log "$exp_dir" "  Waiting for windowed run_data (timeout ${CURVE_FILE_POLL_TIMEOUT}s) ..."
    while :; do
        pod=$(kubectl get pods -l io.kompose.service="$svc" \
                -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$pod" ]] && kubectl exec "$pod" -- test -f "$run_file" 2>/dev/null; then
            step1_log "$exp_dir" "  run_data present in $pod"
            break
        fi
        if [[ $SECONDS -ge $deadline ]]; then
            step1_log "$exp_dir" "  WARNING: run_data not found before timeout; retrieving what exists"
            break
        fi
        sleep 3
    done

    retrieve_windowed_run_data "$svc" "$exp_dir" "$level" || \
        step1_log "$exp_dir" "  WARNING: retrieve_windowed_run_data returned non-zero"

    # Aggregate the filtered run_data into curve columns.
    local filtered="$exp_dir/raw/windowed/${svc}/run_data_iter${level}.json"
    local agg="0,0,0,0,0,0,0,0,0,0,0,0"
    if [[ -s "$filtered" ]]; then
        agg=$(curve_aggregate_level "$filtered" 2>/dev/null || echo "0,0,0,0,0,0,0,0,0,0,0,0")
    else
        step1_log "$exp_dir" "  WARNING: no filtered run_data at $filtered (zero row)"
    fi

    # ghz-based saturation verdict (same criteria as step1): p99 blow-up,
    # error rate, or actual-RPS shortfall. Used only to optionally stop early.
    local saturated=false err_rate="0.0000" total_req=0 p99_ratio="1.00"
    local base="${CURVE_BASELINE_P99:-}"
    if [[ -n "$base" && "$base" != "0" && "$ghz_p99" != "0" ]]; then
        p99_ratio=$(awk "BEGIN {printf \"%.2f\", $ghz_p99 / $base}")
    fi
    if [[ "$ghz_actual" != "0" ]]; then
        total_req=$(awk "BEGIN {printf \"%.0f\", $ghz_actual * $SATURATION_DURATION}")
        [[ "$total_req" != "0" ]] && err_rate=$(awk "BEGIN {printf \"%.4f\", ${ghz_errors:-0} / $total_req}")
    fi
    if [[ -n "$base" ]] && awk "BEGIN {exit !($p99_ratio >= $SATURATION_P99_THRESHOLD)}"; then saturated=true; fi
    if awk "BEGIN {exit !($err_rate >= $SATURATION_ERROR_RATE_THRESHOLD)}"; then saturated=true; fi
    if [[ "$ghz_actual" != "0" ]] && awk "BEGIN {exit !($ghz_actual < $rps * 0.85)}"; then saturated=true; fi

    # First healthy level establishes the ghz p99 baseline.
    if [[ -z "$base" && "$ghz_p99" != "0" && "$saturated" == "false" ]]; then
        export CURVE_BASELINE_P99="$ghz_p99"
        step1_log "$exp_dir" "  ghz baseline p99 = ${ghz_p99}ms"
    fi

    echo "$saturated" > "$sat_file"

    # curve.csv row: x-axis is arrival_rps_mean (first agg field).
    echo "${rps},${agg},${ghz_actual},${ghz_p50},${ghz_p99},${ghz_errors},${saturated}" >> "$csv_file"

    local arr_mean="${agg%%,*}"
    step1_log "$exp_dir" "  arrival_rps≈${arr_mean}  ghz_p99=${ghz_p99}ms  ghz_actual=${ghz_actual}  saturated=${saturated}"
    return 0
}

# ---------------------------------------------------------------------------
# Sweep all RPS levels and build curve.csv + curve_summary.json.
# ---------------------------------------------------------------------------
curve_sweep() {
    local exp_dir="$1"
    local sweep_dir="$exp_dir/saturation"
    local csv_file="$exp_dir/curve.csv"

    echo "target_rps,arrival_rps_mean,arrival_rps_p50,arrival_rps_p99,svc_mean_us,svc_p50_us,svc_p99_us,ipc,llc_mpki,freq_mhz,freq_util_pct,active_windows,total_requests,ghz_actual_rps,ghz_p50_ms,ghz_p99_ms,ghz_errors,saturated" > "$csv_file"

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " INSTRUMENTED SWEEP (no contention)"
    step1_log "$exp_dir" " RPS ${SATURATION_START_RPS}..${SATURATION_MAX_RPS} step ${SATURATION_STEP_RPS}"
    step1_log "$exp_dir" " ghz ${SATURATION_DURATION}s/level, sampler window $((SATURATION_DURATION + CURVE_LEVEL_PAD))s/level"
    step1_log "$exp_dir" " Early stop: $([[ "$FORCE_FULL_SWEEP" == "true" ]] && echo OFF || echo "after ${SATURATION_CONFIRM_LEVELS} consecutive saturated levels")"
    step1_log "$exp_dir" "=========================================="

    local rps=$SATURATION_START_RPS level=0 consec_sat=0
    while [[ $rps -le $SATURATION_MAX_RPS ]]; do
        level=$((level + 1))

        if ! curve_run_level "$exp_dir" "$level" "$rps" "$csv_file"; then
            step1_log "$exp_dir" "WARNING: level $level (rps=$rps) failed; continuing"
        fi

        local saturated="false"
        [[ -f "$sweep_dir/.last_saturated" ]] && saturated=$(cat "$sweep_dir/.last_saturated")

        if [[ "$saturated" == "true" ]]; then
            consec_sat=$((consec_sat + 1))
            if [[ "$FORCE_FULL_SWEEP" != "true" && $consec_sat -ge $SATURATION_CONFIRM_LEVELS ]]; then
                step1_log "$exp_dir" "Confirmed saturation (${consec_sat} consecutive) — stopping sweep at ${rps} RPS"
                break
            fi
        else
            consec_sat=0
        fi

        rps=$((rps + SATURATION_STEP_RPS))
        sleep 5
    done

    cat > "$exp_dir/curve_summary.json" <<-EOJSON
	{
	    "service": "$OBSERVED_SERVICE",
	    "levels_run": $level,
	    "rps_start": $SATURATION_START_RPS,
	    "rps_step": $SATURATION_STEP_RPS,
	    "rps_max": $SATURATION_MAX_RPS,
	    "ghz_duration_per_level_s": $SATURATION_DURATION,
	    "sampler_window_per_level_s": $((SATURATION_DURATION + CURVE_LEVEL_PAD)),
	    "ghz_baseline_p99_ms": ${CURVE_BASELINE_P99:-0},
	    "force_full_sweep": $FORCE_FULL_SWEEP,
	    "x_axis_column": "arrival_rps_mean",
	    "curve_csv": "curve.csv"
	}
	EOJSON

    step1_log "$exp_dir" "Curve written: $csv_file (${level} levels)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
curve_main() {
    if [[ $# -eq 0 ]]; then
        cat <<'USAGE'
Usage (run from noisy-neighbors/): ./stage1-characterization/latency-rate-curve.sh <config-file>

  Instrumented latency-vs-arrival-rate curve for ONE HR service, no
  contention, ghz direct-gRPC load, windowed/interceptor sampler ON.

  <config-file>  per-service config (e.g. configs/curve-search.conf).
                 Same shape as configs/step1-*.conf.

  Knobs (env or config):
    CURVE_LEVEL_PAD        seconds added to ghz duration for the sampler
                           window per level (default 30)
    FORCE_FULL_SWEEP       true|false -- if true, never stop early on
                           saturation (default false)
    CURVE_FILE_POLL_TIMEOUT  seconds to wait for the run_data file per
                           level (default 120)
    CURVE_DATA_DIR         output root (default ./experiment_data)

  X-axis of curve.csv is arrival_rps_mean (interceptor-measured), NOT ghz.
USAGE
        exit 1
    fi

    local config_file="$1"

    # Resolve the config path to absolute BEFORE changing directory.
    case "$config_file" in
        /*) : ;;
        *)  config_file="$(pwd)/$config_file" ;;
    esac

    # Anchor CWD to noisy-neighbors/ (parent of this script's dir) so the
    # project's CWD-relative paths (../services, ../kubernetes, ./loadgen,
    # ../../wrk2, ./experiment_data) resolve regardless of invocation dir.
    cd "$CURVE_SCRIPTS_DIR/.." || { echo "ERROR: cannot cd to noisy-neighbors dir" >&2; exit 1; }

    [[ -f "$SHAPES_SCRIPT" ]] && source "$SHAPES_SCRIPT"

    # Reuse step1's config loader + prechecks (ghz/proto/payload).
    step1_validate_config "$config_file"

    # --- Force the curve's invariants regardless of what the config says ---
    ENABLE_WINDOWED_SAMPLING="true"          # interceptor ON (the whole point)
    STRESSOR_TYPE="none"                     # no contention
    CONTENTION_BURSTS="none"
    NOISY_NEIGHBOR_TYPE="none"

    # Windowed-sampler env defaults consumed by update_deployment_for_timing /
    # apply_freq_util_env (only set if the config didn't).
    WINDOW_INTERVAL_MS="${WINDOW_INTERVAL_MS:-100}"
    TIMING_BUFFER_SIZE="${TIMING_BUFFER_SIZE:-16384}"
    TIMING_FLUSH_THRESHOLD="${TIMING_FLUSH_THRESHOLD:-80}"
    C0_ACTIVE_THRESHOLD="${C0_ACTIVE_THRESHOLD:-0.05}"
    MSR_TURBO_REFRESH_EVERY_S="${MSR_TURBO_REFRESH_EVERY_S:-10}"
    TSC_FREQ_MHZ="${TSC_FREQ_MHZ:-}"         # empty => in-pod auto from /proc/cpuinfo

    # Curve-specific knobs.
    CURVE_LEVEL_PAD="${CURVE_LEVEL_PAD:-30}"
    FORCE_FULL_SWEEP="${FORCE_FULL_SWEEP:-false}"
    CURVE_FILE_POLL_TIMEOUT="${CURVE_FILE_POLL_TIMEOUT:-120}"

    # step1_validate_config derives EXPERIMENT_DURATION from CHARACTERIZE_DURATION,
    # which the curve configs don't set. Give the initial windowed deploy a sane
    # sampler window (per-level runs reset this in curve_run_level anyway).
    EXPERIMENT_DURATION=$((SATURATION_DURATION + CURVE_LEVEL_PAD))

    export ENABLE_WINDOWED_SAMPLING STRESSOR_TYPE CONTENTION_BURSTS NOISY_NEIGHBOR_TYPE \
           WINDOW_INTERVAL_MS TIMING_BUFFER_SIZE TIMING_FLUSH_THRESHOLD \
           C0_ACTIVE_THRESHOLD MSR_TURBO_REFRESH_EVERY_S TSC_FREQ_MHZ EXPERIMENT_DURATION

    # Reuse step1's cleanup (reverts NodePort) on exit.
    trap step1_cleanup EXIT INT TERM

    local exp_dir
    exp_dir=$(curve_create_exp_dir)

    cleanup_existing_stress_pods "$exp_dir"

    curve_deploy "$exp_dir"
    curve_sweep "$exp_dir"

    step1_log "$exp_dir" ""
    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " CURVE COMPLETE"
    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" "Data directory : $exp_dir"
    step1_log "$exp_dir" "Curve CSV      : $exp_dir/curve.csv"

    echo ""
    echo "Latency-rate curve complete!"
    echo "Data:  $exp_dir"
    echo "Curve: $exp_dir/curve.csv   (x-axis: arrival_rps_mean)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    curve_main "$@"
fi
