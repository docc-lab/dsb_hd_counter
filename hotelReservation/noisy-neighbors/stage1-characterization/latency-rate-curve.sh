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
#     so the interceptor produces per-window samples;
#   * NO stressor / no contention -- this is the clean baseline curve.
#
# The curve's X-AXIS is the INTERCEPTOR-MEASURED arrival rate
# (timing_window.arrival_rps_1s), not ghz's send rate. ghz's numbers are
# kept only as secondary sanity columns.
#
# Design: ONE continuous sampler window covers the whole sweep (a single
# pod (re)start aligns it to the sweep start -- NOT one restart per level).
# Per RPS level we run a short warmup ghz (SATURATION_WARMUP, discarded),
# then a measured ghz (SATURATION_DURATION) whose wall-clock [start,end] we
# record, then an idle cooldown (SATURATION_COOLDOWN) to let the stateless
# service's transient queue drain before the next level. After the sweep we
# retrieve the single run_data once and slice its samples per level by the
# recorded offset bounds. The idle warmup/cooldown windows have
# request_count == 0, so the active-window filter drops them anyway.
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
#   saturation/levels.csv per-level ghz manifest + wall-clock bounds
#   raw/windowed/<svc>/    the single full-sweep run_data
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
# Per-level windowed-sample aggregator (shared with reslice-curve.sh).
# Slices the single full-sweep run_data to ONE level by absolute sample
# timestamp in [start_epoch,end_epoch] and prints a curve.csv fragment.
# See curve_aggregate.py for the column list and method.
# Args: run_data_json [start_epoch_s] [end_epoch_s]
# ---------------------------------------------------------------------------
curve_aggregate_level() {
    python3 "$CURVE_SCRIPTS_DIR/curve_aggregate.py" "$@"
}

# ---------------------------------------------------------------------------
# Optional CPU-frequency policy on the target node (intrinsic-curve mode).
#
# Knobs (env or config; all optional — when none are set this is a no-op and
# the sweep runs under whatever governor the node already has):
#   FREQ_GOVERNOR   cpufreq governor for the sweep (e.g. performance)
#   FREQ_MIN_MHZ    scaling_min_freq bound in MHz
#   FREQ_MAX_MHZ    scaling_max_freq bound in MHz
#   FREQ_SSH_HOST   ssh host for cpupower (default: $TARGET_NODE)
#
# Set FREQ_MIN_MHZ == FREQ_MAX_MHZ to PIN the clock: this removes both the
# schedutil idle down-clock (left-side latency fall) AND turbo excursions,
# which governor=performance alone does not (observed 2.4-3.0 GHz wander
# under performance on 2026-07-05). Applies to ALL cpus on the node (the
# node is dedicated to the victim during a sweep). The original governor and
# bounds are read from cpu0, recorded in metadata/freq_policy.json, and
# restored by the EXIT trap no matter how the run ends.
# ---------------------------------------------------------------------------
CURVE_FREQ_SAVED=false
CURVE_FREQ_ORIG_GOV=""
CURVE_FREQ_ORIG_MIN_KHZ=""
CURVE_FREQ_ORIG_MAX_KHZ=""

curve_freq_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 "${FREQ_SSH_HOST:-$TARGET_NODE}" "$@"
}

curve_apply_freq_policy() {
    local exp_dir="$1"
    [[ -z "${FREQ_GOVERNOR:-}${FREQ_MIN_MHZ:-}${FREQ_MAX_MHZ:-}" ]] && return 0

    local host="${FREQ_SSH_HOST:-$TARGET_NODE}"
    step1_log "$exp_dir" "Applying CPU freq policy on $host: governor=${FREQ_GOVERNOR:-<keep>} min=${FREQ_MIN_MHZ:-<keep>}MHz max=${FREQ_MAX_MHZ:-<keep>}MHz"

    # Save the original policy BEFORE touching anything; abort if unreadable
    # (no passwordless ssh/sudo) rather than leave the node half-configured.
    if ! CURVE_FREQ_ORIG_GOV=$(curve_freq_ssh cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null); then
        step1_log "$exp_dir" "ERROR: cannot read cpufreq state on $host (ssh/BatchMode?); aborting before modifying it"
        exit 1
    fi
    CURVE_FREQ_ORIG_MIN_KHZ=$(curve_freq_ssh cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq)
    CURVE_FREQ_ORIG_MAX_KHZ=$(curve_freq_ssh cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)
    CURVE_FREQ_SAVED=true

    # Single cpupower call (all CPUs); -d/-u/-g are each optional.
    if ! curve_freq_ssh sudo cpupower frequency-set \
            ${FREQ_GOVERNOR:+-g "$FREQ_GOVERNOR"} \
            ${FREQ_MIN_MHZ:+-d "${FREQ_MIN_MHZ}MHz"} \
            ${FREQ_MAX_MHZ:+-u "${FREQ_MAX_MHZ}MHz"} >/dev/null; then
        step1_log "$exp_dir" "ERROR: cpupower frequency-set failed on $host; restoring and aborting"
        curve_restore_freq_policy "$exp_dir"
        exit 1
    fi

    # Verify on a victim core (search is pinned to 18-20), not cpu0.
    local gov min max
    gov=$(curve_freq_ssh cat /sys/devices/system/cpu/cpu18/cpufreq/scaling_governor)
    min=$(curve_freq_ssh cat /sys/devices/system/cpu/cpu18/cpufreq/scaling_min_freq)
    max=$(curve_freq_ssh cat /sys/devices/system/cpu/cpu18/cpufreq/scaling_max_freq)
    step1_log "$exp_dir" "  cpu18 policy now: governor=$gov range=$((min/1000))-$((max/1000))MHz (was: $CURVE_FREQ_ORIG_GOV $((CURVE_FREQ_ORIG_MIN_KHZ/1000))-$((CURVE_FREQ_ORIG_MAX_KHZ/1000))MHz)"

    cat > "$exp_dir/metadata/freq_policy.json" <<-EOJSON
	{
	    "host": "$host",
	    "applied": {
	        "governor": "${FREQ_GOVERNOR:-}",
	        "min_mhz": "${FREQ_MIN_MHZ:-}",
	        "max_mhz": "${FREQ_MAX_MHZ:-}"
	    },
	    "verified_cpu18": {
	        "governor": "$gov",
	        "min_khz": $min,
	        "max_khz": $max
	    },
	    "original_cpu0": {
	        "governor": "$CURVE_FREQ_ORIG_GOV",
	        "min_khz": $CURVE_FREQ_ORIG_MIN_KHZ,
	        "max_khz": $CURVE_FREQ_ORIG_MAX_KHZ
	    },
	    "restored_on_exit": true
	}
	EOJSON
}

curve_restore_freq_policy() {
    local exp_dir="${1:-}"
    [[ "$CURVE_FREQ_SAVED" == "true" ]] || return 0
    local host="${FREQ_SSH_HOST:-$TARGET_NODE}"
    local msg="Restoring CPU freq policy on $host: governor=$CURVE_FREQ_ORIG_GOV range=$((CURVE_FREQ_ORIG_MIN_KHZ/1000))-$((CURVE_FREQ_ORIG_MAX_KHZ/1000))MHz"
    if [[ -n "$exp_dir" ]]; then step1_log "$exp_dir" "$msg"; else echo "[curve] $msg" >&2; fi
    if curve_freq_ssh sudo cpupower frequency-set \
            -g "$CURVE_FREQ_ORIG_GOV" \
            -d "${CURVE_FREQ_ORIG_MIN_KHZ}kHz" \
            -u "${CURVE_FREQ_ORIG_MAX_KHZ}kHz" >/dev/null; then
        CURVE_FREQ_SAVED=false
    else
        echo "[curve] WARNING: failed to restore cpufreq policy on $host — fix manually:" >&2
        echo "  ssh $host 'sudo cpupower frequency-set -g $CURVE_FREQ_ORIG_GOV -d ${CURVE_FREQ_ORIG_MIN_KHZ}kHz -u ${CURVE_FREQ_ORIG_MAX_KHZ}kHz'" >&2
    fi
}

curve_cleanup() {
    curve_restore_freq_policy
    step1_cleanup
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
	        "warmup_per_level_s": $SATURATION_WARMUP,
	        "measure_per_level_s": $SATURATION_DURATION,
	        "cooldown_per_level_s": $SATURATION_COOLDOWN,
	        "model": "single_continuous_window_no_per_level_restart"
	    },
	    "instrumentation": {
	        "interceptor": true,
	        "windowed_sampling": true,
	        "window_interval_ms": ${WINDOW_INTERVAL_MS},
	        "sampler_window_s": ${EXPERIMENT_DURATION},
	        "timing_buffer_size": ${TIMING_BUFFER_SIZE},
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

    reset_non_victim_services "" "$exp_dir"

    if ! deploy_timing_service "$OBSERVED_SERVICE" "$TARGET_NODE" "$exp_dir"; then
        step1_log "$exp_dir" "ERROR: windowed deploy of $OBSERVED_SERVICE failed"
        exit 1
    fi

    step1_log "$exp_dir" "Waiting 30s for services to stabilize ..."
    sleep 30

    configure_jaeger_tracing "$exp_dir"

    # Sweep dead srv-* entries from Consul before probing. Prior runs and the
    # windowed-image pod restarts leave stale registrations pointing at dead
    # pod IPs; the frontend then load-balances onto them and the readiness
    # probe flaps with HTTP 500, and search's downstream discovery (geo/rate)
    # can hit dead IPs. Reuses data-collector.sh's idempotent sweep.
    clean_stale_consul_services "$exp_dir"

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
# Run ONE RPS level against the already-running pod (NO restart):
#   warmup ghz (discarded) -> measured ghz (bounds recorded) -> idle cooldown.
# Appends a row to the level manifest. Windowed data is retrieved later, once.
#
# Called as `if ! curve_run_level ...` so `set -e` is disabled inside.
# Args: exp_dir level rps manifest_file
# ---------------------------------------------------------------------------
curve_run_level() {
    local exp_dir="$1" level="$2" rps="$3" manifest="$4"
    local sweep_dir="$exp_dir/saturation"

    step1_log "$exp_dir" "=== Level $level: target ${rps} RPS ==="

    # Warmup (discarded): warms JIT/caches/connection pools at this rate
    # before the measured window. Its traffic is sampled but lies outside the
    # [measure_start,measure_end] slice we record below.
    if [[ "${SATURATION_WARMUP:-0}" -gt 0 ]]; then
        step1_log "$exp_dir" "  warmup ${SATURATION_WARMUP}s @ ${rps} RPS"
        step1_run_ghz "$exp_dir" "$rps" "$SATURATION_WARMUP" "$sweep_dir/L${level}_warmup.json"
    fi

    local measure_start measure_end ghz_out
    measure_start=$(date +%s)
    ghz_out="$sweep_dir/L${level}_rps${rps}.json"
    step1_run_ghz "$exp_dir" "$rps" "$SATURATION_DURATION" "$ghz_out"
    measure_end=$(date +%s)

    # Cooldown: let the stateless service's in-flight backlog drain before the
    # next level so a saturated level doesn't contaminate the next warmup.
    if [[ "${SATURATION_COOLDOWN:-0}" -gt 0 ]]; then
        step1_log "$exp_dir" "  cooldown ${SATURATION_COOLDOWN}s (idle drain)"
        sleep "$SATURATION_COOLDOWN"
    fi

    local ghz_p99 ghz_p50 ghz_actual ghz_errors
    ghz_p99=$(step1_parse_ghz_p99 "$ghz_out")
    ghz_p50=$(step1_parse_ghz_p50 "$ghz_out")
    ghz_actual=$(step1_parse_ghz_actual_rps "$ghz_out")
    ghz_errors=$(step1_parse_ghz_errors "$ghz_out")
    : "${ghz_p99:=0}" "${ghz_p50:=0}" "${ghz_actual:=0}" "${ghz_errors:=0}"

    # Annotation-only saturation verdict (ghz side); does NOT stop the sweep.
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
    if [[ -z "$base" && "$ghz_p99" != "0" && "$saturated" == "false" ]]; then
        export CURVE_BASELINE_P99="$ghz_p99"
        step1_log "$exp_dir" "  ghz baseline p99 = ${ghz_p99}ms"
    fi

    echo "${level},${rps},${measure_start},${measure_end},${ghz_actual},${ghz_p50},${ghz_p99},${ghz_errors},${saturated}" >> "$manifest"
    step1_log "$exp_dir" "  measured [${measure_start},${measure_end}] ghz_p99=${ghz_p99}ms ghz_actual=${ghz_actual} saturated=${saturated}"
    return 0
}

# ---------------------------------------------------------------------------
# Emit the ordered list of RPS levels for the sweep (one per line).
#
# When SATURATION_SEGMENTS is set it takes precedence: whitespace-separated
# "lo-hi:step" tokens expanded left-to-right, giving a variable step across the
# range (coarse far from the knee, progressively finer through it). Boundary
# duplicates between adjacent segments are dropped while preserving order.
# Otherwise fall back to the fixed START/STEP/MAX arithmetic (unchanged
# default used by curve-profile.conf and any other caller).
# ---------------------------------------------------------------------------
curve_expand_levels() {
    if [[ -n "${SATURATION_SEGMENTS:-}" ]]; then
        local seg lo rest hi step r
        for seg in $SATURATION_SEGMENTS; do
            lo=${seg%%-*}; rest=${seg#*-}; hi=${rest%%:*}; step=${rest##*:}
            # Skip malformed tokens rather than looping forever on step<=0.
            [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ && "$step" =~ ^[0-9]+$ ]] || continue
            (( step < 1 )) && continue
            for ((r=lo; r<=hi; r+=step)); do echo "$r"; done
        done | awk '!seen[$0]++'
    else
        local r
        for ((r=SATURATION_START_RPS; r<=SATURATION_MAX_RPS; r+=SATURATION_STEP_RPS)); do
            echo "$r"
        done
    fi
}

# ---------------------------------------------------------------------------
# Sweep all RPS levels under ONE sampler window, then retrieve the single
# run_data and slice it per level into curve.csv.
# ---------------------------------------------------------------------------
curve_sweep() {
    local exp_dir="$1"
    local svc="$OBSERVED_SERVICE"
    local sweep_dir="$exp_dir/saturation"
    local manifest="$sweep_dir/levels.csv"
    local csv_file="$exp_dir/curve.csv"

    echo "level,target_rps,measure_start,measure_end,ghz_actual,ghz_p50,ghz_p99,ghz_errors,saturated" > "$manifest"

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " INSTRUMENTED SWEEP (no contention, single window, no per-level restart)"
    if [[ -n "${SATURATION_SEGMENTS:-}" ]]; then
        step1_log "$exp_dir" " RPS segments: ${SATURATION_SEGMENTS}"
    else
        step1_log "$exp_dir" " RPS ${SATURATION_START_RPS}..${SATURATION_MAX_RPS} step ${SATURATION_STEP_RPS}"
    fi
    step1_log "$exp_dir" " per level: warmup ${SATURATION_WARMUP}s / measure ${SATURATION_DURATION}s / cooldown ${SATURATION_COOLDOWN}s"
    step1_log "$exp_dir" " sampler window: ${EXPERIMENT_DURATION}s   ring buffer: ${TIMING_BUFFER_SIZE}"
    step1_log "$exp_dir" "=========================================="

    # Start ONE measurement window aligned to the sweep: a single pod restart
    # (ITERATION_ID=1) with EXPERIMENT_DURATION covering the whole sweep.
    step1_log "$exp_dir" "Starting single sampler window (one restart) ..."
    update_iteration_id "$exp_dir" 1 "$svc" "$EXPERIMENT_DURATION"
    # That restart orphaned the previous search pod's Consul entry; sweep
    # stale srv-* so downstream discovery and any frontend-routed probe see
    # only live IPs for the whole sweep.
    clean_stale_consul_services "$exp_dir"
    local window_start; window_start=$(date +%s)

    local rps level=0
    while read -r rps; do
        [[ -z "$rps" ]] && continue
        level=$((level + 1))
        if ! curve_run_level "$exp_dir" "$level" "$rps" "$manifest"; then
            step1_log "$exp_dir" "WARNING: level $level (rps=$rps) failed; continuing"
        fi
    done < <(curve_expand_levels)

    # The in-pod sampler runs in CONTINUOUS mode (SetupContinuousSampling
    # hard-overrides RunDuration to 24h; EXPERIMENT_DURATION does NOT bound
    # the window) and its streamMode periodicFlushLoop rewrites /data/run_data
    # every 30s with all samples so far. The file therefore exists ~30s after
    # pod start and is only as fresh as the LAST flush -- retrieving right at
    # sweep end can silently drop up to 30s (the final level's tail). Sleep
    # one full flush period so the flush covering the last level is on disk,
    # then retrieve the newest flush.
    local run_file="/data/run_data_${svc}_iter1.json"
    local raw="$exp_dir/raw/windowed/${svc}/run_data_full_raw.json"
    step1_log "$exp_dir" "Sweep traffic done (${level} levels). Waiting 35s for the sampler's next periodic flush, then retrieving ..."
    sleep 35
    local deadline=$(( SECONDS + CURVE_FILE_POLL_TIMEOUT ))
    local pod
    while :; do
        pod=$(kubectl get pods -l io.kompose.service="$svc" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$pod" ]] && kubectl exec "$pod" -- test -f "$run_file" 2>/dev/null; then
            break
        fi
        if [[ $SECONDS -ge $deadline ]]; then
            step1_log "$exp_dir" "WARNING: run_data not found before timeout; curve may be empty"
            break
        fi
        sleep 5
    done
    # Retrieve with validation + retry: the sampler's periodicFlushLoop
    # rewrites run_data IN PLACE every 30s (os.Create truncates the file
    # before the rewrite), so a cat racing a rewrite reads a truncated or
    # empty file (observed: zero-byte reads, "Unterminated string" ~29MB in).
    # Retry until the payload parses as JSON; 6 x 7s covers >1 flush cycle.
    local attempt retrieved=false
    for attempt in 1 2 3 4 5 6; do
        kubectl exec "$pod" -- cat "$run_file" > "$raw" 2>/dev/null || true
        if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$raw" 2>/dev/null; then
            retrieved=true
            break
        fi
        step1_log "$exp_dir" "  run_data truncated/incomplete (attempt $attempt); retrying in 7s"
        sleep 7
    done
    [[ "$retrieved" == "true" ]] || \
        step1_log "$exp_dir" "WARNING: run_data still invalid after $attempt attempts; curve build will likely fail (reslice-curve.sh can rebuild after a manual re-cat)"
    step1_log "$exp_dir" "Building curve.csv from run_data in one pass (curve_aggregate.py --build)"

    # Single-pass build: loads run_data once, slices every level by its
    # measured [start,end] epoch (from the manifest), and pulls ghz_p90 from
    # each level's saved ghz JSON. Same code path as reslice-curve.sh.
    python3 "$CURVE_SCRIPTS_DIR/curve_aggregate.py" --build "$exp_dir" \
        || step1_log "$exp_dir" "WARNING: curve build failed"

    cat > "$exp_dir/curve_summary.json" <<-EOJSON
	{
	    "service": "$svc",
	    "levels_run": $level,
	    "rps_start": $SATURATION_START_RPS,
	    "rps_step": $SATURATION_STEP_RPS,
	    "rps_max": $SATURATION_MAX_RPS,
	    "warmup_per_level_s": $SATURATION_WARMUP,
	    "measure_per_level_s": $SATURATION_DURATION,
	    "cooldown_per_level_s": $SATURATION_COOLDOWN,
	    "sampler_window_s": $EXPERIMENT_DURATION,
	    "timing_buffer_size": $TIMING_BUFFER_SIZE,
	    "ghz_baseline_p99_ms": ${CURVE_BASELINE_P99:-0},
	    "x_axis_column": "arrival_rps_mean",
	    "curve_csv": "curve.csv"
	}
	EOJSON

    step1_log "$exp_dir" "Curve written: $csv_file (${level} levels)"
}

# ---------------------------------------------------------------------------
# Compute the single-window EXPERIMENT_DURATION + a ring buffer big enough to
# hold the whole sweep without a mid-run flush (so the run_data file is
# written once, complete, at window close).
# ---------------------------------------------------------------------------
curve_size_window() {
    local n_levels per_level pre_settle sweep_est needed min_buf buf
    # Count the exact level list (honours SATURATION_SEGMENTS when set) so the
    # single sampler window + ring buffer size correctly for a variable step.
    n_levels=$(curve_expand_levels | grep -c .)
    [[ $n_levels -lt 1 ]] && n_levels=1
    # +10s/level slack for ghz spin-up + parsing between phases
    per_level=$(( SATURATION_WARMUP + SATURATION_DURATION + SATURATION_COOLDOWN + 10 ))
    # The sampler window starts at pod start, but the windowed-image rollout
    # (image pull + taskset + MSR patches + readiness) plus update_iteration_id's
    # 15s stabilize burn a chunk of the window before level 1. Under-counting
    # this clips the LAST level (observed: row N truncated). Budget generously.
    pre_settle=90                          # windowed pod rollout-to-ready + 15s stabilize
    sweep_est=$(( pre_settle + n_levels * per_level ))
    # window = estimate + user margin + 20% safety
    EXPERIMENT_DURATION=$(( sweep_est + CURVE_WINDOW_MARGIN + sweep_est / 5 ))

    # Ring buffer must hold every 100ms window with headroom so the 80%
    # flush threshold isn't crossed mid-run. samples = window / interval.
    needed=$(( EXPERIMENT_DURATION * 1000 / WINDOW_INTERVAL_MS ))
    min_buf=$(( needed * 100 / 70 ))       # /0.70 headroom below the 80% flush
    buf=1024
    while [[ $buf -lt $min_buf ]]; do buf=$(( buf * 2 )); done
    [[ $buf -gt $TIMING_BUFFER_SIZE ]] && TIMING_BUFFER_SIZE=$buf

    export EXPERIMENT_DURATION TIMING_BUFFER_SIZE
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
  ONE continuous sampler window for the whole sweep (no per-level restart);
  the stateless service's queue is drained by the per-level cooldown.

  <config-file>  per-service config (e.g. configs/curve-search.conf).

  Knobs (env or config):
    SATURATION_WARMUP        per-level warmup ghz seconds, discarded (default 5)
    SATURATION_DURATION      per-level measured ghz seconds (default 30)
    SATURATION_COOLDOWN      per-level idle drain seconds (default 15)
    CURVE_WINDOW_MARGIN      extra seconds added to the computed sampler
                             window (safety; default 30)
    CURVE_FILE_POLL_TIMEOUT  extra seconds to wait for the run_data file at
                             window close (default 120)
    CURVE_DATA_DIR           output root (default ./experiment_data)
    FREQ_GOVERNOR            cpufreq governor on the target node for the sweep
                             (e.g. performance); original restored on exit
    FREQ_MIN_MHZ/FREQ_MAX_MHZ  bound the clock; set equal to PIN it (intrinsic
                             curve with no DVFS / turbo variation)
    FREQ_SSH_HOST            ssh host for cpupower (default: TARGET_NODE)

  X-axis of curve.csv is arrival_rps_mean (interceptor-measured), NOT ghz.
USAGE
        exit 1
    fi

    local config_file="$1"

    case "$config_file" in
        /*) : ;;
        *)  config_file="$(pwd)/$config_file" ;;
    esac
    cd "$CURVE_SCRIPTS_DIR/.." || { echo "ERROR: cannot cd to noisy-neighbors dir" >&2; exit 1; }

    [[ -f "$SHAPES_SCRIPT" ]] && source "$SHAPES_SCRIPT"

    step1_validate_config "$config_file"

    # --- Force the curve's invariants regardless of the config ---
    ENABLE_WINDOWED_SAMPLING="true"
    STRESSOR_TYPE="none"
    CONTENTION_BURSTS="none"
    NOISY_NEIGHBOR_TYPE="none"

    WINDOW_INTERVAL_MS="${WINDOW_INTERVAL_MS:-100}"
    TIMING_BUFFER_SIZE="${TIMING_BUFFER_SIZE:-16384}"
    TIMING_FLUSH_THRESHOLD="${TIMING_FLUSH_THRESHOLD:-80}"
    C0_ACTIVE_THRESHOLD="${C0_ACTIVE_THRESHOLD:-0.05}"
    MSR_TURBO_REFRESH_EVERY_S="${MSR_TURBO_REFRESH_EVERY_S:-10}"
    TSC_FREQ_MHZ="${TSC_FREQ_MHZ:-}"

    SATURATION_WARMUP="${SATURATION_WARMUP:-5}"
    SATURATION_COOLDOWN="${SATURATION_COOLDOWN:-15}"
    CURVE_WINDOW_MARGIN="${CURVE_WINDOW_MARGIN:-30}"
    CURVE_FILE_POLL_TIMEOUT="${CURVE_FILE_POLL_TIMEOUT:-120}"

    # Size the single sampler window + ring buffer for the whole sweep.
    curve_size_window
    local win_min=$(( EXPERIMENT_DURATION / 60 ))
    echo "[curve] single sampler window = ${EXPERIMENT_DURATION}s (~${win_min} min), ring buffer = ${TIMING_BUFFER_SIZE}" >&2
    if [[ $EXPERIMENT_DURATION -gt 3600 ]]; then
        echo "[curve] WARNING: sampler window > 1h; consider a smaller RPS range or shorter per-level phases." >&2
    fi

    export ENABLE_WINDOWED_SAMPLING STRESSOR_TYPE CONTENTION_BURSTS NOISY_NEIGHBOR_TYPE \
           WINDOW_INTERVAL_MS TIMING_BUFFER_SIZE TIMING_FLUSH_THRESHOLD \
           C0_ACTIVE_THRESHOLD MSR_TURBO_REFRESH_EVERY_S TSC_FREQ_MHZ \
           SATURATION_WARMUP SATURATION_COOLDOWN

    trap curve_cleanup EXIT INT TERM

    local exp_dir
    exp_dir=$(curve_create_exp_dir)

    cleanup_existing_stress_pods "$exp_dir"

    curve_apply_freq_policy "$exp_dir"

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
