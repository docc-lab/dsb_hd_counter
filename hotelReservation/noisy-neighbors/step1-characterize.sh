#!/bin/bash
# ===========================================================================
# Step 1: Workload Characterization Without Stressor
# Part of Hardware Counter Justification Plan
#
# Two stages:
#   Stage 1 — Saturation Test: sweep RPS to find the knee point
#   Stage 2 — Characterization: run at 90% knee-point RPS, collect
#             perf counters (in-process), CPU/mem/net (external), latency
#
# Usage: ./step1-characterize.sh <config-file>
# ===========================================================================

set -e
set -o pipefail

STEP1_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source data-collector.sh for shared utility functions
# (deploy_victim_services, validate_system_readiness, etc.)
source "$STEP1_SCRIPTS_DIR/data-collector.sh"

# ===========================================================================
# Default configuration (overridable via config file)
# ===========================================================================

# Saturation sweep
SATURATION_START_RPS="${SATURATION_START_RPS:-50}"
SATURATION_STEP_RPS="${SATURATION_STEP_RPS:-50}"
SATURATION_MAX_RPS="${SATURATION_MAX_RPS:-2000}"
SATURATION_DURATION="${SATURATION_DURATION:-30}"
SATURATION_WARMUP="${SATURATION_WARMUP:-10}"
# Knee-point declared when p99 >= this multiplier of the baseline p99
SATURATION_P99_THRESHOLD="${SATURATION_P99_THRESHOLD:-2.0}"

# Characterization
CHARACTERIZE_DURATION="${CHARACTERIZE_DURATION:-300}"   # 5 min
CHARACTERIZE_RUNS="${CHARACTERIZE_RUNS:-5}"
CHARACTERIZE_KNEE_FRACTION="${CHARACTERIZE_KNEE_FRACTION:-0.9}"  # 90 %

# ===========================================================================
# Logging
# ===========================================================================

step1_log() {
    local exp_dir="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [step1] $*"
    echo "$msg" >&2
    [[ -d "$exp_dir/logs" ]] && echo "$msg" >> "$exp_dir/logs/step1.log"
}

# ===========================================================================
# wrk2 output helpers
# ===========================================================================

step1_parse_wrk2_p99() {
    local file="$1"
    grep -E '^\s+99\.000%' "$file" 2>/dev/null | head -1 | awk '{
        v = $2
        if      (v ~ /ms$/) { gsub(/ms$/, "", v); printf "%.2f", v }
        else if (v ~ /us$/) { gsub(/us$/, "", v); printf "%.2f", v/1000 }
        else if (v ~ /s$/)  { gsub(/s$/,  "", v); printf "%.2f", v*1000 }
        else                 { printf "%.2f", v }
    }'
}

step1_parse_wrk2_p50() {
    local file="$1"
    grep -E '^\s+50\.000%' "$file" 2>/dev/null | head -1 | awk '{
        v = $2
        if      (v ~ /ms$/) { gsub(/ms$/, "", v); printf "%.2f", v }
        else if (v ~ /us$/) { gsub(/us$/, "", v); printf "%.2f", v/1000 }
        else if (v ~ /s$/)  { gsub(/s$/,  "", v); printf "%.2f", v*1000 }
        else                 { printf "%.2f", v }
    }'
}

step1_parse_wrk2_mean() {
    local file="$1"
    grep -E '^\s+#\[Mean' "$file" 2>/dev/null | head -1 | awk -F'[=,]' '{
        gsub(/ /, "", $2); printf "%.2f", $2/1000
    }'
}

step1_parse_wrk2_actual_rps() {
    local file="$1"
    grep 'Requests/sec:' "$file" 2>/dev/null | awk '{print $2}' | head -1
}

step1_parse_wrk2_errors() {
    local file="$1"
    local non2xx
    non2xx=$(grep -i 'Non-2xx' "$file" 2>/dev/null | awk '{print $NF}')
    echo "${non2xx:-0}"
}

# ===========================================================================
# Stage 1 — Saturation Sweep
# ===========================================================================

step1_run_wrk2() {
    local exp_dir="$1" rps="$2" duration="$3" output="$4"

    local url="http://${WRK2_TARGET_IP}:${WRK2_TARGET_PORT}"
    local cmd="$WRK2_DIR/wrk -D exp -t ${WRK2_THREADS:-2} -c ${WRK2_CONNECTIONS:-2}"
    cmd="$cmd -d ${duration}s -L -R $rps"

    if [[ -n "${WRK2_SCRIPT:-}" && -f "${WRK2_SCRIPT}" ]]; then
        cmd="$cmd -s $WRK2_SCRIPT"
    fi
    cmd="$cmd $url"

    step1_log "$exp_dir" "  wrk2: $cmd"
    eval "$cmd" > "$output" 2>&1 || true
}

step1_saturation_sweep() {
    local exp_dir="$1"
    local sweep_dir="$exp_dir/saturation"
    mkdir -p "$sweep_dir"

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " STAGE 1: SATURATION SWEEP"
    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" "RPS range: ${SATURATION_START_RPS}–${SATURATION_MAX_RPS}  step=${SATURATION_STEP_RPS}"
    step1_log "$exp_dir" "Duration per level: ${SATURATION_DURATION}s   p99 threshold: ${SATURATION_P99_THRESHOLD}x"

    local baseline_p99="" knee_rps="" prev_rps="" prev_p99=""
    local rps=$SATURATION_START_RPS level=0

    echo "level,target_rps,actual_rps,p99_ms,p50_ms,p99_ratio,errors" \
        > "$sweep_dir/sweep_results.csv"

    # Warmup
    step1_log "$exp_dir" "Warmup at ${rps} RPS for ${SATURATION_WARMUP}s ..."
    step1_run_wrk2 "$exp_dir" "$rps" "$SATURATION_WARMUP" "$sweep_dir/warmup.txt"
    sleep 5

    while [[ $rps -le $SATURATION_MAX_RPS ]]; do
        ((level++))
        local out="$sweep_dir/level_${level}_rps${rps}.txt"

        step1_log "$exp_dir" "--- Level $level: ${rps} RPS ---"
        step1_run_wrk2 "$exp_dir" "$rps" "$SATURATION_DURATION" "$out"

        local p99  p50  actual errors p99_ratio
        p99=$(step1_parse_wrk2_p99 "$out")
        p50=$(step1_parse_wrk2_p50 "$out")
        actual=$(step1_parse_wrk2_actual_rps "$out")
        errors=$(step1_parse_wrk2_errors "$out")

        if [[ -z "$p99" || "$p99" == "0" || "$p99" == "0.00" ]]; then
            step1_log "$exp_dir" "  WARNING: could not parse p99 — treating as saturated"
            knee_rps="${prev_rps:-$rps}"
            break
        fi

        [[ -z "$baseline_p99" ]] && baseline_p99="$p99" \
            && step1_log "$exp_dir" "  Baseline p99: ${baseline_p99}ms"

        p99_ratio=$(awk "BEGIN {printf \"%.2f\", $p99 / $baseline_p99}")

        step1_log "$exp_dir" "  p99=${p99}ms  p50=${p50}ms  actual_rps=${actual}  errors=${errors}  p99_ratio=${p99_ratio}x"
        echo "$level,$rps,$actual,$p99,$p50,$p99_ratio,$errors" >> "$sweep_dir/sweep_results.csv"

        # ---- Saturation checks ----
        local saturated=false

        if awk "BEGIN {exit !($p99_ratio >= $SATURATION_P99_THRESHOLD)}" 2>/dev/null; then
            step1_log "$exp_dir" "  SATURATED: p99 ratio ${p99_ratio}x >= ${SATURATION_P99_THRESHOLD}x"
            saturated=true
        fi
        if [[ "${errors:-0}" -gt 0 ]]; then
            step1_log "$exp_dir" "  SATURATED: ${errors} non-2xx responses"
            saturated=true
        fi
        if [[ -n "$actual" ]] && awk "BEGIN {exit !($actual < $rps * 0.85)}" 2>/dev/null; then
            step1_log "$exp_dir" "  SATURATED: actual RPS ${actual} << target ${rps}"
            saturated=true
        fi

        if [[ "$saturated" == "true" ]]; then
            knee_rps="${prev_rps:-$rps}"
            break
        fi

        prev_rps="$rps"; prev_p99="$p99"
        rps=$((rps + SATURATION_STEP_RPS))
        sleep 5   # cool-down between levels
    done

    [[ -z "$knee_rps" ]] && knee_rps="$SATURATION_MAX_RPS" \
        && step1_log "$exp_dir" "WARNING: reached max RPS without saturation"

    local char_rps
    char_rps=$(awk "BEGIN {printf \"%.0f\", $knee_rps * $CHARACTERIZE_KNEE_FRACTION}")

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " Knee point      : ${knee_rps} RPS"
    step1_log "$exp_dir" " Characterize at : ${char_rps} RPS (${CHARACTERIZE_KNEE_FRACTION} x knee)"
    step1_log "$exp_dir" " Baseline p99    : ${baseline_p99}ms"
    step1_log "$exp_dir" "=========================================="

    echo "$knee_rps" > "$sweep_dir/knee_point_rps.txt"

    cat > "$sweep_dir/sweep_summary.json" <<-EOJSON
{
    "knee_point_rps": $knee_rps,
    "characterize_rps": $char_rps,
    "characterize_fraction": $CHARACTERIZE_KNEE_FRACTION,
    "baseline_p99_ms": ${baseline_p99:-0},
    "saturation_threshold": $SATURATION_P99_THRESHOLD,
    "levels_tested": $level,
    "rps_start": $SATURATION_START_RPS,
    "rps_step": $SATURATION_STEP_RPS,
    "duration_per_level_s": $SATURATION_DURATION
}
EOJSON

    echo "$char_rps"
}

# ===========================================================================
# Pod-level monitoring  (CPU / memory / network)
#
# Runs a lightweight polling loop *inside* each victim pod via kubectl exec.
# Reads /proc/1/stat, /proc/1/status, /proc/net/dev once per second and
# writes a CSV to /data/system_metrics_run<N>/metrics.csv in the pod.
# Returns the background kubectl-exec PID.
# ===========================================================================

step1_start_pod_monitor() {
    local pod_name="$1" run_num="$2" duration="$3" exp_dir="$4"

    step1_log "$exp_dir" "  Starting system monitor in $pod_name (run $run_num, ${duration}s)"

    kubectl exec "$pod_name" -- sh -c '
        RUN=$1; DUR=$2
        DIR="/data/system_metrics_run${RUN}"
        mkdir -p "$DIR"

        HDR="ts_epoch_ns,utime,stime,threads,vsize_bytes,rss_pages,vmrss_kb,rx_bytes,tx_bytes"
        echo "$HDR" > "$DIR/metrics.csv"

        END=$(( $(date +%s) + DUR + 5 ))
        while [ "$(date +%s)" -lt "$END" ]; do
            TS=$(date +%s%N)
            # /proc/1/stat: strip comm field (in parens), then parse
            RAW=$(sed "s/.*) //" /proc/1/stat)
            UTIME=$(echo  "$RAW" | awk "{print \$12}")
            STIME=$(echo  "$RAW" | awk "{print \$13}")
            THR=$(echo    "$RAW" | awk "{print \$18}")
            VS=$(echo     "$RAW" | awk "{print \$21}")
            RSSPG=$(echo  "$RAW" | awk "{print \$22}")
            VMRSS=$(grep VmRSS /proc/1/status | awk "{print \$2}")
            RX=$(awk "NR>2 && \$1!~/lo:/{gsub(/:/,\"\",\$1);s+=\$2}END{print s+0}" /proc/net/dev)
            TX=$(awk "NR>2 && \$1!~/lo:/{gsub(/:/,\"\",\$1);s+=\$10}END{print s+0}" /proc/net/dev)
            echo "$TS,$UTIME,$STIME,$THR,$VS,$RSSPG,$VMRSS,$RX,$TX" >> "$DIR/metrics.csv"
            sleep 1
        done
    ' _ "$run_num" "$duration" &

    local pid=$!
    step1_log "$exp_dir" "  Monitor PID $pid (kubectl exec background)"
    echo "$pid"
}

step1_stop_pod_monitor() {
    local pid="$1" exp_dir="$2"
    if kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
    fi
    step1_log "$exp_dir" "  Monitor PID $pid finished"
}

# ===========================================================================
# Retrieve data from a victim pod after a characterization run
# ===========================================================================

step1_retrieve_run_data() {
    local service="$1" run_num="$2" run_dir="$3" exp_dir="$4"

    local pod_name
    pod_name=$(kubectl get pods -l io.kompose.service="$service" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$pod_name" ]]; then
        step1_log "$exp_dir" "  WARNING: no pod found for $service"
        return 1
    fi

    # --- Windowed perf + timing JSON ---
    mkdir -p "$run_dir/windowed"
    local iter_id=$run_num
    local remote_file="/data/run_data_${service}_iter${iter_id}.json"

    if kubectl exec "$pod_name" -- test -f "$remote_file" 2>/dev/null; then
        kubectl exec "$pod_name" -- cat "$remote_file" \
            > "$run_dir/windowed/${service}_raw.json" 2>/dev/null
        step1_log "$exp_dir" "  Retrieved windowed data for $service"

        if command -v jq >/dev/null 2>&1 && [[ -s "$run_dir/windowed/${service}_raw.json" ]]; then
            jq '{
                service_name, iteration_id, run_start, run_end,
                run_duration_ms, window_interval_ms, perf_events,
                sample_count, aggregates,
                samples: [.samples[] | {
                    sample_id, timestamp, offset_ms,
                    perf_counters, perf_deltas,
                    timing_window
                }]
            }' "$run_dir/windowed/${service}_raw.json" \
                > "$run_dir/windowed/${service}.json" 2>/dev/null || \
                cp "$run_dir/windowed/${service}_raw.json" "$run_dir/windowed/${service}.json"
        fi
    else
        step1_log "$exp_dir" "  WARNING: windowed data file not found for $service"
        kubectl exec "$pod_name" -- ls -la /data/ 2>/dev/null | \
            while read -r line; do step1_log "$exp_dir" "    $line"; done
    fi

    # --- System metrics CSV ---
    mkdir -p "$run_dir/system"
    local remote_csv="/data/system_metrics_run${run_num}/metrics.csv"

    if kubectl exec "$pod_name" -- test -f "$remote_csv" 2>/dev/null; then
        kubectl exec "$pod_name" -- cat "$remote_csv" \
            > "$run_dir/system/${service}_metrics.csv" 2>/dev/null
        local nlines
        nlines=$(wc -l < "$run_dir/system/${service}_metrics.csv")
        step1_log "$exp_dir" "  Retrieved system metrics for $service ($nlines samples)"
    else
        step1_log "$exp_dir" "  WARNING: system metrics not found for $service"
    fi
}

# ===========================================================================
# Stage 2 — Characterization Runs
# ===========================================================================

step1_prepare_iteration() {
    local exp_dir="$1" run_num="$2" victim_services="$3"

    step1_log "$exp_dir" "Preparing run $run_num — updating ITERATION_ID and restarting pods ..."

    for service in $victim_services; do
        if validate_timing_service "$service"; then
            kubectl set env "deployment/$service" \
                "ITERATION_ID=${run_num}" \
                "EXPERIMENT_DURATION=${CHARACTERIZE_DURATION}" 2>/dev/null

            if [[ -n "${PERF_EVENTS:-}" ]]; then
                kubectl set env "deployment/$service" \
                    "PERF_EVENTS=${PERF_EVENTS}" 2>/dev/null
            fi

            kubectl rollout restart "deployment/$service" 2>/dev/null || true
            kubectl rollout status  "deployment/$service" --timeout=120s 2>/dev/null || \
                step1_log "$exp_dir" "WARNING: timeout waiting for $service restart"
        fi
    done

    step1_log "$exp_dir" "Waiting 25s for services to stabilize and start sampling ..."
    sleep 25
}

step1_run_single_characterization() {
    local exp_dir="$1" run_num="$2" char_rps="$3" victim_services="$4"

    local run_dir="$exp_dir/runs/run_${run_num}"
    mkdir -p "$run_dir"/{latency,windowed,system}

    step1_log "$exp_dir" "------------------------------------------"
    step1_log "$exp_dir" " Characterization Run $run_num / $CHARACTERIZE_RUNS"
    step1_log "$exp_dir" " RPS=${char_rps}  Duration=${CHARACTERIZE_DURATION}s"
    step1_log "$exp_dir" "------------------------------------------"

    # 1. Prepare pods (new ITERATION_ID, restart, wait)
    step1_prepare_iteration "$exp_dir" "$run_num" "$victim_services"

    # 2. Start pod monitors for every victim service
    local monitor_pids=()
    for service in $victim_services; do
        local pod
        pod=$(kubectl get pods -l io.kompose.service="$service" \
                 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$pod" ]]; then
            local mpid
            mpid=$(step1_start_pod_monitor "$pod" "$run_num" "$CHARACTERIZE_DURATION" "$exp_dir")
            monitor_pids+=("$mpid")
        fi
    done

    # 3. Brief settle before load
    step1_log "$exp_dir" "  Settling 5s before starting load ..."
    sleep 5

    # 4. Record workload-start timestamp
    local wl_start
    wl_start=$(date +%s)
    echo "$wl_start" > "$run_dir/workload_start_epoch.txt"

    # 5. Run wrk2
    step1_log "$exp_dir" "  Starting wrk2: ${char_rps} RPS for ${CHARACTERIZE_DURATION}s"
    step1_run_wrk2 "$exp_dir" "$char_rps" "$CHARACTERIZE_DURATION" \
        "$run_dir/latency/wrk2_output.txt"

    # 6. Record workload-end timestamp
    local wl_end
    wl_end=$(date +%s)
    echo "$wl_end" > "$run_dir/workload_end_epoch.txt"

    local actual_dur=$((wl_end - wl_start))
    step1_log "$exp_dir" "  wrk2 finished (actual ${actual_dur}s)"

    # 7. Parse latency headline numbers
    local p99 p50 actual_rps errors
    p99=$(step1_parse_wrk2_p99 "$run_dir/latency/wrk2_output.txt")
    p50=$(step1_parse_wrk2_p50 "$run_dir/latency/wrk2_output.txt")
    actual_rps=$(step1_parse_wrk2_actual_rps "$run_dir/latency/wrk2_output.txt")
    errors=$(step1_parse_wrk2_errors "$run_dir/latency/wrk2_output.txt")
    step1_log "$exp_dir" "  Latency: p50=${p50}ms  p99=${p99}ms  actual_rps=${actual_rps}  errors=${errors}"

    # 8. Let data flush inside pods
    step1_log "$exp_dir" "  Waiting 10s for in-pod data flush ..."
    sleep 10

    # 9. Stop monitors
    for mpid in "${monitor_pids[@]}"; do
        step1_stop_pod_monitor "$mpid" "$exp_dir"
    done

    # 10. Retrieve all data from pods
    step1_log "$exp_dir" "  Retrieving run data from pods ..."
    for service in $victim_services; do
        step1_retrieve_run_data "$service" "$run_num" "$run_dir" "$exp_dir"
    done

    # 11. Write per-run summary
    cat > "$run_dir/run_summary.json" <<-EOJSON
{
    "run": $run_num,
    "target_rps": $char_rps,
    "actual_rps": ${actual_rps:-0},
    "p50_ms": ${p50:-0},
    "p99_ms": ${p99:-0},
    "errors": ${errors:-0},
    "duration_planned_s": $CHARACTERIZE_DURATION,
    "duration_actual_s": $actual_dur,
    "workload_start_epoch": $wl_start,
    "workload_end_epoch": $wl_end
}
EOJSON

    step1_log "$exp_dir" "  Run $run_num complete"
}

step1_characterize() {
    local exp_dir="$1" char_rps="$2" victim_services="$3"

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " STAGE 2: CHARACTERIZATION"
    step1_log "$exp_dir" " ${CHARACTERIZE_RUNS} runs x ${CHARACTERIZE_DURATION}s @ ${char_rps} RPS"
    step1_log "$exp_dir" " Victim services: $victim_services"
    step1_log "$exp_dir" "=========================================="

    for run_num in $(seq 1 "$CHARACTERIZE_RUNS"); do
        step1_run_single_characterization "$exp_dir" "$run_num" "$char_rps" "$victim_services"

        if [[ $run_num -lt $CHARACTERIZE_RUNS ]]; then
            step1_log "$exp_dir" "  Cool-down 30s before next run ..."
            sleep 30
        fi
    done

    step1_log "$exp_dir" "All $CHARACTERIZE_RUNS characterization runs complete"
}

# ===========================================================================
# Aggregation — produces final summary across all runs
# ===========================================================================

step1_aggregate() {
    local exp_dir="$1" victim_services="$2"
    local summary_dir="$exp_dir/summary"
    mkdir -p "$summary_dir"

    step1_log "$exp_dir" "Aggregating results ..."

    # Requires Python 3 for the heavy lifting
    if ! command -v python3 >/dev/null 2>&1; then
        step1_log "$exp_dir" "WARNING: python3 not found, skipping aggregation"
        return 1
    fi

    python3 - "$exp_dir" "$victim_services" "$CHARACTERIZE_RUNS" <<'PYEOF'
import sys, os, json, csv, math
from pathlib import Path

exp_dir      = sys.argv[1]
services     = sys.argv[2].split()
total_runs   = int(sys.argv[3])
summary_dir  = Path(exp_dir) / "summary"

CLK_TCK = 100  # USER_HZ on most Linux systems

def safe_float(v, default=0.0):
    try: return float(v)
    except: return default

def percentile(vals, pct):
    if not vals: return 0
    s = sorted(vals)
    k = (len(s) - 1) * pct
    f = int(k)
    c = min(f + 1, len(s) - 1)
    return s[f] + (s[c] - s[f]) * (k - f)

def mean(vals):
    return sum(vals) / len(vals) if vals else 0

def stddev(vals):
    if len(vals) < 2: return 0
    m = mean(vals)
    return math.sqrt(sum((v - m)**2 for v in vals) / (len(vals) - 1))

# ---- Per-run collection ----
runs_data = []

for run_num in range(1, total_runs + 1):
    run_dir = Path(exp_dir) / "runs" / f"run_{run_num}"
    run_info = {"run": run_num, "services": {}}

    # Latency summary
    summary_file = run_dir / "run_summary.json"
    if summary_file.exists():
        with open(summary_file) as f:
            run_info["latency"] = json.load(f)

    for svc in services:
        svc_info = {}

        # --- Windowed perf data ---
        wfile = run_dir / "windowed" / f"{svc}.json"
        if wfile.exists():
            with open(wfile) as f:
                wdata = json.load(f)

            samples = wdata.get("samples", [])
            active_samples = [s for s in samples
                              if s.get("timing_window", {}).get("request_count", 0) > 0]

            total_cycles = sum(s.get("perf_deltas", {}).get("cycles", 0) for s in active_samples)
            total_instr  = sum(s.get("perf_deltas", {}).get("instructions", 0) for s in active_samples)
            total_cache_ref  = sum(s.get("perf_deltas", {}).get("cache-references", 0) for s in active_samples)
            total_cache_miss = sum(s.get("perf_deltas", {}).get("cache-misses", 0) for s in active_samples)

            ipc = total_instr / total_cycles if total_cycles > 0 else 0
            cache_miss_rate = total_cache_miss / total_cache_ref if total_cache_ref > 0 else 0

            per_sample_ipc = []
            for s in active_samples:
                cyc = s.get("perf_deltas", {}).get("cycles", 0)
                ins = s.get("perf_deltas", {}).get("instructions", 0)
                if cyc > 0:
                    per_sample_ipc.append(ins / cyc)

            svc_info["perf"] = {
                "ipc": round(ipc, 4),
                "ipc_stddev": round(stddev(per_sample_ipc), 4),
                "cache_miss_rate": round(cache_miss_rate, 6),
                "total_cycles": total_cycles,
                "total_instructions": total_instr,
                "total_cache_references": total_cache_ref,
                "total_cache_misses": total_cache_miss,
                "active_samples": len(active_samples),
                "total_samples": len(samples),
            }

            # Collect all perf delta totals
            all_events = {}
            for s in active_samples:
                for evt, val in s.get("perf_deltas", {}).items():
                    all_events[evt] = all_events.get(evt, 0) + val
            svc_info["perf"]["event_totals"] = all_events

            # Timing stats from aggregates
            agg = wdata.get("aggregates", {})
            svc_info["perf"]["total_requests"] = agg.get("total_requests", 0)
            if agg.get("timing_overall"):
                svc_info["perf"]["timing_overall_ns"] = agg["timing_overall"]

        # --- System metrics (CPU / memory / network) ---
        csv_file = run_dir / "system" / f"{svc}_metrics.csv"
        if csv_file.exists():
            rows = []
            with open(csv_file) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    rows.append(row)

            if len(rows) >= 2:
                # CPU: delta(utime+stime) / delta(wallclock) / CLK_TCK * 100
                cpu_pcts = []
                for i in range(1, len(rows)):
                    dt_ns = safe_float(rows[i]["ts_epoch_ns"]) - safe_float(rows[i-1]["ts_epoch_ns"])
                    dt_s = dt_ns / 1e9 if dt_ns > 0 else 1
                    d_utime = safe_float(rows[i]["utime"]) - safe_float(rows[i-1]["utime"])
                    d_stime = safe_float(rows[i]["stime"]) - safe_float(rows[i-1]["stime"])
                    cpu_pct = ((d_utime + d_stime) / CLK_TCK) / dt_s * 100
                    cpu_pcts.append(cpu_pct)

                    # individual usr/sys
                usr_pcts = []
                sys_pcts = []
                for i in range(1, len(rows)):
                    dt_ns = safe_float(rows[i]["ts_epoch_ns"]) - safe_float(rows[i-1]["ts_epoch_ns"])
                    dt_s = dt_ns / 1e9 if dt_ns > 0 else 1
                    d_u = safe_float(rows[i]["utime"]) - safe_float(rows[i-1]["utime"])
                    d_s = safe_float(rows[i]["stime"]) - safe_float(rows[i-1]["stime"])
                    usr_pcts.append((d_u / CLK_TCK) / dt_s * 100)
                    sys_pcts.append((d_s / CLK_TCK) / dt_s * 100)

                vmrss_vals = [safe_float(r["vmrss_kb"]) for r in rows if r.get("vmrss_kb")]

                # Network throughput
                first_rx = safe_float(rows[0].get("rx_bytes", 0))
                last_rx  = safe_float(rows[-1].get("rx_bytes", 0))
                first_tx = safe_float(rows[0].get("tx_bytes", 0))
                last_tx  = safe_float(rows[-1].get("tx_bytes", 0))
                wall_s   = (safe_float(rows[-1]["ts_epoch_ns"]) - safe_float(rows[0]["ts_epoch_ns"])) / 1e9
                wall_s   = max(wall_s, 1)

                svc_info["system"] = {
                    "cpu_pct_mean":  round(mean(cpu_pcts), 2),
                    "cpu_pct_p50":   round(percentile(cpu_pcts, 0.5), 2),
                    "cpu_pct_p99":   round(percentile(cpu_pcts, 0.99), 2),
                    "cpu_usr_mean":  round(mean(usr_pcts), 2),
                    "cpu_sys_mean":  round(mean(sys_pcts), 2),
                    "vmrss_kb_mean": round(mean(vmrss_vals), 0),
                    "vmrss_kb_max":  round(max(vmrss_vals) if vmrss_vals else 0, 0),
                    "vmrss_mb_mean": round(mean(vmrss_vals) / 1024, 2),
                    "net_rx_bytes_sec": round((last_rx - first_rx) / wall_s, 0),
                    "net_tx_bytes_sec": round((last_tx - first_tx) / wall_s, 0),
                    "net_rx_mbps": round((last_rx - first_rx) / wall_s * 8 / 1e6, 3),
                    "net_tx_mbps": round((last_tx - first_tx) / wall_s * 8 / 1e6, 3),
                    "sample_count": len(rows),
                }

        run_info["services"][svc] = svc_info

    runs_data.append(run_info)

# ---- Cross-run aggregation ----
cross_run = {}
for svc in services:
    svc_agg = {"ipc": [], "cache_miss_rate": [], "cpu_pct": [],
               "cpu_usr": [], "cpu_sys": [], "vmrss_kb": [],
               "net_rx_mbps": [], "net_tx_mbps": [],
               "p99_ms": [], "p50_ms": [], "actual_rps": []}

    for rd in runs_data:
        si = rd.get("services", {}).get(svc, {})
        perf_d  = si.get("perf", {})
        sys_d   = si.get("system", {})
        lat_d   = rd.get("latency", {})

        if perf_d.get("ipc"):       svc_agg["ipc"].append(perf_d["ipc"])
        if perf_d.get("cache_miss_rate"): svc_agg["cache_miss_rate"].append(perf_d["cache_miss_rate"])
        if sys_d.get("cpu_pct_mean"):  svc_agg["cpu_pct"].append(sys_d["cpu_pct_mean"])
        if sys_d.get("cpu_usr_mean"):  svc_agg["cpu_usr"].append(sys_d["cpu_usr_mean"])
        if sys_d.get("cpu_sys_mean"):  svc_agg["cpu_sys"].append(sys_d["cpu_sys_mean"])
        if sys_d.get("vmrss_kb_mean"): svc_agg["vmrss_kb"].append(sys_d["vmrss_kb_mean"])
        if sys_d.get("net_rx_mbps"):   svc_agg["net_rx_mbps"].append(sys_d["net_rx_mbps"])
        if sys_d.get("net_tx_mbps"):   svc_agg["net_tx_mbps"].append(sys_d["net_tx_mbps"])
        if lat_d.get("p99_ms"):   svc_agg["p99_ms"].append(safe_float(lat_d["p99_ms"]))
        if lat_d.get("p50_ms"):   svc_agg["p50_ms"].append(safe_float(lat_d["p50_ms"]))
        if lat_d.get("actual_rps"): svc_agg["actual_rps"].append(safe_float(lat_d["actual_rps"]))

    cross_run[svc] = {}
    for metric, vals in svc_agg.items():
        if vals:
            cross_run[svc][metric] = {
                "mean": round(mean(vals), 4),
                "stddev": round(stddev(vals), 4),
                "min": round(min(vals), 4),
                "max": round(max(vals), 4),
                "n": len(vals),
            }

# ---- Write outputs ----
with open(summary_dir / "per_run.json", "w") as f:
    json.dump(runs_data, f, indent=2)

with open(summary_dir / "cross_run.json", "w") as f:
    json.dump(cross_run, f, indent=2)

# ---- Human-readable report ----
with open(summary_dir / "report.txt", "w") as f:
    f.write("=" * 70 + "\n")
    f.write("  STEP 1 — WORKLOAD CHARACTERIZATION REPORT\n")
    f.write("=" * 70 + "\n\n")

    # Load sweep summary
    sweep_file = Path(exp_dir) / "saturation" / "sweep_summary.json"
    if sweep_file.exists():
        with open(sweep_file) as sf:
            sweep = json.load(sf)
        f.write(f"Knee-point RPS        : {sweep['knee_point_rps']}\n")
        f.write(f"Characterization RPS  : {sweep['characterize_rps']} "
                f"({sweep['characterize_fraction']*100:.0f}% of knee)\n")
        f.write(f"Baseline p99          : {sweep.get('baseline_p99_ms', 'N/A')} ms\n\n")

    for svc in services:
        f.write("-" * 70 + "\n")
        f.write(f"  Service: {svc}\n")
        f.write("-" * 70 + "\n")
        cr = cross_run.get(svc, {})

        def fmt(m, unit="", mult=1):
            d = cr.get(m, {})
            if not d: return "  N/A"
            return (f"  {d['mean']*mult:.4f} +/- {d['stddev']*mult:.4f} {unit}"
                    f"  (min={d['min']*mult:.4f}  max={d['max']*mult:.4f}  n={d['n']})")

        f.write(f"\n  [Perf Counters]\n")
        f.write(f"    IPC               :{fmt('ipc')}\n")
        f.write(f"    Cache miss rate   :{fmt('cache_miss_rate')}\n")

        f.write(f"\n  [CPU]\n")
        f.write(f"    Total CPU %%       :{fmt('cpu_pct', '%')}\n")
        f.write(f"    User  CPU %%       :{fmt('cpu_usr', '%')}\n")
        f.write(f"    Sys   CPU %%       :{fmt('cpu_sys', '%')}\n")

        f.write(f"\n  [Memory]\n")
        f.write(f"    VmRSS (KB)        :{fmt('vmrss_kb', 'KB')}\n")

        f.write(f"\n  [Network]\n")
        f.write(f"    RX throughput      :{fmt('net_rx_mbps', 'Mbps')}\n")
        f.write(f"    TX throughput      :{fmt('net_tx_mbps', 'Mbps')}\n")

        f.write(f"\n  [End-to-end Latency]\n")
        f.write(f"    p50               :{fmt('p50_ms', 'ms')}\n")
        f.write(f"    p99               :{fmt('p99_ms', 'ms')}\n")
        f.write(f"    Actual RPS        :{fmt('actual_rps', 'rps')}\n")
        f.write("\n")

    f.write("=" * 70 + "\n")
    f.write(f"Total runs: {total_runs}\n")
    f.write("=" * 70 + "\n")

print(f"Aggregation complete: {summary_dir}")
PYEOF

    step1_log "$exp_dir" "Aggregation complete — see $summary_dir/"

    # Print report to terminal
    if [[ -f "$summary_dir/report.txt" ]]; then
        step1_log "$exp_dir" ""
        cat "$summary_dir/report.txt" >&2
    fi
}

# ===========================================================================
# Setup & Validation
# ===========================================================================

step1_validate_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: config file not found: $config_file" >&2
        exit 1
    fi

    source "$config_file"

    local required=(EXPERIMENT_NAME TARGET_NODE VICTIM_SERVICES
                    WRK2_TARGET_IP WRK2_TARGET_PORT)
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: required variable $var not set in $config_file" >&2
            exit 1
        fi
    done

    # Defaults for variables referenced by data-collector.sh deploy functions
    NOISY_NEIGHBOR_TYPE="${NOISY_NEIGHBOR_TYPE:-cpu}"
    ENABLE_WINDOWED_SAMPLING="${ENABLE_WINDOWED_SAMPLING:-true}"
    WINDOW_INTERVAL_MS="${WINDOW_INTERVAL_MS:-100}"
    PERF_EVENTS="${PERF_EVENTS:-cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,dTLB-load-misses,iTLB-load-misses,page-faults,minor-faults,major-faults,context-switches,cpu-migrations}"
    TIMING_BUFFER_SIZE="${TIMING_BUFFER_SIZE:-16384}"
    TIMING_FLUSH_THRESHOLD="${TIMING_FLUSH_THRESHOLD:-80}"
    EXPERIMENT_DURATION="${EXPERIMENT_DURATION:-$CHARACTERIZE_DURATION}"
    JAEGER_SAMPLE_RATIO="${JAEGER_SAMPLE_RATIO:-0}"
    CONTENTION_BURSTS="none"
}

step1_setup() {
    local config_file="$1"

    # Source contention-shapes.sh (needed by data-collector.sh internals)
    [[ -f "$SHAPES_SCRIPT" ]] && source "$SHAPES_SCRIPT"

    step1_validate_config "$config_file"

    local exp_id="step1_$(date +%Y%m%d_%H%M%S)_$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')"
    local exp_dir="${STEP1_DATA_DIR:-./step1_data}/$exp_id"
    mkdir -p "$exp_dir"/{logs,metadata,saturation,runs,summary}

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " Step 1: Workload Characterization"
    step1_log "$exp_dir" " Experiment: $EXPERIMENT_NAME"
    step1_log "$exp_dir" " ID: $exp_id"
    step1_log "$exp_dir" " Directory: $exp_dir"
    step1_log "$exp_dir" "=========================================="

    # Write metadata
    cat > "$exp_dir/metadata/experiment.json" <<-EOJSON
{
    "experiment_id": "$exp_id",
    "experiment_name": "$EXPERIMENT_NAME",
    "experiment_type": "step1_characterization",
    "target_node": "$TARGET_NODE",
    "victim_services": "$(echo $VICTIM_SERVICES)",
    "config_file": "$(basename "$config_file")",
    "saturation_sweep": {
        "start_rps": $SATURATION_START_RPS,
        "step_rps": $SATURATION_STEP_RPS,
        "max_rps": $SATURATION_MAX_RPS,
        "duration_per_level_s": $SATURATION_DURATION,
        "p99_threshold": $SATURATION_P99_THRESHOLD
    },
    "characterization": {
        "duration_s": $CHARACTERIZE_DURATION,
        "runs": $CHARACTERIZE_RUNS,
        "knee_fraction": $CHARACTERIZE_KNEE_FRACTION
    },
    "instrumentation": {
        "windowed_sampling": "$ENABLE_WINDOWED_SAMPLING",
        "window_interval_ms": $WINDOW_INTERVAL_MS,
        "perf_events": "$PERF_EVENTS",
        "system_metrics": "proc_stat+proc_status+proc_net_dev@1Hz",
        "latency": "wrk2_hdr_histogram"
    },
    "timestamp": "$(date -Iseconds)"
}
EOJSON

    echo "$exp_dir"
}

step1_deploy() {
    local exp_dir="$1"

    step1_log "$exp_dir" "Deploying victim services: $VICTIM_SERVICES"

    # Remove anti-affinity from all deployments to allow placement
    local all_deps
    all_deps=$(kubectl get deployments -n default -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)
    if [[ -n "$all_deps" ]]; then
        remove_anti_affinity "$all_deps" "$exp_dir"
        sleep 5
    fi

    # Reset non-victim services to default images
    reset_non_victim_services "$VICTIM_SERVICES" "$exp_dir"

    # Deploy victim services with timing images on target node
    deploy_victim_services "$VICTIM_SERVICES" "$TARGET_NODE" "$exp_dir"

    # Stabilisation
    step1_log "$exp_dir" "Waiting 45s for services to stabilize ..."
    sleep 45

    # Configure Jaeger (disabled by default for characterization to reduce overhead)
    configure_jaeger_tracing "$exp_dir"

    # Validate
    step1_log "$exp_dir" "Validating system readiness ..."
    if ! validate_system_readiness "$exp_dir"; then
        step1_log "$exp_dir" "WARNING: validation failed — attempting manual registration ..."
        manual_register_all_services "$exp_dir" 2>/dev/null || true
        sleep 15
        if ! validate_system_readiness "$exp_dir"; then
            step1_log "$exp_dir" "ERROR: system validation failed after recovery. Aborting."
            exit 1
        fi
    fi
    step1_log "$exp_dir" "System ready"
}

# ===========================================================================
# Main
# ===========================================================================

step1_main() {
    if [[ $# -eq 0 ]]; then
        cat <<'USAGE'
Usage: ./step1-characterize.sh <config-file>

Step 1 — Workload Characterization Without Stressor

Two stages:
  Stage 1  Saturation sweep — ramp RPS to find knee point
  Stage 2  Characterization — 5 min x 5 runs at 90% knee-point RPS

Required config variables:
  EXPERIMENT_NAME       Descriptive name
  TARGET_NODE           Kubernetes node to pin victims to
  VICTIM_SERVICES       Space-separated list (e.g. 'search profile')
  WRK2_TARGET_IP        IP reachable from wrk2 client
  WRK2_TARGET_PORT      Port (usually 5000)

Optional:
  WRK2_SCRIPT           Lua workload script path
  WRK2_THREADS          wrk2 threads  (default: 2)
  WRK2_CONNECTIONS      wrk2 connections (default: 2)

  SATURATION_START_RPS  Starting RPS for sweep  (default: 50)
  SATURATION_STEP_RPS   Increment per level     (default: 50)
  SATURATION_MAX_RPS    Upper bound             (default: 2000)
  SATURATION_DURATION   Seconds per level       (default: 30)
  SATURATION_P99_THRESHOLD  p99 multiplier to declare saturation (default: 2.0)

  CHARACTERIZE_DURATION Seconds per run         (default: 300)
  CHARACTERIZE_RUNS     Number of runs          (default: 5)
  CHARACTERIZE_KNEE_FRACTION  Fraction of knee  (default: 0.9)

  ENABLE_WINDOWED_SAMPLING  true/false  (default: true)
  WINDOW_INTERVAL_MS        Sampling window     (default: 100)
  PERF_EVENTS               Comma-separated     (sensible default)
  JAEGER_SAMPLE_RATIO       0 to disable tracing overhead (default: 0)

Example config:

  EXPERIMENT_NAME='Step1 Hotel Reservation Characterization'
  TARGET_NODE='node-1'
  VICTIM_SERVICES='search profile'
  WRK2_TARGET_IP='192.168.1.100'
  WRK2_TARGET_PORT=5000
  WRK2_SCRIPT='../wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua'
  WRK2_THREADS=3
  WRK2_CONNECTIONS=3
  SATURATION_START_RPS=100
  SATURATION_STEP_RPS=100
  SATURATION_MAX_RPS=3000
  CHARACTERIZE_DURATION=300
  CHARACTERIZE_RUNS=5
USAGE
        exit 1
    fi

    local config_file="$1"

    # Setup
    local exp_dir
    exp_dir=$(step1_setup "$config_file")

    # Deploy
    step1_deploy "$exp_dir"

    # Stage 1 — Saturation sweep
    local char_rps
    char_rps=$(step1_saturation_sweep "$exp_dir")

    if [[ -z "$char_rps" || "$char_rps" == "0" ]]; then
        step1_log "$exp_dir" "ERROR: saturation sweep produced no usable RPS"
        exit 1
    fi

    # Brief cool-down between stages
    step1_log "$exp_dir" "Cool-down 30s between stages ..."
    sleep 30

    # Stage 2 — Characterization runs
    step1_characterize "$exp_dir" "$char_rps" "$VICTIM_SERVICES"

    # Aggregate
    step1_aggregate "$exp_dir" "$VICTIM_SERVICES"

    step1_log "$exp_dir" ""
    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " EXPERIMENT COMPLETE"
    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" "Data directory  : $exp_dir"
    step1_log "$exp_dir" "Sweep results   : $exp_dir/saturation/"
    step1_log "$exp_dir" "Run data        : $exp_dir/runs/"
    step1_log "$exp_dir" "Summary         : $exp_dir/summary/"

    echo ""
    echo "Step 1 characterization complete!"
    echo "Data: $exp_dir"
    echo "Report: $exp_dir/summary/report.txt"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    step1_main "$@"
fi
