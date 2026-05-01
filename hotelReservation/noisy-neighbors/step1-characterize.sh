#!/bin/bash
# ===========================================================================
# Step 1: Workload Characterization Without Stressor
# Part of Hardware Counter Justification Plan
#
# Characterizes services under vanilla (unmodified) deployment — no
# interceptor, no in-process perf sampling, no stressors.
#
# Two stages:
#   Stage 1 — Saturation Test: sweep RPS to find the knee point
#   Stage 2 — Characterization: run at 90% knee-point RPS, collect
#             perf counters (external via perf stat), CPU/mem/net, latency
#
# Usage: ./step1-characterize.sh <config-file>
# ===========================================================================

set -e
set -o pipefail

STEP1_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source data-collector.sh for shared deployment utility functions
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
SATURATION_P99_THRESHOLD="${SATURATION_P99_THRESHOLD:-4.0}"
# After first saturation, keep running this many extra levels at the same
# step to verify saturation holds and to better localize the knee.
SATURATION_EXTRA_LEVELS="${SATURATION_EXTRA_LEVELS:-4}"

# Characterization
CHARACTERIZE_DURATION="${CHARACTERIZE_DURATION:-300}"   # 5 min
CHARACTERIZE_RUNS="${CHARACTERIZE_RUNS:-5}"
CHARACTERIZE_KNEE_FRACTION="${CHARACTERIZE_KNEE_FRACTION:-0.9}"  # 90 %

# External perf stat — Ice Lake-SP optimized event set
#
# Top-down L1 group (uses PERF_METRICS register on Ice Lake+, semi-free):
#   slots, topdown-retiring, topdown-bad-spec, topdown-fe-bound, topdown-be-bound
#
# Raw counters (10 events, multiplexed to ~50-70% scheduling on Ice Lake-SP):
#   cycles, instructions                   — IPC denominator/numerator
#   LLC-loads, LLC-load-misses             — last-level cache pressure
#   cycle_activity.stalls_l3_miss          — DRAM stall cycles (direct latency cost)
#   offcore_requests.all_data_rd           — DRAM read bandwidth
#   L1-dcache-load-misses                  — L1 data cache pressure
#   L1-icache-load-misses                  — L1 instruction cache (frontend signal)
#   dTLB-load-misses                       — data TLB pressure
#   branch-misses                          — branch behavior / workload signature
#
# Multiplexing on Ice Lake-SP is expected (~50-70%) due to event constraints
# (cycle_activity.* and offcore_requests.* have specific PMC requirements).
# perf scales values to estimate true counts; for steady 100s ghz runs the
# averaging absorbs most of the noise.
PERF_TOPDOWN_GROUP="${PERF_TOPDOWN_GROUP:-slots,topdown-retiring,topdown-bad-spec,topdown-fe-bound,topdown-be-bound}"
PERF_EVENTS="${PERF_EVENTS:-cycles,instructions,LLC-loads,LLC-load-misses,cycle_activity.stalls_l3_miss,offcore_requests.all_data_rd,L1-dcache-load-misses,L1-icache-load-misses,dTLB-load-misses,branch-misses}"

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
# ghz (gRPC load generator) helpers
#
# We drive the under-observation service's gRPC method directly, bypassing
# the frontend.  ghz is invoked with `--format json`, so its output is a
# single JSON document containing a HDR-style latencyDistribution array
# plus rps / count / errorDistribution.
#
# Payload strategy: ghz's `-d` requires the entire data string to parse
# as valid JSON (template tokens are only allowed inside string values,
# which won't auto-coerce into proto float fields).  Instead we generate
# a randomized JSON array once per experiment via a small Python generator
# and feed it via `-D / --data-file`.  ghz cycles through the array,
# sending one element per request, giving us the same per-request
# variance we'd get from templates without any template-engine risk.
# ===========================================================================

# Read a percentile (50 / 99 / ...) from ghz JSON output, in milliseconds.
step1_parse_ghz_pct() {
    local file="$1" pct="$2"
    [[ -s "$file" ]] || { echo ""; return; }
    python3 - "$file" "$pct" <<'PYEOF' 2>/dev/null || echo ""
import sys, json
try:
    with open(sys.argv[1]) as f:
        # ghz may print non-JSON warnings before the JSON object; find the
        # first '{' to be safe.
        text = f.read()
        i = text.find('{')
        data = json.loads(text[i:]) if i >= 0 else {}
    pct = float(sys.argv[2])
    for entry in data.get('latencyDistribution', []) or []:
        if abs(float(entry.get('percentage', -1)) - pct) < 0.001:
            ns = float(entry.get('latency', 0))
            print(f"{ns/1e6:.2f}")
            sys.exit(0)
    print("")
except Exception:
    print("")
PYEOF
}

step1_parse_ghz_p99() { step1_parse_ghz_pct "$1" 99; }
step1_parse_ghz_p50() { step1_parse_ghz_pct "$1" 50; }

step1_parse_ghz_actual_rps() {
    local file="$1"
    [[ -s "$file" ]] || { echo "0"; return; }
    python3 - "$file" <<'PYEOF' 2>/dev/null || echo "0"
import sys, json
try:
    with open(sys.argv[1]) as f:
        text = f.read()
        i = text.find('{')
        data = json.loads(text[i:]) if i >= 0 else {}
    print(f"{float(data.get('rps', 0)):.2f}")
except Exception:
    print("0")
PYEOF
}

# Total error count: errorDistribution values + non-OK status codes.
step1_parse_ghz_errors() {
    local file="$1"
    [[ -s "$file" ]] || { echo "0"; return; }
    python3 - "$file" <<'PYEOF' 2>/dev/null || echo "0"
import sys, json
try:
    with open(sys.argv[1]) as f:
        text = f.read()
        i = text.find('{')
        data = json.loads(text[i:]) if i >= 0 else {}
    err_total = sum(int(v) for v in (data.get('errorDistribution') or {}).values())
    sc = data.get('statusCodeDistribution') or {}
    non_ok = sum(int(v) for k, v in sc.items() if k != 'OK')
    print(int(err_total + non_ok))
except Exception:
    print("0")
PYEOF
}

# ===========================================================================
# Stage 1 — Saturation Sweep
# ===========================================================================

step1_run_ghz() {
    local exp_dir="$1" rps="$2" duration="$3" output="$4"

    : "${LOADGEN_BIN:?LOADGEN_BIN not set}"
    : "${LOADGEN_PROTO:?LOADGEN_PROTO not set}"
    : "${LOADGEN_METHOD:?LOADGEN_METHOD not set}"
    : "${LOADGEN_DATA_FILE:?LOADGEN_DATA_FILE not set (step1_prepare_payload not run?)}"
    : "${LOADGEN_TARGET_HOST:?LOADGEN_TARGET_HOST not set (NodePort expose failed?)}"
    : "${LOADGEN_TARGET_PORT:?LOADGEN_TARGET_PORT not set (NodePort expose failed?)}"

    local concurrency="${LOADGEN_CONCURRENCY:-12}"
    local connections="${LOADGEN_CONNECTIONS:-4}"
    local proto_root="${LOADGEN_PROTO_ROOT:-../services}"

    if [[ ! -f "$LOADGEN_DATA_FILE" ]]; then
        step1_log "$exp_dir" "  ERROR: payload data file not found: $LOADGEN_DATA_FILE"
        echo "{}" > "$output"
        return
    fi

    step1_log "$exp_dir" \
        "  ghz: --rps=$rps --duration=${duration}s -c $concurrency --connections=$connections" \
        "    method=$LOADGEN_METHOD target=${LOADGEN_TARGET_HOST}:${LOADGEN_TARGET_PORT}"

    "$LOADGEN_BIN" \
        --insecure \
        --proto "$LOADGEN_PROTO" \
        -i "$proto_root" \
        --call "$LOADGEN_METHOD" \
        --rps "$rps" \
        --concurrency "$concurrency" \
        --connections "$connections" \
        --duration "${duration}s" \
        --format json \
        -D "$LOADGEN_DATA_FILE" \
        "${LOADGEN_TARGET_HOST}:${LOADGEN_TARGET_PORT}" \
        > "$output" 2>&1 || true
}

# ===========================================================================
# Pre-generate a randomized JSON array of request payloads (one element per
# request, ghz cycles through them).  Run once per experiment in step1_deploy.
# ===========================================================================

step1_prepare_payload() {
    local exp_dir="$1"
    local count="${LOADGEN_PAYLOAD_COUNT:-5000}"
    local out="$exp_dir/loadgen_payload.json"

    if [[ ! -f "$LOADGEN_PAYLOAD_GENERATOR" ]]; then
        step1_log "$exp_dir" "ERROR: payload generator not found: $LOADGEN_PAYLOAD_GENERATOR"
        return 1
    fi

    step1_log "$exp_dir" "Generating $count randomized payloads -> $out"

    if ! python3 "$LOADGEN_PAYLOAD_GENERATOR" "$count" > "$out"; then
        step1_log "$exp_dir" "ERROR: payload generator failed"
        return 1
    fi

    if [[ ! -s "$out" ]]; then
        step1_log "$exp_dir" "ERROR: payload generator produced empty output"
        return 1
    fi

    LOADGEN_DATA_FILE="$out"
    export LOADGEN_DATA_FILE
    step1_log "$exp_dir" "  payload data file: $LOADGEN_DATA_FILE ($(wc -c < "$out") bytes)"
    return 0
}

# Evaluate one sweep level.
# Args: exp_dir rps duration out_file baseline_p99 label csv_file phase
# Echoes: "saturated|p99|p50|actual|errors|p99_ratio"
# Appends a CSV row to csv_file.
step1_eval_sweep_level() {
    local exp_dir="$1" rps="$2" duration="$3" out="$4"
    local baseline_p99="$5" label="$6" csv_file="$7" phase="$8"

    step1_log "$exp_dir" "--- $label: ${rps} RPS ---"
    step1_run_ghz "$exp_dir" "$rps" "$duration" "$out"

    local p99 p50 actual errors
    p99=$(step1_parse_ghz_p99 "$out")
    p50=$(step1_parse_ghz_p50 "$out")
    actual=$(step1_parse_ghz_actual_rps "$out")
    errors=$(step1_parse_ghz_errors "$out")

    if [[ -z "$p99" || "$p99" == "0" || "$p99" == "0.00" ]]; then
        step1_log "$exp_dir" "  WARNING: could not parse p99 — treating as saturated"
        echo "$label,$phase,$rps,0,0,0,0,0" >> "$csv_file"
        echo "true|0|0|0|0|0"
        return
    fi

    local p99_ratio="1.00"
    if [[ -n "$baseline_p99" && "$baseline_p99" != "0" ]]; then
        p99_ratio=$(awk "BEGIN {printf \"%.2f\", $p99 / $baseline_p99}")
    fi

    step1_log "$exp_dir" "  p99=${p99}ms  p50=${p50}ms  actual_rps=${actual}  errors=${errors}  p99_ratio=${p99_ratio}x"
    echo "$label,$phase,$rps,${actual:-0},$p99,$p50,$p99_ratio,${errors:-0}" >> "$csv_file"

    # ---- Saturation checks ----
    local saturated=false
    local reasons=""

    if [[ -n "$baseline_p99" ]] && \
       awk "BEGIN {exit !($p99_ratio >= $SATURATION_P99_THRESHOLD)}" 2>/dev/null; then
        reasons="p99_ratio=${p99_ratio}x"
        saturated=true
    fi
    if [[ "${errors:-0}" -gt 0 ]]; then
        reasons="${reasons:+$reasons, }errors=${errors}"
        saturated=true
    fi
    if [[ -n "$actual" ]] && awk "BEGIN {exit !($actual < $rps * 0.85)}" 2>/dev/null; then
        reasons="${reasons:+$reasons, }rps_shortfall(${actual}<${rps})"
        saturated=true
    fi

    [[ "$saturated" == "true" ]] && step1_log "$exp_dir" "  SATURATED: $reasons"

    echo "${saturated}|${p99}|${p50}|${actual}|${errors}|${p99_ratio}"
}

step1_saturation_sweep() {
    local exp_dir="$1"
    local sweep_dir="$exp_dir/saturation"
    mkdir -p "$sweep_dir"

    local csv_file="$sweep_dir/sweep_results.csv"
    echo "level,phase,target_rps,actual_rps,p99_ms,p50_ms,p99_ratio,errors,saturated" > "$csv_file"

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " STAGE 1: SATURATION SWEEP"
    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" "RPS range: ${SATURATION_START_RPS}–${SATURATION_MAX_RPS}  step=${SATURATION_STEP_RPS}"
    step1_log "$exp_dir" "Duration per level: ${SATURATION_DURATION}s   p99 threshold: ${SATURATION_P99_THRESHOLD}x"
    step1_log "$exp_dir" "Extra levels past first saturation: ${SATURATION_EXTRA_LEVELS}"

    # Warmup
    step1_log "$exp_dir" "Warmup at ${SATURATION_START_RPS} RPS for ${SATURATION_WARMUP}s ..."
    step1_run_ghz "$exp_dir" "$SATURATION_START_RPS" "$SATURATION_WARMUP" "$sweep_dir/warmup.txt"
    sleep 5

    # Sweep strategy:
    #   Run at increasing RPS using a fixed coarse step.
    #   On first saturation, record first_saturated_rps, then continue for
    #   SATURATION_EXTRA_LEVELS more levels to verify saturation / collect
    #   more post-knee data.  Knee = highest RPS across all levels that did
    #   not saturate.
    local baseline_p99=""
    local last_healthy_rps=""
    local first_saturated_rps=""
    local rps=$SATURATION_START_RPS
    local level=0
    local extra_done=0

    while [[ $rps -le $SATURATION_MAX_RPS ]]; do
        ((level++))
        local phase="pre_sat"
        [[ -n "$first_saturated_rps" ]] && phase="post_sat"

        local out="$sweep_dir/L${level}_rps${rps}.txt"

        local result
        result=$(step1_eval_sweep_level "$exp_dir" "$rps" "$SATURATION_DURATION" \
                    "$out" "$baseline_p99" "L$level ($phase)" "$csv_file" "$phase")

        local saturated p99 p50 actual errors p99_ratio
        IFS='|' read -r saturated p99 p50 actual errors p99_ratio <<< "$result"

        # Append saturated flag to CSV row (step1_eval_sweep_level wrote an 8-col row;
        # rewrite the last line with the saturated column appended)
        # Simpler: recompute CSV line here directly
        sed -i '$ s/$/,'"${saturated}"'/' "$csv_file" 2>/dev/null || true

        # First successful run establishes baseline
        if [[ -z "$baseline_p99" && "$p99" != "0" ]]; then
            baseline_p99="$p99"
            step1_log "$exp_dir" "  Baseline p99: ${baseline_p99}ms"
        fi

        if [[ "$saturated" == "true" ]]; then
            # Track the first saturating RPS
            if [[ -z "$first_saturated_rps" ]]; then
                first_saturated_rps=$rps
                step1_log "$exp_dir" "  First saturation at ${rps} RPS — continuing for ${SATURATION_EXTRA_LEVELS} more level(s)"
            fi
        else
            # Healthy level — update knee candidate
            last_healthy_rps=$rps
        fi

        # If we've already seen saturation, count extra levels
        if [[ -n "$first_saturated_rps" ]]; then
            ((extra_done++))
            if [[ $extra_done -ge $SATURATION_EXTRA_LEVELS ]]; then
                step1_log "$exp_dir" "  Completed ${SATURATION_EXTRA_LEVELS} extra level(s) after first saturation — stopping sweep"
                break
            fi
        fi

        rps=$((rps + SATURATION_STEP_RPS))
        sleep 5
    done

    # --- Determine knee ---
    local knee_rps=""
    if [[ -z "$last_healthy_rps" ]]; then
        step1_log "$exp_dir" "WARNING: system saturated from the start"
        knee_rps=$SATURATION_START_RPS
    else
        knee_rps=$last_healthy_rps
        if [[ -z "$first_saturated_rps" ]]; then
            step1_log "$exp_dir" "WARNING: reached max RPS ${SATURATION_MAX_RPS} without saturation"
        fi
    fi

    local char_rps
    char_rps=$(awk "BEGIN {printf \"%.0f\", $knee_rps * $CHARACTERIZE_KNEE_FRACTION}")

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " Knee point (max healthy) : ${knee_rps} RPS"
    step1_log "$exp_dir" " First saturated at       : ${first_saturated_rps:-N/A} RPS"
    step1_log "$exp_dir" " Characterize at          : ${char_rps} RPS (${CHARACTERIZE_KNEE_FRACTION} x knee)"
    step1_log "$exp_dir" " Baseline p99             : ${baseline_p99}ms"
    step1_log "$exp_dir" " Levels tested            : ${level}"
    step1_log "$exp_dir" "=========================================="

    echo "$knee_rps" > "$sweep_dir/knee_point_rps.txt"

    cat > "$sweep_dir/sweep_summary.json" <<-EOJSON
{
    "knee_point_rps": $knee_rps,
    "first_saturated_rps": ${first_saturated_rps:-0},
    "characterize_rps": $char_rps,
    "characterize_fraction": $CHARACTERIZE_KNEE_FRACTION,
    "baseline_p99_ms": ${baseline_p99:-0},
    "saturation_threshold": $SATURATION_P99_THRESHOLD,
    "levels_tested": $level,
    "extra_levels_after_saturation": $SATURATION_EXTRA_LEVELS,
    "rps_start": $SATURATION_START_RPS,
    "rps_step": $SATURATION_STEP_RPS,
    "rps_max": $SATURATION_MAX_RPS,
    "duration_per_level_s": $SATURATION_DURATION
}
EOJSON

    echo "$char_rps"
}

# ===========================================================================
# Pod-level monitoring  (CPU / memory / network)
#
# Runs a lightweight polling loop *inside* each observed-service pod via
# kubectl exec.  Reads /proc/1/stat, /proc/1/status, /proc/net/dev once
# per second and writes a CSV in the pod.
# Returns the background kubectl-exec PID.
# ===========================================================================

step1_start_pod_monitor() {
    local pod_name="$1" run_num="$2" duration="$3" exp_dir="$4"

    step1_log "$exp_dir" "  Starting system monitor in $pod_name (run $run_num, ${duration}s)"

    kubectl exec "$pod_name" -- sh -c '
        RUN=$1; DUR=$2
        DIR="/data/system_metrics_run${RUN}"
        mkdir -p "$DIR"

        HDR="ts_epoch_ns,utime,stime,threads,vsize_bytes,rss_pages,vmrss_kb,rx_bytes,tx_bytes,vol_ctxt,nonvol_ctxt"
        echo "$HDR" > "$DIR/metrics.csv"

        END=$(( $(date +%s) + DUR + 5 ))
        while [ "$(date +%s)" -lt "$END" ]; do
            TS=$(date +%s%N)
            RAW=$(sed "s/.*) //" /proc/1/stat)
            UTIME=$(echo  "$RAW" | awk "{print \$12}")
            STIME=$(echo  "$RAW" | awk "{print \$13}")
            THR=$(echo    "$RAW" | awk "{print \$18}")
            VS=$(echo     "$RAW" | awk "{print \$21}")
            RSSPG=$(echo  "$RAW" | awk "{print \$22}")
            VMRSS=$(grep VmRSS /proc/1/status | awk "{print \$2}")
            VCS=$(grep "^voluntary_ctxt_switches" /proc/1/status | awk "{print \$2}")
            NVCS=$(grep "^nonvoluntary_ctxt_switches" /proc/1/status | awk "{print \$2}")
            RX=$(awk "NR>2 && \$1!~/lo:/{gsub(/:/,\"\",\$1);s+=\$2}END{print s+0}" /proc/net/dev)
            TX=$(awk "NR>2 && \$1!~/lo:/{gsub(/:/,\"\",\$1);s+=\$10}END{print s+0}" /proc/net/dev)
            echo "$TS,$UTIME,$STIME,$THR,$VS,$RSSPG,$VMRSS,$RX,$TX,$VCS,$NVCS" >> "$DIR/metrics.csv"
            sleep 1
        done
    ' _ "$run_num" "$duration" &

    local pid=$!
    step1_log "$exp_dir" "  Monitor PID $pid (kubectl exec background)"
    echo "$pid"
}

step1_wait_background_pid() {
    local pid="$1" exp_dir="$2" label="$3"
    if kill -0 "$pid" 2>/dev/null; then
        wait "$pid" 2>/dev/null || true
    fi
    step1_log "$exp_dir" "  $label PID $pid finished"
}

# ===========================================================================
# External perf stat collection (via SSH to node)
#
# Resolves the container PID on the host, then runs
#   sudo perf stat -e <events> -p <PID> sleep <duration>
# Output is saved to a file for later parsing.
# ===========================================================================

step1_start_perf_stat() {
    local service="$1" run_num="$2" duration="$3" exp_dir="$4"
    local output_file="$exp_dir/runs/run_${run_num}/perf/${service}_perf_stat.txt"
    mkdir -p "$(dirname "$output_file")"

    # Resolve pod → node + container ID
    local pod_name
    pod_name=$(kubectl get pods -l io.kompose.service="$service" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$pod_name" ]]; then
        step1_log "$exp_dir" "  WARNING: no pod for $service, skipping perf stat"
        echo ""
        return
    fi

    local node_name
    node_name=$(kubectl get pod "$pod_name" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    local container_id
    container_id=$(kubectl get pod "$pod_name" \
        -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null | sed 's|.*://||')

    if [[ -z "$node_name" || -z "$container_id" ]]; then
        step1_log "$exp_dir" "  WARNING: could not resolve node/container for $service"
        echo ""
        return
    fi

    step1_log "$exp_dir" "  Starting perf stat on $node_name for $service (container $container_id)"

    local events="$PERF_EVENTS"
    local topdown="$PERF_TOPDOWN_GROUP"

    # Build perf -e flags. If PERF_TOPDOWN_GROUP is set, wrap it as a strict
    # event group with {} so its members schedule together (uses PERF_METRICS
    # register on Ice Lake-SP and newer).  Raw events get a separate -e flag.
    local perf_args=""
    if [[ -n "$topdown" ]]; then
        perf_args="-e '{${topdown}}'"
    fi
    perf_args="$perf_args -e $events"

    # SSH to the node, find host PID, run perf stat
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "$node_name" "
        # Try docker first, then crictl
        PID=\$(docker inspect $container_id --format '{{.State.Pid}}' 2>/dev/null)
        if [[ -z \"\$PID\" || \"\$PID\" == \"0\" ]]; then
            PID=\$(crictl inspect --output go-template --template '{{.info.pid}}' $container_id 2>/dev/null)
        fi

        if [[ -z \"\$PID\" || \"\$PID\" == \"0\" ]]; then
            echo 'ERROR: could not resolve container PID'
            exit 1
        fi

        echo \"host_pid=\$PID\"
        echo \"node=$node_name\"
        echo \"service=$service\"
        echo \"container_id=$container_id\"
        echo \"topdown_group=$topdown\"
        echo \"events=$events\"
        echo \"duration=${duration}s\"
        echo '---'
        sudo perf stat $perf_args -p \$PID sleep $duration 2>&1
    " > "$output_file" 2>&1 &

    local pid=$!
    step1_log "$exp_dir" "  perf stat PID $pid (ssh background)"
    echo "$pid"
}

step1_parse_perf_stat_file() {
    local perf_file="$1"

    if [[ ! -s "$perf_file" ]] || grep -q 'ERROR:' "$perf_file" 2>/dev/null; then
        echo "{}"
        return
    fi

    # Parse "   1,234,567      event-name" lines from perf stat output
    python3 -c "
import sys, re, json

data = open(sys.argv[1]).read()
counters = {}
schedule_pct = {}
for line in data.splitlines():
    # Match: '   1,234,567      event-name           # ...           (74.32%)'
    m = re.match(r'^\s+([\d,]+)\s+([\S]+)', line)
    if m:
        val = int(m.group(1).replace(',', ''))
        name = m.group(2)
        counters[name] = val
        pct_match = re.search(r'\(([\d.]+)%\)\s*\$', line)
        if pct_match:
            schedule_pct[name] = float(pct_match.group(1))

result = dict(counters)

# ---------- Basic counters ----------
cyc   = counters.get('cycles', 0)
ins   = counters.get('instructions', 0)
# LLC (last-level cache)
llc_loads = counters.get('LLC-loads', 0)
llc_miss  = counters.get('LLC-load-misses', 0)
# Branches
br_ins    = counters.get('branch-instructions', counters.get('branches', 0))
br_miss   = counters.get('branch-misses', 0)
# L1 caches
l1i_miss  = counters.get('L1-icache-load-misses', 0)
l1d_loads = counters.get('L1-dcache-loads', 0)
l1d_miss  = counters.get('L1-dcache-load-misses', 0)
# TLBs
itlb_miss = counters.get('iTLB-load-misses', 0)
dtlb_loads = counters.get('dTLB-loads', 0)
dtlb_miss  = counters.get('dTLB-load-misses', 0)
# Memory subsystem
stalls_l3   = counters.get('cycle_activity.stalls_l3_miss', 0)
stalls_mem  = counters.get('cycle_activity.stalls_mem_any', 0)
stalls_tot  = counters.get('cycle_activity.stalls_total', 0)
offcore_rd  = counters.get('offcore_requests.all_data_rd', 0)
offcore_all = counters.get('offcore_requests.all_requests', 0)
# Generic cache (legacy compatibility)
cref  = counters.get('cache-references', 0)
cmiss = counters.get('cache-misses', 0)

# ---------- Top-down (Ice Lake+) ----------
slots         = counters.get('slots', 0)
td_retire     = counters.get('topdown-retiring', 0)
td_badspec    = counters.get('topdown-bad-spec', 0)
td_febound    = counters.get('topdown-fe-bound', 0)
td_bebound    = counters.get('topdown-be-bound', 0)

if slots > 0:
    result['topdown_retiring_pct']     = round(td_retire / slots * 100, 2)
    result['topdown_bad_spec_pct']     = round(td_badspec / slots * 100, 2)
    result['topdown_fe_bound_pct']     = round(td_febound / slots * 100, 2)
    result['topdown_be_bound_pct']     = round(td_bebound / slots * 100, 2)

# ---------- Derived metrics ----------
if cyc > 0:
    result['ipc'] = round(ins / cyc, 4)
    if stalls_l3 > 0:
        result['stalls_l3_pct'] = round(stalls_l3 / cyc * 100, 2)
    if stalls_mem > 0:
        result['stalls_mem_pct'] = round(stalls_mem / cyc * 100, 2)
    if stalls_tot > 0:
        result['stalls_total_pct'] = round(stalls_tot / cyc * 100, 2)

# Miss rates
if cref > 0:
    result['cache_miss_rate'] = round(cmiss / cref, 6)
if llc_loads > 0:
    result['llc_miss_rate'] = round(llc_miss / llc_loads, 6)
if br_ins > 0:
    result['branch_miss_rate'] = round(br_miss / br_ins, 6)
if l1d_loads > 0:
    result['l1d_miss_rate'] = round(l1d_miss / l1d_loads, 6)
if dtlb_loads > 0:
    result['dtlb_miss_rate'] = round(dtlb_miss / dtlb_loads, 6)

# MPKI = misses per kilo instructions
if ins > 0:
    if llc_miss > 0:
        result['llc_mpki'] = round(llc_miss / ins * 1000, 4)
    if l1i_miss > 0:
        result['l1i_mpki'] = round(l1i_miss / ins * 1000, 4)
    if l1d_miss > 0:
        result['l1d_mpki'] = round(l1d_miss / ins * 1000, 4)
    if br_miss > 0:
        result['branch_mpki'] = round(br_miss / ins * 1000, 4)
    if cmiss > 0:
        result['cache_mpki'] = round(cmiss / ins * 1000, 4)
    if itlb_miss > 0:
        result['itlb_mpki'] = round(itlb_miss / ins * 1000, 4)
    if dtlb_miss > 0:
        result['dtlb_mpki'] = round(dtlb_miss / ins * 1000, 4)
    if offcore_rd > 0:
        result['offcore_data_rd_per_kins'] = round(offcore_rd / ins * 1000, 4)

# Scheduling % (multiplexing transparency)
if schedule_pct:
    result['_schedule_pct'] = schedule_pct

print(json.dumps(result))
" "$perf_file" 2>/dev/null || echo "{}"
}

# ===========================================================================
# Retrieve system metrics from a pod after a characterization run
# ===========================================================================

step1_retrieve_system_metrics() {
    local service="$1" run_num="$2" run_dir="$3" exp_dir="$4"

    local pod_name
    pod_name=$(kubectl get pods -l io.kompose.service="$service" \
                  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$pod_name" ]]; then
        step1_log "$exp_dir" "  WARNING: no pod found for $service"
        return 1
    fi

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
#
# Each run: restart pods (clean state) → start monitors + perf stat →
#           run ghz → collect data.
# ===========================================================================

step1_prepare_run() {
    local exp_dir="$1" run_num="$2" observed_services="$3"

    step1_log "$exp_dir" "Preparing run $run_num — restarting pods for clean process state ..."

    for service in $observed_services; do
        # Set ITERATION_ID for tracking (visible in kubectl describe)
        kubectl set env "deployment/$service" "ITERATION_ID=${run_num}" 2>/dev/null || true

        kubectl rollout restart "deployment/$service" 2>/dev/null || true
        kubectl rollout status  "deployment/$service" --timeout=120s 2>/dev/null || \
            step1_log "$exp_dir" "WARNING: timeout waiting for $service restart"
    done

    step1_log "$exp_dir" "Waiting 25s for services to stabilize ..."
    sleep 25
}

step1_run_single_characterization() {
    local exp_dir="$1" run_num="$2" char_rps="$3" observed_services="$4"

    local run_dir="$exp_dir/runs/run_${run_num}"
    mkdir -p "$run_dir"/{latency,perf,system}

    step1_log "$exp_dir" "------------------------------------------"
    step1_log "$exp_dir" " Characterization Run $run_num / $CHARACTERIZE_RUNS"
    step1_log "$exp_dir" " RPS=${char_rps}  Duration=${CHARACTERIZE_DURATION}s"
    step1_log "$exp_dir" "------------------------------------------"

    # 0. Restart pods for clean process state
    step1_prepare_run "$exp_dir" "$run_num" "$observed_services"

    # 1. Start pod monitors (CPU / memory / network via /proc)
    local monitor_pids=()
    for service in $observed_services; do
        local pod
        pod=$(kubectl get pods -l io.kompose.service="$service" \
                 -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$pod" ]]; then
            local mpid
            mpid=$(step1_start_pod_monitor "$pod" "$run_num" "$CHARACTERIZE_DURATION" "$exp_dir")
            monitor_pids+=("$mpid")
        fi
    done

    # 2. Start external perf stat (IPC, cache miss rate via SSH + perf)
    local perf_pids=()
    for service in $observed_services; do
        local ppid
        ppid=$(step1_start_perf_stat "$service" "$run_num" "$CHARACTERIZE_DURATION" "$exp_dir")
        [[ -n "$ppid" ]] && perf_pids+=("$ppid")
    done

    # 3. Brief settle before load
    step1_log "$exp_dir" "  Settling 5s before starting load ..."
    sleep 5

    # 4. Record workload-start timestamp
    local wl_start
    wl_start=$(date +%s)
    echo "$wl_start" > "$run_dir/workload_start_epoch.txt"

    # 5. Run ghz
    step1_log "$exp_dir" "  Starting ghz: ${char_rps} RPS for ${CHARACTERIZE_DURATION}s"
    step1_run_ghz "$exp_dir" "$char_rps" "$CHARACTERIZE_DURATION" \
        "$run_dir/latency/ghz_output.json"

    # 6. Record workload-end timestamp
    local wl_end
    wl_end=$(date +%s)
    echo "$wl_end" > "$run_dir/workload_end_epoch.txt"

    local actual_dur=$((wl_end - wl_start))
    step1_log "$exp_dir" "  ghz finished (actual ${actual_dur}s)"

    # 7. Parse latency headline numbers
    local p99 p50 actual_rps errors
    p99=$(step1_parse_ghz_p99 "$run_dir/latency/ghz_output.json")
    p50=$(step1_parse_ghz_p50 "$run_dir/latency/ghz_output.json")
    actual_rps=$(step1_parse_ghz_actual_rps "$run_dir/latency/ghz_output.json")
    errors=$(step1_parse_ghz_errors "$run_dir/latency/ghz_output.json")
    step1_log "$exp_dir" "  Latency: p50=${p50}ms  p99=${p99}ms  actual_rps=${actual_rps}  errors=${errors}"

    # 8. Wait for monitors and perf stat to finish
    step1_log "$exp_dir" "  Waiting for background collectors ..."
    for mpid in "${monitor_pids[@]}"; do
        step1_wait_background_pid "$mpid" "$exp_dir" "Monitor"
    done
    for ppid in "${perf_pids[@]}"; do
        step1_wait_background_pid "$ppid" "$exp_dir" "perf stat"
    done

    # 9. Retrieve system metrics from pods
    step1_log "$exp_dir" "  Retrieving data from pods ..."
    for service in $observed_services; do
        step1_retrieve_system_metrics "$service" "$run_num" "$run_dir" "$exp_dir"
    done

    # 10. Parse perf stat results
    for service in $observed_services; do
        local pf="$run_dir/perf/${service}_perf_stat.txt"
        if [[ -s "$pf" ]]; then
            local parsed
            parsed=$(step1_parse_perf_stat_file "$pf")
            echo "$parsed" > "$run_dir/perf/${service}_perf_parsed.json"
            step1_log "$exp_dir" "  perf stat for $service: $parsed"
        fi
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
    local exp_dir="$1" char_rps="$2" observed_services="$3"

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " STAGE 2: CHARACTERIZATION"
    step1_log "$exp_dir" " ${CHARACTERIZE_RUNS} runs x ${CHARACTERIZE_DURATION}s @ ${char_rps} RPS"
    step1_log "$exp_dir" " Observed services: $observed_services"
    step1_log "$exp_dir" "=========================================="

    # Verify SSH + perf availability before starting runs
    step1_verify_perf_access "$exp_dir" "$observed_services"

    for run_num in $(seq 1 "$CHARACTERIZE_RUNS"); do
        step1_run_single_characterization "$exp_dir" "$run_num" "$char_rps" "$observed_services"

        if [[ $run_num -lt $CHARACTERIZE_RUNS ]]; then
            step1_log "$exp_dir" "  Cool-down 30s before next run ..."
            sleep 30
        fi
    done

    step1_log "$exp_dir" "All $CHARACTERIZE_RUNS characterization runs complete"
}

step1_verify_perf_access() {
    local exp_dir="$1" observed_services="$2"

    step1_log "$exp_dir" "Verifying SSH + perf access for external counter collection ..."

    for service in $observed_services; do
        local pod_name node_name
        pod_name=$(kubectl get pods -l io.kompose.service="$service" \
                      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        node_name=$(kubectl get pod "$pod_name" -o jsonpath='{.spec.nodeName}' 2>/dev/null)

        if [[ -z "$node_name" ]]; then
            step1_log "$exp_dir" "  WARNING: cannot resolve node for $service"
            continue
        fi

        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$node_name" \
                "command -v perf >/dev/null 2>&1 && echo 'perf OK'" 2>/dev/null | grep -q 'perf OK'; then
            step1_log "$exp_dir" "  $service ($node_name): SSH + perf OK"
        else
            step1_log "$exp_dir" "  WARNING: SSH or perf not available on $node_name for $service"
            step1_log "$exp_dir" "           IPC / cache-miss-rate will not be collected for this service"
        fi
    done
}

# ===========================================================================
# Aggregation — produces final summary across all runs
# ===========================================================================

step1_aggregate() {
    local exp_dir="$1" observed_services="$2"
    local summary_dir="$exp_dir/summary"
    mkdir -p "$summary_dir"

    step1_log "$exp_dir" "Aggregating results ..."

    if ! command -v python3 >/dev/null 2>&1; then
        step1_log "$exp_dir" "WARNING: python3 not found, skipping aggregation"
        return 1
    fi

    python3 - "$exp_dir" "$observed_services" "$CHARACTERIZE_RUNS" <<'PYEOF'
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

        # --- perf stat data (external, via SSH) ---
        perf_file = run_dir / "perf" / f"{svc}_perf_parsed.json"
        if perf_file.exists():
            with open(perf_file) as f:
                try:
                    perf_data = json.load(f)
                except json.JSONDecodeError:
                    perf_data = {}
            if perf_data:
                svc_info["perf"] = perf_data

        # --- System metrics (CPU / memory / network from /proc) ---
        csv_file = run_dir / "system" / f"{svc}_metrics.csv"
        if csv_file.exists():
            rows = []
            with open(csv_file) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    rows.append(row)

            if len(rows) >= 2:
                cpu_pcts = []
                usr_pcts = []
                sys_pcts = []
                for i in range(1, len(rows)):
                    dt_ns = safe_float(rows[i]["ts_epoch_ns"]) - safe_float(rows[i-1]["ts_epoch_ns"])
                    dt_s = dt_ns / 1e9 if dt_ns > 0 else 1
                    d_u = safe_float(rows[i]["utime"]) - safe_float(rows[i-1]["utime"])
                    d_s = safe_float(rows[i]["stime"]) - safe_float(rows[i-1]["stime"])
                    usr_pcts.append((d_u / CLK_TCK) / dt_s * 100)
                    sys_pcts.append((d_s / CLK_TCK) / dt_s * 100)
                    cpu_pcts.append(((d_u + d_s) / CLK_TCK) / dt_s * 100)

                vmrss_vals = [safe_float(r["vmrss_kb"]) for r in rows if r.get("vmrss_kb")]

                first_rx = safe_float(rows[0].get("rx_bytes", 0))
                last_rx  = safe_float(rows[-1].get("rx_bytes", 0))
                first_tx = safe_float(rows[0].get("tx_bytes", 0))
                last_tx  = safe_float(rows[-1].get("tx_bytes", 0))
                wall_s   = (safe_float(rows[-1]["ts_epoch_ns"]) - safe_float(rows[0]["ts_epoch_ns"])) / 1e9
                wall_s   = max(wall_s, 1)

                # Context switch rates (cumulative deltas / wall time)
                vol_first  = safe_float(rows[0].get("vol_ctxt", 0))
                vol_last   = safe_float(rows[-1].get("vol_ctxt", 0))
                nvol_first = safe_float(rows[0].get("nonvol_ctxt", 0))
                nvol_last  = safe_float(rows[-1].get("nonvol_ctxt", 0))

                svc_info["system"] = {
                    "cpu_pct_mean":  round(mean(cpu_pcts), 2),
                    "cpu_pct_p50":   round(percentile(cpu_pcts, 0.5), 2),
                    "cpu_pct_p99":   round(percentile(cpu_pcts, 0.99), 2),
                    "cpu_usr_mean":  round(mean(usr_pcts), 2),
                    "cpu_sys_mean":  round(mean(sys_pcts), 2),
                    "vmrss_kb_mean": round(mean(vmrss_vals), 0),
                    "vmrss_kb_max":  round(max(vmrss_vals) if vmrss_vals else 0, 0),
                    "vmrss_mb_mean": round(mean(vmrss_vals) / 1024, 2) if vmrss_vals else 0,
                    "net_rx_bytes_sec": round((last_rx - first_rx) / wall_s, 0),
                    "net_tx_bytes_sec": round((last_tx - first_tx) / wall_s, 0),
                    "net_rx_mbps": round((last_rx - first_rx) / wall_s * 8 / 1e6, 3),
                    "net_tx_mbps": round((last_tx - first_tx) / wall_s * 8 / 1e6, 3),
                    "vol_ctxt_per_sec":   round((vol_last  - vol_first)  / wall_s, 2),
                    "nonvol_ctxt_per_sec": round((nvol_last - nvol_first) / wall_s, 2),
                    "sample_count": len(rows),
                }

        run_info["services"][svc] = svc_info

    runs_data.append(run_info)

# ---- Cross-run aggregation ----
cross_run = {}
for svc in services:
    svc_agg = {
        # Compute efficiency
        "ipc": [],
        # Top-down breakdown
        "topdown_retiring_pct": [], "topdown_bad_spec_pct": [],
        "topdown_fe_bound_pct": [], "topdown_be_bound_pct": [],
        # Memory subsystem stalls
        "stalls_l3_pct": [], "stalls_mem_pct": [], "stalls_total_pct": [],
        # Miss rates
        "cache_miss_rate": [], "llc_miss_rate": [], "branch_miss_rate": [],
        "l1d_miss_rate": [], "dtlb_miss_rate": [],
        # MPKI family
        "cache_mpki": [], "llc_mpki": [], "l1i_mpki": [], "l1d_mpki": [],
        "branch_mpki": [], "itlb_mpki": [], "dtlb_mpki": [],
        "offcore_data_rd_per_kins": [],
        # System metrics
        "cpu_pct": [], "cpu_usr": [], "cpu_sys": [], "vmrss_kb": [],
        "net_rx_mbps": [], "net_tx_mbps": [],
        "vol_ctxt_per_sec": [], "nonvol_ctxt_per_sec": [],
        # Latency
        "p99_ms": [], "p50_ms": [], "actual_rps": []
    }

    for rd in runs_data:
        si = rd.get("services", {}).get(svc, {})
        perf_d = si.get("perf", {})
        sys_d  = si.get("system", {})
        lat_d  = rd.get("latency", {})

        # Derived perf metrics (only append if present and non-zero)
        for k in ("ipc",
                  "topdown_retiring_pct", "topdown_bad_spec_pct",
                  "topdown_fe_bound_pct", "topdown_be_bound_pct",
                  "stalls_l3_pct", "stalls_mem_pct", "stalls_total_pct",
                  "cache_miss_rate", "llc_miss_rate", "branch_miss_rate",
                  "l1d_miss_rate", "dtlb_miss_rate",
                  "cache_mpki", "llc_mpki", "l1i_mpki", "l1d_mpki",
                  "branch_mpki", "itlb_mpki", "dtlb_mpki",
                  "offcore_data_rd_per_kins"):
            v = perf_d.get(k)
            if v is not None and v != 0:
                svc_agg[k].append(v)

        # System metrics
        for k in ("vol_ctxt_per_sec", "nonvol_ctxt_per_sec"):
            v = sys_d.get(k)
            if v is not None:
                svc_agg[k].append(v)

        if sys_d.get("cpu_pct_mean"):     svc_agg["cpu_pct"].append(sys_d["cpu_pct_mean"])
        if sys_d.get("cpu_usr_mean"):     svc_agg["cpu_usr"].append(sys_d["cpu_usr_mean"])
        if sys_d.get("cpu_sys_mean"):     svc_agg["cpu_sys"].append(sys_d["cpu_sys_mean"])
        if sys_d.get("vmrss_kb_mean"):    svc_agg["vmrss_kb"].append(sys_d["vmrss_kb_mean"])
        if sys_d.get("net_rx_mbps"):      svc_agg["net_rx_mbps"].append(sys_d["net_rx_mbps"])
        if sys_d.get("net_tx_mbps"):      svc_agg["net_tx_mbps"].append(sys_d["net_tx_mbps"])
        if lat_d.get("p99_ms"):           svc_agg["p99_ms"].append(safe_float(lat_d["p99_ms"]))
        if lat_d.get("p50_ms"):           svc_agg["p50_ms"].append(safe_float(lat_d["p50_ms"]))
        if lat_d.get("actual_rps"):       svc_agg["actual_rps"].append(safe_float(lat_d["actual_rps"]))

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
    f.write("  STEP 1 — WORKLOAD CHARACTERIZATION REPORT (VANILLA)\n")
    f.write("=" * 70 + "\n\n")

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

        f.write(f"\n  [Top-down L1 — Ice Lake PERF_METRICS]\n")
        f.write(f"    Retiring %         :{fmt('topdown_retiring_pct', '%')}\n")
        f.write(f"    Bad-speculation %  :{fmt('topdown_bad_spec_pct', '%')}\n")
        f.write(f"    Frontend-bound %   :{fmt('topdown_fe_bound_pct', '%')}\n")
        f.write(f"    Backend-bound %    :{fmt('topdown_be_bound_pct', '%')}\n")

        f.write(f"\n  [Compute Efficiency]\n")
        f.write(f"    IPC                :{fmt('ipc')}\n")

        f.write(f"\n  [Memory Subsystem Stalls — % of cycles]\n")
        f.write(f"    Stalled L3-miss %  :{fmt('stalls_l3_pct', '%')}\n")
        f.write(f"    Stalled mem-any %  :{fmt('stalls_mem_pct', '%')}\n")
        f.write(f"    Stalled total %    :{fmt('stalls_total_pct', '%')}\n")

        f.write(f"\n  [Cache Hierarchy — Miss Rates / MPKI]\n")
        f.write(f"    LLC miss rate      :{fmt('llc_miss_rate')}\n")
        f.write(f"    LLC MPKI           :{fmt('llc_mpki')}\n")
        f.write(f"    L1-d miss rate     :{fmt('l1d_miss_rate')}\n")
        f.write(f"    L1-d MPKI          :{fmt('l1d_mpki')}\n")
        f.write(f"    L1-i MPKI          :{fmt('l1i_mpki')}\n")
        f.write(f"    Cache miss rate    :{fmt('cache_miss_rate')}\n")
        f.write(f"    Cache MPKI         :{fmt('cache_mpki')}\n")

        f.write(f"\n  [TLB Pressure — MPKI]\n")
        f.write(f"    dTLB MPKI          :{fmt('dtlb_mpki')}\n")
        f.write(f"    iTLB MPKI          :{fmt('itlb_mpki')}\n")

        f.write(f"\n  [Branches]\n")
        f.write(f"    Branch miss rate   :{fmt('branch_miss_rate')}\n")
        f.write(f"    Branch MPKI        :{fmt('branch_mpki')}\n")

        f.write(f"\n  [DRAM Bandwidth]\n")
        f.write(f"    Offcore reads/Kins :{fmt('offcore_data_rd_per_kins')}\n")

        f.write(f"\n  [CPU — /proc/1/stat]\n")
        f.write(f"    Total CPU %%       :{fmt('cpu_pct', '%')}\n")
        f.write(f"    User  CPU %%       :{fmt('cpu_usr', '%')}\n")
        f.write(f"    Sys   CPU %%       :{fmt('cpu_sys', '%')}\n")

        f.write(f"\n  [Scheduling — /proc/1/status, ctxt switches/sec]\n")
        f.write(f"    Voluntary    /sec  :{fmt('vol_ctxt_per_sec', '/s')}\n")
        f.write(f"    Non-voluntary/sec  :{fmt('nonvol_ctxt_per_sec', '/s')}\n")

        f.write(f"\n  [Memory — /proc/1/status]\n")
        f.write(f"    VmRSS (KB)         :{fmt('vmrss_kb', 'KB')}\n")

        f.write(f"\n  [Network — /proc/net/dev]\n")
        f.write(f"    RX throughput      :{fmt('net_rx_mbps', 'Mbps')}\n")
        f.write(f"    TX throughput      :{fmt('net_tx_mbps', 'Mbps')}\n")

        f.write(f"\n  [Service Latency — ghz (direct gRPC, downstream live)]\n")
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

    local required=(EXPERIMENT_NAME TARGET_NODE OBSERVED_SERVICE
                    LOADGEN_BIN LOADGEN_PROTO LOADGEN_METHOD LOADGEN_PAYLOAD_GENERATOR)
    for var in "${required[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: required variable $var not set in $config_file" >&2
            exit 1
        fi
    done

    # OBSERVED_SERVICE must be a single service name (one experiment per
    # service).  The script exposes that one service via NodePort and drives
    # ghz directly at it; multi-service runs are no longer supported here.
    if [[ "$OBSERVED_SERVICE" =~ [[:space:]] ]]; then
        echo "ERROR: OBSERVED_SERVICE must be a single service name (got: '$OBSERVED_SERVICE')" >&2
        echo "       Run separate experiments per service with one config each." >&2
        exit 1
    fi

    # Many helpers downstream still loop over a space-separated list; expose
    # a singleton list so they keep working unchanged.
    OBSERVED_SERVICES="$OBSERVED_SERVICE"
    VICTIM_SERVICES="$OBSERVED_SERVICE"

    # ghz binary precheck
    if ! command -v "$LOADGEN_BIN" >/dev/null 2>&1 && [[ ! -x "$LOADGEN_BIN" ]]; then
        echo "ERROR: ghz binary not found at LOADGEN_BIN='$LOADGEN_BIN'" >&2
        echo "       Install with: $STEP1_SCRIPTS_DIR/loadgen/install-ghz.sh" >&2
        exit 1
    fi

    # Payload generator precheck (Python script that prints a JSON array
    # of N randomized requests; called once per experiment).
    if [[ ! -f "$LOADGEN_PAYLOAD_GENERATOR" ]]; then
        echo "ERROR: LOADGEN_PAYLOAD_GENERATOR not found: $LOADGEN_PAYLOAD_GENERATOR" >&2
        exit 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: python3 is required to run the payload generator" >&2
        exit 1
    fi

    # Proto file precheck
    if [[ ! -f "$LOADGEN_PROTO" ]]; then
        echo "ERROR: LOADGEN_PROTO not found: $LOADGEN_PROTO" >&2
        exit 1
    fi

    # Vanilla deployment — no interceptor, no windowed sampling
    ENABLE_WINDOWED_SAMPLING="false"

    # Defaults for data-collector.sh deploy function compatibility
    NOISY_NEIGHBOR_TYPE="${NOISY_NEIGHBOR_TYPE:-cpu}"
    EXPERIMENT_DURATION="${EXPERIMENT_DURATION:-$CHARACTERIZE_DURATION}"
    JAEGER_SAMPLE_RATIO="${JAEGER_SAMPLE_RATIO:-0}"
    CONTENTION_BURSTS="none"
}

# ===========================================================================
# NodePort exposure for the under-observation service
#
# search/profile k8s Services are ClusterIP by default; ghz lives outside the
# cluster, so we patch the Service to NodePort, capture the assigned port,
# and revert on cleanup.
# ===========================================================================

step1_expose_nodeport() {
    local service="$1" exp_dir="$2"

    step1_log "$exp_dir" "Exposing $service via NodePort ..."

    if ! kubectl patch svc "$service" \
            -p '{"spec":{"type":"NodePort"}}' >/dev/null 2>&1; then
        step1_log "$exp_dir" "ERROR: kubectl patch svc $service failed"
        return 1
    fi

    # Wait briefly for the auto-allocated NodePort to be assigned
    local node_port="" tries=0
    while [[ -z "$node_port" && $tries -lt 10 ]]; do
        node_port=$(kubectl get svc "$service" \
            -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
        [[ -n "$node_port" ]] && break
        sleep 1
        ((tries++))
    done

    if [[ -z "$node_port" ]]; then
        step1_log "$exp_dir" "ERROR: NodePort not assigned for $service after 10s"
        return 1
    fi

    # Pin to a specific NodePort if requested (firewalld on RHEL/OpenShift
    # only opens 30000-32767 by default; the kube-apiserver port range may
    # be wider but allocations below 30000 will be silently dropped at the
    # host firewall.  Always pin to a port in the firewall-friendly range
    # to avoid silent connection-refused failures.)
    if [[ -n "${LOADGEN_NODEPORT:-}" ]]; then
        if [[ "$node_port" != "$LOADGEN_NODEPORT" ]]; then
            step1_log "$exp_dir" "  Pinning NodePort -> $LOADGEN_NODEPORT (was auto=$node_port)"
            if ! kubectl patch svc "$service" \
                    --type='json' \
                    -p='[{"op":"replace","path":"/spec/ports/0/nodePort","value":'"$LOADGEN_NODEPORT"'}]' \
                    >/dev/null 2>&1; then
                step1_log "$exp_dir" "ERROR: failed to pin NodePort to $LOADGEN_NODEPORT (already in use?)"
                return 1
            fi
            node_port="$LOADGEN_NODEPORT"
        fi
    fi

    local node_ip
    node_ip=$(kubectl get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [[ -z "$node_ip" ]]; then
        # Fallback to ExternalIP if no InternalIP
        node_ip=$(kubectl get node "$TARGET_NODE" \
            -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
    fi
    if [[ -z "$node_ip" ]]; then
        step1_log "$exp_dir" "ERROR: could not resolve IP for node $TARGET_NODE"
        return 1
    fi

    # Allow override via config (e.g. cluster-internal IP not reachable from loadgen host)
    LOADGEN_TARGET_HOST="${LOADGEN_TARGET_HOST_OVERRIDE:-$node_ip}"
    LOADGEN_TARGET_PORT="$node_port"
    export LOADGEN_TARGET_HOST LOADGEN_TARGET_PORT

    step1_log "$exp_dir" "  $service exposed at ${LOADGEN_TARGET_HOST}:${LOADGEN_TARGET_PORT} (NodePort, node=$TARGET_NODE)"

    # Fail-fast TCP reachability probe.  Many clusters silently drop
    # NodePort traffic below the firewalld-allowed range; without this
    # check the saturation sweep would burn an entire run before noticing.
    # Endpoints can take a few seconds to populate, so retry briefly.
    local probe_ok=false probe_tries=0
    while [[ "$probe_ok" == "false" && $probe_tries -lt 8 ]]; do
        if timeout 3 bash -c "</dev/tcp/${LOADGEN_TARGET_HOST}/${LOADGEN_TARGET_PORT}" 2>/dev/null; then
            probe_ok=true
            break
        fi
        sleep 2
        ((probe_tries++))
    done

    if [[ "$probe_ok" != "true" ]]; then
        step1_log "$exp_dir" "ERROR: ${LOADGEN_TARGET_HOST}:${LOADGEN_TARGET_PORT} not reachable from this host."
        step1_log "$exp_dir" "       Likely cause: firewalld blocks NodePort outside 30000-32767."
        step1_log "$exp_dir" "       Set LOADGEN_NODEPORT=<port-in-30000-32767> in the config,"
        step1_log "$exp_dir" "       or LOADGEN_TARGET_HOST_OVERRIDE=<reachable-IP> if the node IP is not routable."
        return 1
    fi

    step1_log "$exp_dir" "  TCP reachability OK (${LOADGEN_TARGET_HOST}:${LOADGEN_TARGET_PORT})"
    return 0
}

step1_revert_nodeport() {
    local service="$1"
    [[ -z "$service" ]] && return 0

    # Best-effort revert.  JSON Patch leaves nodePort allocation alone but
    # changes type back to ClusterIP; failure is non-fatal (cleanup path).
    kubectl patch svc "$service" \
        --type='json' \
        -p='[{"op":"replace","path":"/spec/type","value":"ClusterIP"}]' \
        >/dev/null 2>&1 || true
}

# ===========================================================================
# step1-specific readiness validation
#
# data-collector.sh's validate_system_readiness probes the frontend HTTP
# endpoints (/hotels, /recommendations).  step1 bypasses the frontend
# entirely (ghz -> NodePort -> observed service), so a /hotels failure is
# a false-positive for step1.  We check only what step1 actually depends on:
#   1. The observed service's pod is ready.
#   2. The Consul services required by the observed service's gRPC clients
#      are registered:
#        - search   needs srv-geo and srv-rate (consul resolver)
#        - profile  needs no Consul-resolved peer (talks to memcached/mongo
#                   via kube-dns, which is verified by pod readiness probes)
# ===========================================================================
step1_validate_readiness() {
    local exp_dir="$1"
    local svc="${OBSERVED_SERVICE:-}"

    step1_log "$exp_dir" "=== STEP1 READINESS VALIDATION ==="

    if [[ -z "$svc" ]]; then
        step1_log "$exp_dir" "  ERROR: OBSERVED_SERVICE is empty"
        return 1
    fi

    # 1. Observed service pod ready
    local ready desired
    ready=$(kubectl get deployment "$svc" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(kubectl get deployment "$svc" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [[ "$ready" != "$desired" || "$ready" == "0" ]]; then
        step1_log "$exp_dir" "  FAIL: $svc pods ready=$ready/$desired"
        return 1
    fi
    step1_log "$exp_dir" "  $svc: $ready/$desired pods ready"

    # 2. Required downstream Consul services for the observed service
    local required_consul=()
    case "$svc" in
        search)  required_consul=(srv-search srv-geo srv-rate) ;;
        profile) required_consul=(srv-profile) ;;
        *)       required_consul=("srv-$svc") ;;
    esac

    local consul_services
    consul_services=$(kubectl exec -it deployment/consul -- \
        consul catalog services 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//')

    for c in "${required_consul[@]}"; do
        if echo "$consul_services" | grep -qx "$c"; then
            step1_log "$exp_dir" "  $c: registered"
        else
            step1_log "$exp_dir" "  FAIL: $c not registered in Consul"
            step1_log "$exp_dir" "  Registered services seen: $(echo $consul_services | tr '\n' ' ')"
            return 1
        fi
    done

    step1_log "$exp_dir" "Step1 readiness: PASS"
    return 0
}

step1_create_exp_dir() {
    local exp_id="step1_$(date +%Y%m%d_%H%M%S)_$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' ')"
    local exp_dir="${STEP1_DATA_DIR:-./step1_data}/$exp_id"
    mkdir -p "$exp_dir"/{logs,metadata,saturation,runs,summary}

    step1_log "$exp_dir" "=========================================="
    step1_log "$exp_dir" " Step 1: Workload Characterization (vanilla)"
    step1_log "$exp_dir" " Experiment: $EXPERIMENT_NAME"
    step1_log "$exp_dir" " ID: $exp_id"
    step1_log "$exp_dir" " Directory: $exp_dir"
    step1_log "$exp_dir" "=========================================="

    cat > "$exp_dir/metadata/experiment.json" <<-EOJSON
{
    "experiment_id": "$exp_id",
    "experiment_name": "$EXPERIMENT_NAME",
    "experiment_type": "step1_characterization_vanilla",
    "target_node": "$TARGET_NODE",
    "observed_service": "$OBSERVED_SERVICE",
    "config_file": "$(basename "$config_file")",
    "loadgen": {
        "tool": "ghz",
        "binary": "$LOADGEN_BIN",
        "proto": "$LOADGEN_PROTO",
        "method": "$LOADGEN_METHOD",
        "payload_generator": "$LOADGEN_PAYLOAD_GENERATOR",
        "payload_count": ${LOADGEN_PAYLOAD_COUNT:-5000},
        "concurrency": ${LOADGEN_CONCURRENCY:-12},
        "connections": ${LOADGEN_CONNECTIONS:-4},
        "transport": "direct_grpc_nodeport"
    },
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
        "interceptor": false,
        "windowed_sampling": false,
        "perf_stat_external": true,
        "perf_events": "$PERF_EVENTS",
        "system_metrics": "proc_stat+proc_status+proc_net_dev@1Hz",
        "latency": "ghz_hdr_histogram"
    },
    "timestamp": "$(date -Iseconds)"
}
EOJSON

    echo "$exp_dir"
}

step1_deploy() {
    local exp_dir="$1"

    step1_log "$exp_dir" "Deploying observed service (vanilla image): $OBSERVED_SERVICE"

    # Remove anti-affinity from all deployments to allow placement
    local all_deps
    all_deps=$(kubectl get deployments -n default \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null)
    if [[ -n "$all_deps" ]]; then
        remove_anti_affinity "$all_deps" "$exp_dir"
        sleep 5
    fi

    # Reset ALL services to default images (ensures vanilla deployment)
    reset_non_victim_services "" "$exp_dir"

    # Deploy the observed service on the target node using vanilla images.
    # ENABLE_WINDOWED_SAMPLING=false causes deploy_victim_services to use
    # deploy_regular_service (standard image, no interceptor)
    deploy_victim_services "$OBSERVED_SERVICE" "$TARGET_NODE" "$exp_dir"

    step1_log "$exp_dir" "Waiting 45s for services to stabilize ..."
    sleep 45

    # Configure Jaeger (disabled by default to avoid overhead)
    configure_jaeger_tracing "$exp_dir"

    # Validate system readiness (step1-specific: only what direct-gRPC needs)
    step1_log "$exp_dir" "Validating step1 readiness ..."
    if ! step1_validate_readiness "$exp_dir"; then
        step1_log "$exp_dir" "WARNING: validation failed — attempting Consul re-registration ..."
        manual_register_all_services "$exp_dir" 2>/dev/null || true
        sleep 15
        if ! step1_validate_readiness "$exp_dir"; then
            step1_log "$exp_dir" "ERROR: step1 readiness failed after recovery. Aborting."
            exit 1
        fi
    fi
    step1_log "$exp_dir" "System ready"

    # Expose the observed service via NodePort so the external ghz client
    # can dial it directly.  Trap-based revert is set in step1_main.
    if ! step1_expose_nodeport "$OBSERVED_SERVICE" "$exp_dir"; then
        step1_log "$exp_dir" "ERROR: failed to expose $OBSERVED_SERVICE via NodePort"
        exit 1
    fi
    STEP1_EXPOSED_SERVICE="$OBSERVED_SERVICE"
    export STEP1_EXPOSED_SERVICE

    # Generate the randomized payload array used by ghz (-D).  This is what
    # gives every request a fresh lat/lon/dates (search) or hotelIds list
    # (profile) without relying on ghz's template engine.
    if ! step1_prepare_payload "$exp_dir"; then
        step1_log "$exp_dir" "ERROR: failed to prepare loadgen payload"
        exit 1
    fi
}

# Cleanup hook installed via trap in step1_main.  Runs on EXIT/INT/TERM.
step1_cleanup() {
    if [[ -n "${STEP1_EXPOSED_SERVICE:-}" ]]; then
        step1_revert_nodeport "$STEP1_EXPOSED_SERVICE"
    fi
}

# ===========================================================================
# Main
# ===========================================================================

step1_main() {
    if [[ $# -eq 0 ]]; then
        cat <<'USAGE'
Usage: ./step1-characterize.sh <config-file>

Step 1 — Workload Characterization Without Stressor (Vanilla)

Deploys ONE service with the standard (unmodified) image — no
interceptor, no in-process perf sampling.  ghz drives that service's
gRPC method directly via NodePort while its downstream call chain
stays live (search→geo+rate, profile→memcached+mongo).  Perf counters
are collected externally via SSH + perf stat on the target node.

Two stages:
  Stage 1  Saturation sweep   — ramp RPS to find the knee point
  Stage 2  Characterization   — N runs at (knee_fraction * knee) RPS

Required config variables:
  EXPERIMENT_NAME        Descriptive name
  TARGET_NODE            Kubernetes node to pin the observed service to
  OBSERVED_SERVICE       Single service name (e.g. 'search' or 'profile')

  LOADGEN_BIN            Path to the ghz binary (install via
                         ./loadgen/install-ghz.sh)
  LOADGEN_PROTO          .proto file for the target service
  LOADGEN_METHOD         Fully-qualified method, e.g.
                         'search.Search/Nearby' or 'profile.Profile/GetProfiles'
  LOADGEN_PAYLOAD_GENERATOR  Python3 script that prints a JSON array of N
                             randomized request bodies to stdout (called once
                             per experiment; ghz cycles through the array)

Optional:
  LOADGEN_PROTO_ROOT     Proto import root (default: ../services)
  LOADGEN_PAYLOAD_COUNT  Number of pre-randomized requests in the array
                         (default: 5000)
  LOADGEN_CONCURRENCY    ghz virtual users  (default: 12)
  LOADGEN_CONNECTIONS    ghz gRPC connections (default: 4)
  LOADGEN_NODEPORT       Pin NodePort to this value (recommended: 30000-32767
                         so RHEL/OpenShift firewalld doesn't drop the traffic).
                         If unset, k8s auto-allocates -- which may pick a port
                         outside firewalld's range.
  LOADGEN_TARGET_HOST_OVERRIDE
                         Override the resolved node IP (e.g. external IP)

  SATURATION_START_RPS   Starting RPS for sweep  (default: 50)
  SATURATION_STEP_RPS    Increment per level     (default: 50)
  SATURATION_MAX_RPS     Upper bound             (default: 2000)
  SATURATION_DURATION    Seconds per level       (default: 30)
  SATURATION_P99_THRESHOLD  p99 multiplier to declare saturation (default: 4.0)
  SATURATION_EXTRA_LEVELS   Extra sweep levels after first saturation
                            (default: 4 — verifies saturation, refines knee)

  CHARACTERIZE_DURATION  Seconds per run         (default: 300)
  CHARACTERIZE_RUNS      Number of runs          (default: 5)
  CHARACTERIZE_KNEE_FRACTION  Fraction of knee   (default: 0.9)

  PERF_EVENTS            perf stat events (sensible default)
  JAEGER_SAMPLE_RATIO    0 to disable tracing overhead (default: 0)

Prerequisites:
  - ghz installed and pointed to by LOADGEN_BIN (./loadgen/install-ghz.sh)
  - SSH access from this host to TARGET_NODE (for perf stat)
  - perf installed on TARGET_NODE
  - sudo access for perf stat on TARGET_NODE
USAGE
        exit 1
    fi

    local config_file="$1"

    # Source contention-shapes.sh (needed by data-collector.sh internals)
    [[ -f "$SHAPES_SCRIPT" ]] && source "$SHAPES_SCRIPT"

    # Load and validate config in the current shell (NOT a subshell)
    # so that all variables (OBSERVED_SERVICE, LOADGEN_*, etc.) persist
    step1_validate_config "$config_file"

    # Install cleanup trap BEFORE deploy so a failure mid-deploy still
    # reverts any NodePort patch that was applied.
    trap step1_cleanup EXIT INT TERM

    # Create experiment directory (runs in subshell to capture path)
    local exp_dir
    exp_dir=$(step1_create_exp_dir)

    step1_deploy "$exp_dir"

    local char_rps
    char_rps=$(step1_saturation_sweep "$exp_dir")

    if [[ -z "$char_rps" || "$char_rps" == "0" ]]; then
        step1_log "$exp_dir" "ERROR: saturation sweep produced no usable RPS"
        exit 1
    fi

    step1_log "$exp_dir" "Cool-down 30s between stages ..."
    sleep 30

    step1_characterize "$exp_dir" "$char_rps" "$OBSERVED_SERVICE"

    step1_aggregate "$exp_dir" "$OBSERVED_SERVICE"

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
