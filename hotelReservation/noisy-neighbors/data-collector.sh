#!/bin/bash
# Integrated Data Collection Framework with Service Execution Time Integration
# Usage: ./data-collector.sh <experiment-config-file>

set -e

# Configuration
DATA_DIR="${DATA_DIR:-./experiment_data}"
HOTEL_MANIFESTS_DIR="${HOTEL_MANIFESTS_DIR:-./hotelReservation}"
WRK2_DIR="${WRK2_DIR:-../../wrk2}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Timing image configuration
TIMING_REGISTRY="${TIMING_REGISTRY:-royno7}"
WINDOWED_IMAGE_SUFFIX="windowed"

# CPU allocation configuration
CPUS_PER_SERVICE="${CPUS_PER_SERVICE:-3}"  # Each service gets 3 CPUs by default
STARTING_CPU="${STARTING_CPU:-0}"          # Start allocating from CPU 0

# Valid services that support windowed sampling
VALID_TIMING_SERVICES=("frontend" "geo" "profile" "rate" "recommendation" "reservation" "search" "user")

# Get current image for a service from deployment
get_current_windowed_image() {
    local service="$1"
    
    # Get current image from deployment
    local current_image=$(kubectl get deployment "$service" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
    
    if [[ -z "$current_image" ]]; then
        echo ""
        return 1
    fi
    
    # If already using a windowed image, return it as-is
    if [[ "$current_image" == *"-windowed:"* ]]; then
        echo "$current_image"
        return 0
    fi
    
    # If not a windowed image, construct windowed version with same tag
    # Extract registry, image name, and tag
    # Format could be: registry/image:tag or just image:tag
    if [[ "$current_image" =~ ^([^/]+)/([^:]+):(.+)$ ]]; then
        # Has registry: registry/image:tag
        local registry="${BASH_REMATCH[1]}"
        local image="${BASH_REMATCH[2]}"
        local tag="${BASH_REMATCH[3]}"
        echo "${registry}/${service}-windowed:${tag}"
    elif [[ "$current_image" =~ ^([^:]+):(.+)$ ]]; then
        # No registry: image:tag
        local tag="${BASH_REMATCH[2]}"
        echo "${TIMING_REGISTRY}/${service}-windowed:${tag}"
    else
        # Fallback: use default registry and latest tag
        echo "${TIMING_REGISTRY}/${service}-windowed:latest"
    fi
}

# Timing images are determined dynamically based on current deployment
declare -A TIMING_IMAGES

# Path to timing image build script
TIMING_BUILD_SCRIPT="../build-timing-images.sh"

# existing script paths
STRESS_SCRIPT="$SCRIPTS_DIR/stress-ng/stress-ng-helpers.sh"
TAINT_SCRIPT="$SCRIPTS_DIR/node-taint.sh"
SHAPES_SCRIPT="$SCRIPTS_DIR/contention-shapes.sh"

# Generate unique experiment ID
generate_exp_id() {
    echo "exp_$(date +%Y%m%d_%H%M%S)_$(uuidgen | cut -d'-' -f1)"
}

# Generate contention burst schedule for an iteration
# Returns: array of burst specs "start_time:duration:intensity"
# Special values: "none" or empty = no contention baseline
generate_burst_schedule() {
    local exp_dir="$1"
    local iteration="$2"
    
    if [[ "${CONTENTION_BURSTS:-}" == "none" ]]; then
        # Explicit no-contention mode
        log "$exp_dir" "No-contention baseline mode for iteration $iteration"
        echo "none"
    elif [[ -n "${CONTENTION_BURSTS:-}" ]]; then
        # User-defined burst schedule
        log "$exp_dir" "Using user-defined burst schedule for iteration $iteration"
        log "$exp_dir" "Burst schedule: $CONTENTION_BURSTS"
        echo "$CONTENTION_BURSTS"
    elif [[ -n "${EXPERIMENT_DURATION:-}" ]]; then
        # Legacy single-duration model (backward compatibility)
        log "$exp_dir" "Using legacy single-duration model: ${EXPERIMENT_DURATION}s"
        if [[ -z "${NOISY_NEIGHBOR_ARGS:-}" || "${NOISY_NEIGHBOR_ARGS:-}" == "0" ]]; then
            # No contention in legacy mode
            log "$exp_dir" "No-contention baseline (NOISY_NEIGHBOR_ARGS empty or 0)"
            echo "none"
        else
            echo "0:${EXPERIMENT_DURATION}:${NOISY_NEIGHBOR_ARGS}"
        fi
    else
        log "$exp_dir" "ERROR: Must specify either CONTENTION_BURSTS or EXPERIMENT_DURATION"
        return 1
    fi
}

# Calculate total iteration duration from burst schedule
calculate_iteration_duration() {
    local burst_schedule="$1"
    
    # Handle no-contention mode
    if [[ -z "$burst_schedule" || "$burst_schedule" == "none" ]]; then
        # Use EXPERIMENT_DURATION if set, otherwise default to 60s
        local duration="${EXPERIMENT_DURATION:-60}"
        echo $((duration + 10))  # Add buffer
        return
    fi
    
    local bursts=($burst_schedule)
    local max_end_time=0
    
    for burst in "${bursts[@]}"; do
        IFS=':' read -r start duration intensity <<< "$burst"
        local end_time=$((start + duration))
        [[ $end_time -gt $max_end_time ]] && max_end_time=$end_time
    done
    
    # Add buffer time for data collection
    echo $((max_end_time + 10))
}

# Parse intensity value for stress command
# For CPU: returns number of workers
# For MEM/MEMORY: returns "workers l3_size" (uses --stream --stream-l3-size stressor)
#   - Set MEMORY_L3_SIZE env var to override L3 size (default: 64M)
#   - L3 size forces buffer allocation of 4x this size per worker
# For CACHE-FENCE/CACHE-FLUSH: returns number of cache workers
parse_stress_intensity() {
    local stress_type="$1"
    local intensity="$2"
    
    case "$stress_type" in
        cpu)
            echo "$intensity"  # Number of CPU workers
            ;;
        mem|memory)
            # Memory stressor uses: workers l3_size
            # Default L3 size is 64M to force main memory access (4x L3 = 256MB per worker)
            local l3_size="${MEMORY_L3_SIZE:-64M}"
            echo "$intensity $l3_size"  # Number of stream workers + L3 size override
            ;;
        io|iomix)
            echo "$intensity"  # Number of IO workers
            ;;
        cache|cache-fence|cache-flush|cache-l2)
            echo "$intensity"  # Number of cache workers (uses --cache stressor)
            ;;
        cache-llc)
            # Cache LLC bandwidth stressor uses: workers l3_size
            # Default L3 size is 8M (creates 32MB working set per worker to fit in typical L3)
            local llc_l3_size="${CACHE_LLC_L3_SIZE:-8M}"
            echo "$intensity $llc_l3_size"  # Number of stream workers + L3 size for LLC-fit working set
            ;;
        *)
            echo "$intensity"
            ;;
    esac
}

# Create experiment directory structure
create_exp_directory() {
    local exp_id="$1"
    local exp_dir="$DATA_DIR/$exp_id"
    
    mkdir -p "$exp_dir"/{raw,processed,logs,metadata}
    mkdir -p "$exp_dir/raw"/{windowed,latency,system,stress}
    mkdir -p "$exp_dir/processed"/{aggregated}
    
    echo "$exp_dir"
}

# Log function with timestamp
# Outputs to stderr AND log file (so it doesn't pollute function return values on stdout)
log() {
    local exp_dir="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >&2
    echo "$msg" >> "$exp_dir/logs/collector.log"
}

# Validate timing service
validate_timing_service() {
    local service="$1"
    
    for valid_service in "${VALID_TIMING_SERVICES[@]}"; do
        if [[ "$service" == "$valid_service" ]]; then
            return 0
        fi
    done
    return 1
}

# Get container name for a service
get_container_name() {
    local service="$1"
    
    case $service in
        "user")
            echo "hotel-reserv-user"
            ;;
        "frontend")
            echo "hotel-reserv-frontend"
            ;;
        "search")
            echo "hotel-reserv-search"
            ;;
        "profile")
            echo "hotel-reserv-profile"
            ;;
        "rate")
            echo "hotel-reserv-rate"
            ;;
        "recommendation")
            echo "hotel-reserv-recommendation"
            ;;
        "reservation")
            echo "hotel-reserv-reservation"
            ;;
        "geo")
            echo "hotel-reserv-geo"
            ;;
        *)
            echo "hotel-reserv-$service"
            ;;
    esac
}

# Check if timing image exists, build if needed
ensure_timing_image_exists() {
    local service="$1"
    local exp_dir="$2"
    
    # Get windowed image name dynamically from current deployment
    local timing_image=$(get_current_windowed_image "$service")
    
    if [[ -z "$timing_image" ]]; then
        log "$exp_dir" "ERROR: Could not determine windowed image for $service"
        return 1
    fi
    
    log "$exp_dir" "Checking if windowed image exists: $timing_image"
    
    # Check if image exists in registry (try to pull)
    if docker pull "$timing_image" &>/dev/null; then
        log "$exp_dir" "Timing image already exists: $timing_image"
        return 0
    fi
    
    log "$exp_dir" "Timing image not found, building: $timing_image"
    
    # Check if build script exists
    if [[ ! -f "$TIMING_BUILD_SCRIPT" ]]; then
        log "$exp_dir" "ERROR: Timing build script not found: $TIMING_BUILD_SCRIPT"
        return 1
    fi
    
    # Build the timing image
    log "$exp_dir" "Building timing image for $service using $TIMING_BUILD_SCRIPT"
    if "$TIMING_BUILD_SCRIPT" "$service" "$TIMING_TAG" >> "$exp_dir/logs/collector.log" 2>&1; then
        log "$exp_dir" "Successfully built timing image: $timing_image"
        return 0
    else
        log "$exp_dir" "ERROR: Failed to build timing image for $service"
        return 1
    fi
}

# Update deployment to use timing-enabled image and environment (with windowed sampling)
update_deployment_for_timing() {
    local service="$1"
    local exp_dir="$2"
    local iteration="${3:-1}"  # Optional: iteration number (default 1)
    
    log "$exp_dir" "Updating deployment for $service with windowed sampling configuration (iteration $iteration)"
    
    # Get windowed image name dynamically from current deployment
    local timing_image=$(get_current_windowed_image "$service")
    
    if [[ -z "$timing_image" ]]; then
        log "$exp_dir" "ERROR: Could not determine windowed image for service $service"
        return 1
    fi
    
    log "$exp_dir" "Will use windowed image: $timing_image"
    local container_name=$(get_container_name "$service")
    
    # Update image
    log "$exp_dir" "Setting image for $service: $timing_image"
    if ! kubectl set image "deployment/$service" "$container_name=$timing_image"; then
        log "$exp_dir" "ERROR: Failed to set image for $service"
        return 1
    fi
    
    # Set windowed sampling environment variables
    log "$exp_dir" "Setting windowed sampling environment variables for $service"
    
    # Enable windowed sampling
    if ! kubectl set env "deployment/$service" "ENABLE_WINDOWED_SAMPLING=${ENABLE_WINDOWED_SAMPLING:-true}"; then
        log "$exp_dir" "ERROR: Failed to set ENABLE_WINDOWED_SAMPLING for $service"
        return 1
    fi
    
    # Set iteration ID for this iteration
    if ! kubectl set env "deployment/$service" "ITERATION_ID=${iteration}"; then
        log "$exp_dir" "ERROR: Failed to set ITERATION_ID for $service"
        return 1
    fi
    
    # Set experiment duration (run duration)
    if ! kubectl set env "deployment/$service" "EXPERIMENT_DURATION=${EXPERIMENT_DURATION}"; then
        log "$exp_dir" "ERROR: Failed to set EXPERIMENT_DURATION for $service"
        return 1
    fi
    
    # Set window interval (sampling interval)
    if ! kubectl set env "deployment/$service" "WINDOW_INTERVAL_MS=${WINDOW_INTERVAL_MS:-100}"; then
        log "$exp_dir" "ERROR: Failed to set WINDOW_INTERVAL_MS for $service"
        return 1
    fi
    
    # Set perf events (use safe default if not specified)
    local perf_events_value="${PERF_EVENTS:-cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,dtlb-load-misses,itlb-load-misses,page-faults,minor-faults,major-faults,context-switches,cpu-migrations}"
    if ! kubectl set env "deployment/$service" "PERF_EVENTS=${perf_events_value}"; then
        log "$exp_dir" "ERROR: Failed to set PERF_EVENTS for $service"
        return 1
    fi
    
    # Set output directory
    if ! kubectl set env "deployment/$service" "OUTPUT_DIR=/data"; then
        log "$exp_dir" "ERROR: Failed to set OUTPUT_DIR for $service"
        return 1
    fi
    
    # Assign CPU set for this service (for taskset and perf monitoring)
    # Calculate CPU range based on service index
    local service_index=0
    for idx in "${!VALID_TIMING_SERVICES[@]}"; do
        if [[ "${VALID_TIMING_SERVICES[$idx]}" == "$service" ]]; then
            service_index=$idx
            break
        fi
    done
    
    local cpu_start=$((STARTING_CPU + service_index * CPUS_PER_SERVICE))
    local cpu_end=$((cpu_start + CPUS_PER_SERVICE - 1))
    local cpu_set=""
    for ((cpu=$cpu_start; cpu<=$cpu_end; cpu++)); do
        if [ -z "$cpu_set" ]; then
            cpu_set="$cpu"
        else
            cpu_set="$cpu_set,$cpu"
        fi
    done
    
    log "$exp_dir" "  Assigning CPU set for $service: $cpu_set"
    if ! kubectl set env "deployment/$service" "CPU_SET=${cpu_set}"; then
        log "$exp_dir" "ERROR: Failed to set CPU_SET for $service"
        return 1
    fi
    
    # Set ring buffer configuration (optional tuning parameters)
    local buffer_size="${TIMING_BUFFER_SIZE:-2048}"
    if ! kubectl set env "deployment/$service" "TIMING_BUFFER_SIZE=${buffer_size}"; then
        log "$exp_dir" "ERROR: Failed to set TIMING_BUFFER_SIZE for $service"
        return 1
    fi
    
    local flush_threshold="${TIMING_FLUSH_THRESHOLD:-80}"
    if ! kubectl set env "deployment/$service" "TIMING_FLUSH_THRESHOLD=${flush_threshold}"; then
        log "$exp_dir" "ERROR: Failed to set TIMING_FLUSH_THRESHOLD for $service"
        return 1
    fi
    
    log "$exp_dir" "Successfully updated deployment configuration for $service"
    log "$exp_dir" "  Windowed Sampling: enabled"
    log "$exp_dir" "  CPU Set: $cpu_set (taskset pinning + perf monitoring)"
    log "$exp_dir" "  Run Duration: ${EXPERIMENT_DURATION}s"
    log "$exp_dir" "  Window Interval: ${WINDOW_INTERVAL_MS}ms"
    log "$exp_dir" "  Perf Events: ${PERF_EVENTS}"
    log "$exp_dir" "  Ring Buffer: size=${buffer_size}, threshold=${flush_threshold}%"
    
    return 0
}

# Deploy timing-enabled service
deploy_timing_service() {
    local service="$1"
    local target_node="$2"
    local exp_dir="$3"
    
    log "$exp_dir" "Deploying timing-enabled $service service"
    
    # First deploy the regular service if it's not already deployed
    deploy_regular_service "$service" "$target_node" "$exp_dir"
    
    # Ensure timing image exists (build if needed)
    if ! ensure_timing_image_exists "$service" "$exp_dir"; then
        log "$exp_dir" "ERROR: Failed to ensure timing image exists for $service"
        return 1
    fi
    
    # Update deployment to use timing configuration
    if ! update_deployment_for_timing "$service" "$exp_dir"; then
        log "$exp_dir" "ERROR: Failed to update deployment for timing"
        return 1
    fi
    
    # Wait for rollout to complete
    log "$exp_dir" "Waiting for $service rollout to complete"
    log "$exp_dir" "Current pods before rollout:"
    kubectl get pods -l io.kompose.service="$service" -o wide | tee -a "$exp_dir/logs/collector.log"
    
    if kubectl rollout status deployment "$service" --timeout=300s; then
        log "$exp_dir" "Successfully deployed timing-enabled $service"
        
        # Verify the deployment
        log "$exp_dir" "Verifying timing configuration for $service"
        kubectl describe deployment "$service" | grep -A 5 Environment | tee -a "$exp_dir/logs/collector.log"
        
        return 0
    else
        log "$exp_dir" "ERROR: Rollout failed for $service"
        log "$exp_dir" "Current pods after rollout failure:"
        kubectl get pods -l io.kompose.service="$service" -o wide | tee -a "$exp_dir/logs/collector.log"
        log "$exp_dir" "Checking for pod events:"
        kubectl get events --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' | tail -10 | tee -a "$exp_dir/logs/collector.log"
        return 1
    fi
}

# Retrieve windowed run data from service pod
retrieve_windowed_run_data() {
    local service="$1"
    local exp_dir="$2"
    local iteration="$3"
    
    log "$exp_dir" "Retrieving windowed run data from $service (iteration $iteration)"
    
    # Get pod name
    local pod_name=$(kubectl get pods -l io.kompose.service="$service" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$pod_name" ]]; then
        log "$exp_dir" "WARNING: No pod found for service $service"
        return 1
    fi
    
    log "$exp_dir" "Found pod: $pod_name"
    
    # Create output directory
    local output_dir="$exp_dir/raw/windowed/${service}"
    mkdir -p "$output_dir"
    
    # Retrieve run data file for this iteration
    local run_file="/data/run_data_${service}_iter${iteration}.json"
    if kubectl exec "$pod_name" -- test -f "$run_file" 2>/dev/null; then
        log "$exp_dir" "  Retrieving run data: $run_file"
        kubectl exec "$pod_name" -- cat "$run_file" > "$output_dir/run_data_iter${iteration}_raw.json" 2>/dev/null
        
        if [[ -s "$output_dir/run_data_iter${iteration}_raw.json" ]]; then
            # Load iteration timing metadata
            local workload_start_file="$exp_dir/metadata/iteration_${iteration}_workload_start.txt"
            local iteration_end_file="$exp_dir/metadata/iteration_${iteration}_end.txt"
            
            local workload_start_ts=0
            local iteration_end_ts=0
            
            if [[ -f "$workload_start_file" ]]; then
                workload_start_ts=$(cat "$workload_start_file")
            fi
            if [[ -f "$iteration_end_file" ]]; then
                iteration_end_ts=$(cat "$iteration_end_file")
            fi
            
            # Filter samples using offset_ms
            # For iteration > 1, pod restarts and offset_ms counts from pod start
            # We need to filter to only include samples from workload start onwards
            if command -v jq >/dev/null 2>&1; then
                # Get run_start timestamp from the JSON (when pod/sampling started)
                local run_start_ts=$(jq -r '.run_start // ""' "$output_dir/run_data_iter${iteration}_raw.json" 2>/dev/null)
                
                # Calculate the offset_ms threshold (time from pod start to workload start)
                local offset_threshold_ms=0
                if [[ -n "$run_start_ts" && $workload_start_ts -gt 0 ]]; then
                    # Parse run_start timestamp to epoch seconds
                    local run_start_epoch=$(date -d "$run_start_ts" +%s 2>/dev/null || echo "0")
                    if [[ $run_start_epoch -gt 0 ]]; then
                        # Calculate offset: how many ms after pod start did workload start?
                        offset_threshold_ms=$(( (workload_start_ts - run_start_epoch) * 1000 ))
                        if [[ $offset_threshold_ms -lt 0 ]]; then
                            offset_threshold_ms=0
                        fi
                    fi
                fi
                
                # Calculate iteration duration for end threshold
                local iteration_duration_ms=0
                if [[ $iteration_end_ts -gt 0 && $workload_start_ts -gt 0 ]]; then
                    iteration_duration_ms=$(( (iteration_end_ts - workload_start_ts) * 1000 ))
                fi
                local offset_end_ms=$((offset_threshold_ms + iteration_duration_ms))
                
                log "$exp_dir" "  Filtering samples by offset_ms range"
                log "$exp_dir" "    Pod start (run_start): $run_start_ts"
                log "$exp_dir" "    Workload start offset: ${offset_threshold_ms}ms from pod start"
                log "$exp_dir" "    Iteration end offset: ${offset_end_ms}ms from pod start"
                
                if [[ $offset_threshold_ms -gt 0 || $offset_end_ms -gt 0 ]]; then
                    jq --argjson start_offset "$offset_threshold_ms" --argjson end_offset "$offset_end_ms" '{
                        service_name,
                        iteration_id,
                        run_start,
                        run_end,
                        run_duration_ms,
                        window_interval_ms,
                        perf_events,
                        filtering: {
                            applied: true,
                            method: "offset_ms based",
                            offset_start_ms: $start_offset,
                            offset_end_ms: $end_offset,
                            rationale: "Filtered to samples from workload start to iteration end, excluding pre-workload samples"
                        },
                        samples: [.samples[] | select(
                            .offset_ms >= $start_offset and 
                            .offset_ms <= $end_offset
                        ) | . + {
                            offset_from_workload_ms: (.offset_ms - $start_offset)
                        }],
                        sample_count: ([.samples[] | select(
                            .offset_ms >= $start_offset and 
                            .offset_ms <= $end_offset
                        )] | length),
                        samples_with_timing: ([.samples[] | select(
                            .offset_ms >= $start_offset and 
                            .offset_ms <= $end_offset and
                            (.timing_window.request_count > 0)
                        )] | length),
                        samples_idle: ([.samples[] | select(
                            .offset_ms >= $start_offset and 
                            .offset_ms <= $end_offset and
                            .timing_window.request_count == 0
                        )] | length),
                        aggregates: .aggregates
                    }' "$output_dir/run_data_iter${iteration}_raw.json" > "$output_dir/run_data_iter${iteration}.json"
                else
                    # Fallback: no offset filtering needed (iteration 1 or missing metadata)
                    log "$exp_dir" "    No offset filtering needed, keeping all samples"
                    jq '{
                        service_name,
                        iteration_id,
                        run_start,
                        run_end,
                        run_duration_ms,
                        window_interval_ms,
                        perf_events,
                        filtering: {
                            applied: false,
                            rationale: "No offset filtering needed (iteration 1 or missing metadata)"
                        },
                        samples: [.samples[] | . + {offset_from_workload_ms: .offset_ms}],
                        sample_count: (.samples | length),
                        samples_with_timing: ([.samples[] | select(.timing_window.request_count > 0)] | length),
                        samples_idle: ([.samples[] | select(.timing_window.request_count == 0)] | length),
                        aggregates: .aggregates
                    }' "$output_dir/run_data_iter${iteration}_raw.json" > "$output_dir/run_data_iter${iteration}.json"
                fi
                
                local total_samples=$(jq -r '.samples | length' "$output_dir/run_data_iter${iteration}_raw.json" 2>/dev/null || echo "0")
                local filtered_samples=$(jq -r '.sample_count // 0' "$output_dir/run_data_iter${iteration}.json" 2>/dev/null)
                local samples_with_timing=$(jq -r '.samples_with_timing // 0' "$output_dir/run_data_iter${iteration}.json" 2>/dev/null)
                local samples_idle=$(jq -r '.samples_idle // 0' "$output_dir/run_data_iter${iteration}.json" 2>/dev/null)
                
                log "$exp_dir" "  Filtered: $filtered_samples/$total_samples samples in experiment window"
                log "$exp_dir" "    Active samples (with requests): $samples_with_timing"
                log "$exp_dir" "    Idle samples (no requests): $samples_idle"
            else
                # No jq available, just copy raw file
                log "$exp_dir" "  WARNING: jq not available, copying all samples without filtering"
                cp "$output_dir/run_data_iter${iteration}_raw.json" "$output_dir/run_data_iter${iteration}.json"
                filtered_samples=$(grep -o '"sample_count":[^,}]*' "$output_dir/run_data_iter${iteration}.json" | cut -d':' -f2 | tr -d ' ' || echo "unknown")
            fi
            
            log "$exp_dir" "  Successfully retrieved run data with $filtered_samples samples"
            
            # Also get logs with timing and perf information
            local log_file="$output_dir/service_logs_iter${iteration}.txt"
            kubectl logs "$pod_name" | grep -E "(Windowed sampling|sample_id|perf_deltas|timing_window)" > "$log_file" 2>/dev/null || true
            
            return 0
        else
            log "$exp_dir" "  WARNING: Retrieved run data file is empty"
            return 1
        fi
    else
        log "$exp_dir" "  WARNING: Run data file not found in pod $pod_name: $run_file"
        # Check if there are any data files
        log "$exp_dir" "  Checking for any data files in /data/"
        kubectl exec "$pod_name" -- ls -la /data/ 2>/dev/null | tee -a "$exp_dir/logs/collector.log" || true
        return 1
    fi
}

# Update iteration ID and experiment duration for all victim services and restart pods
update_iteration_id() {
    local exp_dir="$1"
    local iteration="$2"
    local victim_services="$3"
    local experiment_duration="${4:-}"  # Optional: updated duration for this iteration
    
    log "$exp_dir" "Updating ITERATION_ID to $iteration for victim services"
    if [[ -n "$experiment_duration" ]]; then
        log "$exp_dir" "Updating EXPERIMENT_DURATION to ${experiment_duration}s"
    fi
    
    for service in $victim_services; do
        if validate_timing_service "$service"; then
            log "$exp_dir" "  Setting ITERATION_ID=$iteration for $service"
            
            if ! kubectl set env "deployment/$service" "ITERATION_ID=${iteration}"; then
                log "$exp_dir" "WARNING: Failed to set ITERATION_ID for $service"
                continue
            fi
            
            # Also update EXPERIMENT_DURATION if provided
            if [[ -n "$experiment_duration" ]]; then
                if ! kubectl set env "deployment/$service" "EXPERIMENT_DURATION=${experiment_duration}"; then
                    log "$exp_dir" "WARNING: Failed to set EXPERIMENT_DURATION for $service"
                fi
            fi
            
            # Restart pods to pick up new iteration ID
            log "$exp_dir" "  Restarting $service pods for new iteration"
            kubectl rollout restart "deployment/$service" 2>/dev/null || true
            kubectl rollout status "deployment/$service" --timeout=60s 2>/dev/null || log "$exp_dir" "WARNING: Timeout waiting for $service restart"
        fi
    done
    
    log "$exp_dir" "Iteration ID updated, waiting 20s for services to stabilize and initialize sampling"
    sleep 20
}

# Validate configuration
validate_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file"
        exit 1
    fi
    
    # Source shapes script FIRST so helper functions are available to config file
    if [[ -f "$SHAPES_SCRIPT" ]]; then
        source "$SHAPES_SCRIPT"
    fi
    
    source "$config_file"
    
    # Check required variables
    local required_vars=("EXPERIMENT_NAME" "TARGET_NODE" "VICTIM_SERVICES" "NOISY_NEIGHBOR_TYPE")
    
    # Check if using burst-based model or legacy single-duration model
    if [[ -n "${CONTENTION_BURSTS:-}" ]]; then
        # User-defined burst model
        echo "Using user-defined burst schedule model"
        echo "Burst schedule: ${CONTENTION_BURSTS}"
    elif [[ -n "${EXPERIMENT_DURATION:-}" ]]; then
        # Legacy single-duration model (backward compatibility)
        echo "Using legacy single-duration contention model (EXPERIMENT_DURATION=${EXPERIMENT_DURATION}s)"
    else
        echo "ERROR: Must specify either CONTENTION_BURSTS or EXPERIMENT_DURATION"
        exit 1
    fi
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            echo "ERROR: Required variable $var not set in config file"
            exit 1
        fi
    done
    
    # Check if scripts exist
    for script in "$STRESS_SCRIPT" "$TAINT_SCRIPT" "$SHAPES_SCRIPT"; do
        if [[ ! -f "$script" ]]; then
            echo "ERROR: Required script not found: $script"
            exit 1
        fi
    done
    
	# Set defaults for windowed sampling if not specified
	WINDOW_INTERVAL_MS="${WINDOW_INTERVAL_MS:-100}"
	# Safe default using only universally available counters
	PERF_EVENTS="${PERF_EVENTS:-cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,dtlb-load-misses,itlb-load-misses,page-faults,minor-faults,major-faults,context-switches,cpu-migrations}"
	ENABLE_WINDOWED_SAMPLING="${ENABLE_WINDOWED_SAMPLING:-true}"
	# Large buffer size for channel + ring buffer architecture
	TIMING_BUFFER_SIZE="${TIMING_BUFFER_SIZE:-16384}"
	
	# Burst-based model configuration
	if [[ -n "${CONTENTION_SHAPE:-}" ]]; then
		echo ""
		echo "Burst-based Contention Configuration:"
		echo "  Shape: ${CONTENTION_SHAPE}"
		echo "  Shape Args: ${CONTENTION_SHAPE_ARGS}"
		echo "  Randomize: ${CONTENTION_RANDOMIZE:-false}"
		if [[ "${CONTENTION_RANDOMIZE:-false}" == "true" ]]; then
			echo "  Random Seed: ${CONTENTION_RANDOM_SEED:-auto}"
		fi
		
		# Calculate estimated duration
		local test_bursts=$(generate_shape "$CONTENTION_SHAPE" ${CONTENTION_SHAPE_ARGS})
		local est_duration=$(calculate_iteration_duration "$test_bursts")
		echo "  Estimated iteration duration: ~${est_duration}s (varies per iteration)"
		echo "  Burst schedule preview: $test_bursts"
	fi
	
	echo ""
	echo "Windowed Sampling Configuration:"
	echo "  Window Interval: ${WINDOW_INTERVAL_MS}ms"
	echo "  Perf Events: ${PERF_EVENTS}"
	if [[ -n "${CONTENTION_SHAPE:-}" ]]; then
		echo "  Note: Samples collected for entire iteration duration (including idle periods)"
	else
	echo "  Expected samples per run: $((EXPERIMENT_DURATION * 1000 / WINDOW_INTERVAL_MS))"
	fi
	echo "  Ring Buffer: size=${TIMING_BUFFER_SIZE}"
	echo "  Architecture: non-blocking channel → consumer goroutine → ring buffer → window flush"
    
    # Validate target node exists
    if ! kubectl get node "$TARGET_NODE" &>/dev/null; then
        echo "ERROR: Target node $TARGET_NODE not found"
        exit 1
    fi
    
    # Check if wrk2 exists
    if [[ -n "${WRK2_TARGET_SERVICE:-}" && ! -f "$WRK2_DIR/wrk" ]]; then
        echo "WARNING: wrk2 not found at: $WRK2_DIR/wrk (will skip workload generation)"
    fi
    
    # Check Docker access for timing image building (if needed)
    if ! docker info &>/dev/null; then
        echo "WARNING: Docker is not accessible. Timing images cannot be built automatically."
        echo "Please ensure timing images exist in registry or make Docker available."
    fi
    
    # Validate victim services for timing integration
    local timing_services=""
    for service in $VICTIM_SERVICES; do
        if validate_timing_service "$service"; then
            timing_services="$timing_services $service"
        else
            echo "WARNING: Service '$service' is not supported for timing integration (will use regular deployment)"
        fi
    done
    
    if [[ -n "$timing_services" ]]; then
        echo "Timing integration will be enabled for:$timing_services"
    else
        echo "No victim services support timing integration - running without timing data collection"
    fi
    
    echo "Configuration validation passed"
}

# Cleanup any existing stress pods
cleanup_existing_stress_pods() {
    local exp_dir="$1"
    
    log "$exp_dir" "Cleaning up any existing stress pods..."
    
    # Clean up stress pods (both running and completed)
    local stress_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running -o name 2>/dev/null | grep -E "(stress|cpu-stress|mem-stress|io-stress)" || echo "")
    local running_stress_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running -o name 2>/dev/null | grep -E "(stress|cpu-stress|mem-stress|io-stress)" || echo "")
    
    # Delete completed/failed stress pods
    if [[ -n "$stress_pods" ]]; then
        echo "$stress_pods" | while read -r pod; do
            if [[ -n "$pod" ]]; then
                log "$exp_dir" "  Deleting completed/failed stress pod: $pod"
                kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
            fi
        done
    fi
    
    # Delete running stress pods
    if [[ -n "$running_stress_pods" ]]; then
        echo "$running_stress_pods" | while read -r pod; do
            if [[ -n "$pod" ]]; then
                log "$exp_dir" "  Deleting running stress pod: $pod"
                kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
            fi
        done
    fi
    
    # Also run the stress script cleanup
    if [[ -f "$STRESS_SCRIPT" ]]; then
        log "$exp_dir" "Running stress script cleanup..."
        "$STRESS_SCRIPT" cleanup 2>/dev/null || log "$exp_dir" "  Warning: Stress script cleanup failed"
    fi
    
    log "$exp_dir" "Stress pod cleanup completed"
}

# Check and untolerate existing pods on target node
check_and_untolerate_pods() {
    local target_node="$1"
    local exp_dir="$2"
    
    log "$exp_dir" "Checking existing user deployments on target node: $target_node"
    
    # Get only deployments in default namespace that have pods on the target node
    local deployments_to_untolerate=()
    
    # Get all deployments in default namespace
    local deployments=$(kubectl get deployments -n default -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    
    if [[ -n "$deployments" ]]; then
        while read -r deployment; do
            if [[ -n "$deployment" ]]; then
                # Check if this deployment has pods on the target node
                # Try both common label patterns: app= and io.kompose.service=
                local pods_on_node=$(kubectl get pods -n default -l io.kompose.service="$deployment" --field-selector=spec.nodeName="$target_node" -o name 2>/dev/null | wc -l)
                if [[ "$pods_on_node" -eq 0 ]]; then
                    # Fallback to app label if no pods found with io.kompose.service
                    pods_on_node=$(kubectl get pods -n default -l app="$deployment" --field-selector=spec.nodeName="$target_node" -o name 2>/dev/null | wc -l)
                fi
                if [[ "$pods_on_node" -gt 0 ]]; then
                    deployments_to_untolerate+=("$deployment")
                    log "$exp_dir" "  Found deployment '$deployment' with $pods_on_node pod(s) on $target_node"
                fi
            fi
        done <<< "$deployments"
    fi
    
    if [[ ${#deployments_to_untolerate[@]} -gt 0 ]]; then
        log "$exp_dir" "Untolerating ${#deployments_to_untolerate[@]} deployment(s) to clear target node..."
        
        for deployment in "${deployments_to_untolerate[@]}"; do
            log "$exp_dir" "  Untolerating deployment: $deployment"
            "$TAINT_SCRIPT" "$target_node" "$deployment" --untolerate 2>/dev/null || log "$exp_dir" "    Warning: Failed to untolerate $deployment (may not have tolerations)"
            
            # Add node anti-affinity to prevent scheduling back on target node
            log "$exp_dir" "  Adding anti-affinity to keep $deployment away from $target_node"
            kubectl patch deployment "$deployment" -n default --type='merge' -p "{
              \"spec\": {
                \"template\": {
                  \"spec\": {
                    \"affinity\": {
                      \"nodeAffinity\": {
                        \"requiredDuringSchedulingIgnoredDuringExecution\": {
                          \"nodeSelectorTerms\": [{
                            \"matchExpressions\": [{
                              \"key\": \"kubernetes.io/hostname\",
                              \"operator\": \"NotIn\",
                              \"values\": [\"$target_node\"]
                            }]
                          }]
                        }
                      }
                    }
                  }
                }
              }
            }" 2>/dev/null || log "$exp_dir" "    Warning: Failed to add anti-affinity to $deployment"
        done
        
        # Wait for pods to be rescheduled
        log "$exp_dir" "Waiting for pods to be rescheduled away from $target_node..."
        sleep 30
        
        # Check if any pods are still on the target node and force restart if needed
        for deployment in "${deployments_to_untolerate[@]}"; do
            # Use reliable method to check if deployment pods are still on target node
            local remaining_pods=$(kubectl get pods -n default -l io.kompose.service="$deployment" -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
            if [[ "$remaining_pods" -eq 0 ]]; then
                # Fallback to app label
                remaining_pods=$(kubectl get pods -n default -l app="$deployment" -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
            fi
            if [[ "$remaining_pods" -gt 0 ]]; then
                log "$exp_dir" "  $deployment still has $remaining_pods pod(s) on $target_node, forcing restart..."
                kubectl rollout restart deployment "$deployment" -n default 2>/dev/null || log "$exp_dir" "    Warning: Failed to restart $deployment"
            fi
        done
        
        # Final wait for rollouts to complete
        log "$exp_dir" "Waiting for rollouts to complete..."
        for deployment in "${deployments_to_untolerate[@]}"; do
            kubectl rollout status deployment "$deployment" -n default --timeout=60s 2>/dev/null || log "$exp_dir" "    Warning: Timeout waiting for $deployment rollout"
        done
        
        # Save list of untolerated deployments for cleanup
        echo "${deployments_to_untolerate[@]}" > "$exp_dir/metadata/untolerated_deployments.txt"
        
        # Verify target node is clear and wait if needed
        local max_attempts=6
        local attempt=1
        while [[ $attempt -le $max_attempts ]]; do
            # Use a more reliable method: get pods with wide output and grep for the target node
            local final_user_pods=$(kubectl get pods -n default -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
            log "$exp_dir" "Attempt $attempt/$max_attempts: Target node $target_node has $final_user_pods running user pod(s) in default namespace"
            
            # Also show which pods are still on the target node for debugging
            local pods_on_target=$(kubectl get pods -n default -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | awk '{print $1}' | tr '\n' ' ')
            if [[ -n "$pods_on_target" ]]; then
                log "$exp_dir" "  Pods still on $target_node: $pods_on_target"
            fi
            
            if [[ $final_user_pods -eq 0 ]]; then
                log "$exp_dir" " Target node $target_node is now clear of user pods"
                break
            fi
            
            if [[ $attempt -lt $max_attempts ]]; then
                log "$exp_dir" "Waiting 15s for remaining pods to reschedule..."
                sleep 15
            else
                log "$exp_dir" "WARNING: Target node still has $final_user_pods user pods after $max_attempts attempts"
                # Force one more round of restarts for any remaining deployments
                for deployment in "${deployments_to_untolerate[@]}"; do
                    local remaining=$(kubectl get pods -n default -l io.kompose.service="$deployment" -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
                    if [[ $remaining -eq 0 ]]; then
                        # Fallback to app label
                        remaining=$(kubectl get pods -n default -l app="$deployment" -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
                    fi
                    if [[ $remaining -gt 0 ]]; then
                        log "$exp_dir" "  Force restarting $deployment (still has $remaining pod(s) on $target_node)"
                        kubectl rollout restart deployment "$deployment" -n default 2>/dev/null
                    fi
                done
            fi
            ((attempt++))
        done
        
    else
        log "$exp_dir" "No user deployments found on target node $target_node"
    fi
}

# Reset non-victim services to default images
# This ensures previous experiments don't contaminate the current one
reset_non_victim_services() {
    local victim_services="$1"
    local exp_dir="$2"
    
    log "$exp_dir" "Resetting non-victim services to default images..."
    
    # List of all hotel reservation services
    local all_services=(
        "frontend"
        "search" 
        "geo"
        "profile"
        "rate"
        "recommendation"
        "reservation"
        "user"
    )
    
    # Convert victim services string to array for comparison
    local victim_array=($victim_services)
    
    # Reset each non-victim service to default image
    local reset_count=0
    for service in "${all_services[@]}"; do
        # Check if this service is a victim
        local is_victim=false
        for victim in "${victim_array[@]}"; do
            if [[ "$service" == "$victim" ]]; then
                is_victim=true
                break
            fi
        done
        
        # Skip if this is a victim service (will be handled by deploy_victim_services)
        if [[ "$is_victim" == "true" ]]; then
            log "$exp_dir" "  Skipping $service (victim service, will be deployed separately)"
            continue
        fi
        
        # Check if deployment exists
        if ! kubectl get deployment "$service" &>/dev/null; then
            log "$exp_dir" "  Skipping $service (deployment not found)"
            continue
        fi
        
        # Get current image
        local current_image=$(kubectl get deployment "$service" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
        
        if [[ -z "$current_image" ]]; then
            log "$exp_dir" "  WARNING: Could not get current image for $service"
            continue
        fi
        
        # Check if currently using a windowed/timing image
        if [[ "$current_image" == *"-windowed:"* ]] || [[ "$current_image" == *"/windowed"* ]]; then
            # Default hotel-reservation image (standard for all services)
            local default_image="deathstarbench/hotel-reservation:latest"
            
            log "$exp_dir" "  Resetting $service: $current_image -> $default_image"
            local container_name=$(get_container_name "$service")
            
            if kubectl set image "deployment/$service" "$container_name=$default_image" 2>/dev/null; then
                log "$exp_dir" "    Successfully reset $service to default image"
                ((reset_count++))
                
                # Remove windowed sampling env vars if present
                kubectl set env "deployment/$service" ENABLE_WINDOWED_SAMPLING- ITERATION_ID- 2>/dev/null || true
            else
                log "$exp_dir" "    WARNING: Failed to reset image for $service"
            fi
        else
            # Check if already using the correct default image
            if [[ "$current_image" == "deathstarbench/hotel-reservation:latest" ]]; then
                log "$exp_dir" "  $service already using default image"
            else
                log "$exp_dir" "  $service using non-standard image: $current_image (leaving as-is)"
            fi
        fi
    done
    
    if [[ $reset_count -gt 0 ]]; then
        log "$exp_dir" "Reset $reset_count non-victim services to default images. Waiting for rollouts..."
        
        # Wait for all rollouts to complete
        for service in "${all_services[@]}"; do
            local is_victim=false
            for victim in "${victim_array[@]}"; do
                if [[ "$service" == "$victim" ]]; then
                    is_victim=true
                    break
                fi
            done
            
            if [[ "$is_victim" == "false" ]] && kubectl get deployment "$service" &>/dev/null; then
                kubectl rollout status deployment/"$service" --timeout=120s 2>/dev/null || \
                    log "$exp_dir" "    WARNING: Rollout timeout for $service"
            fi
        done
        
        log "$exp_dir" "Non-victim services reset complete"
    else
        log "$exp_dir" "No non-victim services needed resetting"
    fi
}

# Deploy victim services on target node
deploy_victim_services() {
    local services="$1"
    local target_node="$2"
    local exp_dir="$3"
    
    log "$exp_dir" "Deploying victim services: $services"
    
    # Remove anti-affinity rules from victim services before deploying to target node
    log "$exp_dir" "Removing anti-affinity rules from victim services: $services"
    remove_anti_affinity "$services" "$exp_dir"
    sleep 5  # Wait for affinity rules to be removed
    
    for service in $services; do
        # Check if windowed sampling is enabled and this service supports timing integration
        if [[ "${ENABLE_WINDOWED_SAMPLING:-true}" == "true" ]] && validate_timing_service "$service"; then
            log "$exp_dir" "Deploying timing-enabled $service with windowed sampling"
            if ! deploy_timing_service "$service" "$target_node" "$exp_dir"; then
                log "$exp_dir" "ERROR: Failed to deploy timing-enabled $service, falling back to regular deployment"
                # Fall back to regular deployment
                deploy_regular_service "$service" "$target_node" "$exp_dir"
            fi
        else
            # Deploy regular service (either windowed sampling is disabled or service doesn't support it)
            if validate_timing_service "$service" && [[ "${ENABLE_WINDOWED_SAMPLING:-true}" != "true" ]]; then
                log "$exp_dir" "Deploying regular $service (windowed sampling disabled)"
            else
                log "$exp_dir" "Deploying regular $service"
            fi
            deploy_regular_service "$service" "$target_node" "$exp_dir"
        fi
    done
    
    # Record deployed services
    echo "$services" > "$exp_dir/metadata/deployed_services.txt"
}

# Deploy regular service (original logic)
deploy_regular_service() {
    local service="$1"
    local target_node="$2"
    local exp_dir="$3"
    
    local service_dir="../kubernetes/${service}"
    
    if [[ ! -d "$service_dir" ]]; then
        log "$exp_dir" "WARNING: Service directory not found for $service: $service_dir"
        return 1
    fi
    
    log "$exp_dir" "Deploying $service from $service_dir..."
    
    # Apply all YAML files in the service directory
    if ls "$service_dir"/*.yaml 1> /dev/null 2>&1; then
        kubectl apply -f "$service_dir/"
        
        # Add toleration and node selector to the deployment
        "$TAINT_SCRIPT" "$target_node" "$service"
        
        # Wait for deployment to be ready
        kubectl rollout status deployment "$service" --timeout=120s
        
        log "$exp_dir" "Service $service deployed and ready"
        return 0
    else
        log "$exp_dir" "WARNING: No YAML files found in $service_dir"
        return 1
    fi
}

# Configure Jaeger tracing for all hotel reservation services
configure_jaeger_tracing() {
    local exp_dir="$1"
    
    # Get sampling rate from config or use default
    local sampling_rate="${JAEGER_SAMPLE_RATIO:-0.01}"
    
    # Skip Jaeger configuration if sampling rate is 0
    if [[ "$sampling_rate" == "0" || "$sampling_rate" == "0.0" ]]; then
        log "$exp_dir" "Jaeger sampling rate is 0 - skipping Jaeger configuration"
        echo "=== JAEGER CONFIGURATION ===" > "$exp_dir/metadata/jaeger_config.txt"
        echo "Skipped at: $(date -Iseconds)" >> "$exp_dir/metadata/jaeger_config.txt"
        echo "Reason: Sampling rate set to 0" >> "$exp_dir/metadata/jaeger_config.txt"
        echo "Sampling rate: $sampling_rate" >> "$exp_dir/metadata/jaeger_config.txt"
        return 0
    fi
    
    log "$exp_dir" "Configuring Jaeger tracing for all hotel reservation services..."
    log "$exp_dir" "Using Jaeger sampling rate: $sampling_rate"
    
    # Temporarily disable exit on error for Jaeger configuration
    set +e
    
    # List of all hotel reservation services that need Jaeger configuration
    local all_services=(
        "frontend"
        "search" 
        "geo"
        "profile"
        "rate"
        "recommendation"
        "reservation"
        "user"
        "review"
        "attractions"
    )
    
    # Wait for all deployments to be available before configuring
    log "$exp_dir" "Waiting for deployments to be ready before Jaeger configuration..."
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            kubectl wait --for=condition=available --timeout=300s deployment/"$service" 2>/dev/null || \
                log "$exp_dir" "WARNING: Timeout waiting for $service deployment"
        fi
    done
    
    # Configure each service
    local configured_count=0
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            log "$exp_dir" "Configuring Jaeger for $service..."
            
            # Set HTTP collector endpoint
            if kubectl set env deployment/"$service" JAEGER_ENDPOINT=http://jaeger:14268/api/traces 2>/dev/null; then
                log "$exp_dir" "   Set JAEGER_ENDPOINT for $service"
            else
                log "$exp_dir" "   WARNING: Failed to set JAEGER_ENDPOINT for $service"
            fi
            
            # Set sampling rate
            if kubectl set env deployment/"$service" JAEGER_SAMPLE_RATIO="$sampling_rate" 2>/dev/null; then
                log "$exp_dir" "   Set JAEGER_SAMPLE_RATIO for $service"
            else
                log "$exp_dir" "   WARNING: Failed to set JAEGER_SAMPLE_RATIO for $service"
            fi
            
            # Remove UDP agent configuration
            if kubectl set env deployment/"$service" JAEGER_AGENT_HOST- 2>/dev/null; then
                log "$exp_dir" "   Removed JAEGER_AGENT_HOST for $service"
            else
                log "$exp_dir" "   WARNING: Failed to remove JAEGER_AGENT_HOST for $service (may not exist)"
            fi
            
            ((configured_count++))
        else
            log "$exp_dir" "Service $service not found, skipping Jaeger configuration"
        fi
    done
    
    log "$exp_dir" "Jaeger environment variables set for $configured_count services. Waiting for rollouts..."
    
    # Wait for all rollouts to complete
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            kubectl rollout status deployment/"$service" --timeout=120s 2>/dev/null || \
                log "$exp_dir" "WARNING: Rollout timeout for $service"
        fi
    done
    
    # Verify all services are actually running and ready
    log "$exp_dir" "Verifying all services are running after Jaeger configuration..."
    local failed_services=()
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            local ready_replicas=$(kubectl get deployment "$service" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired_replicas=$(kubectl get deployment "$service" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            
            if [[ "$ready_replicas" == "$desired_replicas" && "$ready_replicas" != "0" ]]; then
                log "$exp_dir" "   $service: $ready_replicas/$desired_replicas pods ready"
            else
                log "$exp_dir" "   $service: $ready_replicas/$desired_replicas pods ready (FAILED)"
                failed_services+=("$service")
            fi
        fi
    done
    
    # If services failed, try to recover them
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log "$exp_dir" "Attempting to recover failed services: ${failed_services[*]}"
        for service in "${failed_services[@]}"; do
            log "$exp_dir" "  Checking $service pods..."
            kubectl get pods -l app="$service" -o wide
            
            # Try restarting failed service
            log "$exp_dir" "  Restarting $service..."
            kubectl rollout restart deployment/"$service" 2>/dev/null
            kubectl rollout status deployment/"$service" --timeout=60s 2>/dev/null || \
                log "$exp_dir" "  WARNING: Recovery timeout for $service"
        done
        
        # Additional wait for recovery
        sleep 30
    fi
    
    log "$exp_dir" "Waiting for services to stabilize after Jaeger configuration..."
    sleep 45  # Increased from 30s to 45s
    
    # Enhanced service registration validation and monitoring
    log "$exp_dir" "Validating service registration in Consul..."
    if ! validate_and_ensure_service_registration "$exp_dir" 3; then
        log "$exp_dir" "WARNING: Service registration validation failed, performing refresh..."
        refresh_consul_service_discovery "$exp_dir"
        
        # If still failing after refresh, try manual registration as fallback
        if ! validate_and_ensure_service_registration "$exp_dir" 1; then
            log "$exp_dir" "WARNING: Consul refresh failed, attempting manual service registration..."
            manual_register_all_services "$exp_dir"
        fi
    else
        log "$exp_dir" " All services properly registered, skipping unnecessary Consul restart"
    fi
    
    # Verification
    log "$exp_dir" "Verifying Jaeger configuration..."
    
    # Check sampling rate on a few key services
    for service in "frontend" "search"; do
        if kubectl get deployment "$service" &>/dev/null; then
            local sample_log=$(kubectl logs deployment/"$service" 2>/dev/null | grep "sample ratio" | tail -1)
            if [[ -n "$sample_log" ]]; then
                log "$exp_dir" "  $service: $sample_log"
            else
                log "$exp_dir" "  $service: No sample ratio log found"
            fi
        fi
    done
    
    # Check Jaeger service registration
    local jaeger_services=$(kubectl exec -it deployment/jaeger -- wget -qO- "http://localhost:16686/api/services" 2>/dev/null | grep -o '"[^"]*"' | grep -v "data\|total\|limit\|offset\|errors" | head -5)
    if [[ -n "$jaeger_services" ]]; then
        log "$exp_dir" "  Registered services in Jaeger: $jaeger_services"
    else
        log "$exp_dir" "  WARNING: Could not verify Jaeger service registration"
    fi
    
    # Test connectivity with a simple request
    local connectivity_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
    if [[ "$connectivity_test" == "200" ]]; then
        log "$exp_dir" "  Frontend connectivity test passed (HTTP 200)"
    else
        log "$exp_dir" "  Frontend connectivity test failed (HTTP $connectivity_test)"
    fi
    
    log "$exp_dir" "Jaeger configuration completed. Services ready for tracing experiments."
    
    # Re-enable exit on error
    set -e
    
    # Save configuration details to metadata
    {
        echo "=== JAEGER CONFIGURATION ==="
        echo "Configured at: $(date -Iseconds)"
        echo "Sampling rate: $sampling_rate"
        echo "Services configured: $configured_count"
        echo "Endpoint: http://jaeger:14268/api/traces"
        echo ""
        echo "Configured services:"
        for service in "${all_services[@]}"; do
            if kubectl get deployment "$service" &>/dev/null; then
                echo "  - $service"
            fi
        done
    } > "$exp_dir/metadata/jaeger_config.txt"
}

# Monitor and validate Consul service registration
monitor_consul_service_registration() {
    local exp_dir="$1"
    local max_wait_time="${2:-120}"  # Maximum wait time in seconds
    local check_interval="${3:-10}"  # Check interval in seconds
    
    log "$exp_dir" "Monitoring Consul service registration..."
    
    # Check if Consul is available
    if ! kubectl get deployment consul &>/dev/null; then
        log "$exp_dir" "WARNING: Consul deployment not found, skipping service registration monitoring"
        return 1
    fi
    
    local expected_services=("srv-search" "srv-geo" "srv-profile" "srv-rate" "srv-recommendation" "srv-reservation" "srv-user")
    local wait_time=0
    local all_registered=false
    
    while [[ $wait_time -lt $max_wait_time && "$all_registered" == "false" ]]; do
        # Get current service registrations
        local consul_services=$(kubectl exec -it deployment/consul -- consul catalog services 2>/dev/null | grep -E "srv-" | tr -d '\r' | head -10)
        local registered_count=0
        local missing_services=()
        
        if [[ -n "$consul_services" ]]; then
            registered_count=$(echo "$consul_services" | wc -l)
            
            # Check for missing services
            for expected in "${expected_services[@]}"; do
                if ! echo "$consul_services" | grep -q "$expected"; then
                    missing_services+=("$expected")
                fi
            done
            
            if [[ ${#missing_services[@]} -eq 0 ]]; then
                log "$exp_dir" "   All ${#expected_services[@]} expected services are registered in Consul"
                all_registered=true
                break
            else
                log "$exp_dir" "  Progress: $registered_count/${#expected_services[@]} services registered. Missing: ${missing_services[*]}"
            fi
        else
            log "$exp_dir" "  No services found in Consul registry yet"
        fi
        
        if [[ "$all_registered" == "false" ]]; then
            sleep $check_interval
            wait_time=$((wait_time + check_interval))
        fi
    done
    
    if [[ "$all_registered" == "true" ]]; then
        log "$exp_dir" " Service registration monitoring completed successfully"
        return 0
    else
        log "$exp_dir" " Service registration monitoring failed - not all services registered after ${max_wait_time}s"
        
        # Log final state for debugging
        log "$exp_dir" "Final Consul service state:"
        kubectl exec -it deployment/consul -- consul catalog services 2>/dev/null | while read -r service; do
            log "$exp_dir" "    $service"
        done
        
        return 1
    fi
}

# Enhanced service registration validation with retry logic
validate_and_ensure_service_registration() {
    local exp_dir="$1"
    local max_attempts="${2:-3}"
    
    log "$exp_dir" "Validating and ensuring all services are registered in Consul..."
    
    local expected_services=("srv-search" "srv-geo" "srv-profile" "srv-rate" "srv-recommendation" "srv-reservation" "srv-user")
    
    for attempt in $(seq 1 $max_attempts); do
        log "$exp_dir" "Validation attempt $attempt/$max_attempts"
        
        # Check current registrations
        local consul_services=$(kubectl exec -it deployment/consul -- consul catalog services 2>/dev/null | grep -E "srv-" | tr -d '\r' | head -10)
        local missing_services=()
        
        if [[ -n "$consul_services" ]]; then
            local registered_count=$(echo "$consul_services" | wc -l)
            log "$exp_dir" "  Currently registered: $registered_count services"
            
            # Check for missing services
            for expected in "${expected_services[@]}"; do
                if ! echo "$consul_services" | grep -q "$expected"; then
                    missing_services+=("$expected")
                fi
            done
            
            if [[ ${#missing_services[@]} -eq 0 ]]; then
                log "$exp_dir" "   All services are properly registered"
                
                # Test connectivity to ensure services are actually reachable
                log "$exp_dir" "  Testing service connectivity..."
                local connectivity_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/recommendations?require=price&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
                if [[ "$connectivity_test" == "200" ]]; then
                    log "$exp_dir" "   Service connectivity test passed (HTTP 200)"
                    return 0
                else
                    log "$exp_dir" "   Service connectivity test failed (HTTP $connectivity_test)"
                    if [[ $attempt -lt $max_attempts ]]; then
                        log "$exp_dir" "  Will retry service registration..."
                    fi
                fi
            else
                log "$exp_dir" "  Missing services in Consul: ${missing_services[*]}"
            fi
        else
            log "$exp_dir" "  No services found in Consul registry"
        fi
        
        # If not the last attempt, try to fix registration issues
        if [[ $attempt -lt $max_attempts ]]; then
            log "$exp_dir" "  Attempting to fix service registration issues..."
            
            # Restart services that should be registered but aren't
            for missing in "${missing_services[@]}"; do
                local service_name=${missing#srv-}  # Remove srv- prefix
                if kubectl get deployment "$service_name" &>/dev/null; then
                    log "$exp_dir" "    Restarting $service_name to trigger re-registration..."
                    kubectl rollout restart deployment/"$service_name" 2>/dev/null
                fi
            done
            
            # Wait for services to restart and register
            log "$exp_dir" "  Waiting 90s for services to restart and register..."
            sleep 90
            
            # Monitor registration progress with extended timeout
            monitor_consul_service_registration "$exp_dir" 120 10
        fi
    done
    
    log "$exp_dir" " Service registration validation failed after $max_attempts attempts"
    return 1
}

# Manual registration of all services as fallback
manual_register_all_services() {
    local exp_dir="$1"
    
    log "$exp_dir" "Performing manual registration of all services..."
    
    # Check if Consul is available
    if ! kubectl get deployment consul &>/dev/null; then
        log "$exp_dir" "ERROR: Consul deployment not found, cannot perform manual registration"
        return 1
    fi
    
    # Get Consul pod
    local consul_pod=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$consul_pod" ]]; then
        log "$exp_dir" "ERROR: Could not find Consul pod"
        return 1
    fi
    
    # List of services to register manually (frontend doesn't register with Consul)
    local services_to_register=(
        "search:srv-search:8082"
        "geo:srv-geo:8083"
        "profile:srv-profile:8081"
        "rate:srv-rate:8084"
        "recommendation:srv-recommendation:8085"
        "reservation:srv-reservation:8087"
        "user:srv-user:8086"
    )
    
    local registered_count=0
    
    for service_info in "${services_to_register[@]}"; do
        IFS=':' read -r service_name consul_name port <<< "$service_info"
        
        # Get service IP
        local service_ip=$(kubectl get pod -l io.kompose.service="$service_name" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
        
        if [[ -n "$service_ip" ]]; then
            log "$exp_dir" "  Registering $consul_name at $service_ip:$port"
            
            # Register service without health checks to avoid deregistration
            if kubectl exec -it "$consul_pod" -- consul services register \
                -name="$consul_name" \
                -port="$port" \
                -address="$service_ip" \
                -id="manual-$service_name" 2>/dev/null; then
                
                log "$exp_dir" "    Successfully registered $consul_name"
                ((registered_count++))
            else
                log "$exp_dir" "    Failed to register $consul_name"
            fi
        else
            log "$exp_dir" "  Skipping $service_name - no pod found or not ready"
        fi
    done
    
    log "$exp_dir" "Manual registration completed: $registered_count/${#services_to_register[@]} services registered"
    
    # Wait for registration to propagate
    sleep 10
    
    # Verify registration
    local final_services=$(kubectl exec -it "$consul_pod" -- consul catalog services 2>/dev/null | grep -E "srv-" | wc -l)
    log "$exp_dir" "  Final service count in Consul: $final_services"
    
    if [[ $final_services -ge 7 ]]; then
        log "$exp_dir" " Manual registration successful"
        return 0
    else
        log "$exp_dir" " Manual registration partially failed"
        return 1
    fi
}

# Lightweight Consul service discovery refresh (no restarts)
refresh_consul_service_discovery() {
    local exp_dir="$1"
    
    log "$exp_dir" "Performing lightweight Consul service discovery refresh..."
    
    # Check if Consul is available
    if ! kubectl get deployment consul &>/dev/null; then
        log "$exp_dir" "WARNING: Consul deployment not found, skipping service discovery refresh"
        return 0
    fi
    
    # First, validate current service registration without any restarts
    if validate_and_ensure_service_registration "$exp_dir" 1; then
        log "$exp_dir" " All services already properly registered, no refresh needed"
        return 0
    fi
    
    log "$exp_dir" "Service registration issues detected, performing refresh..."
    
    # Restart all services to force re-registration (more aggressive approach)
    log "$exp_dir" "Restarting all services to force fresh registration..."
    
    local all_services=("search" "geo" "profile" "rate" "recommendation" "reservation" "user")
    
    # Restart services in dependency order
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            log "$exp_dir" "  Restarting $service..."
            kubectl rollout restart deployment/"$service" 2>/dev/null
        fi
    done
    
    # Wait for all services to be ready
    log "$exp_dir" "Waiting for all services to be ready..."
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            kubectl rollout status deployment/"$service" --timeout=90s 2>/dev/null || \
                log "$exp_dir" "  WARNING: $service restart timeout"
        fi
    done
    
    # Then restart Consul to ensure clean state
    log "$exp_dir" "Restarting Consul after services are ready..."
    kubectl rollout restart deployment/consul 2>/dev/null
    kubectl rollout status deployment/consul --timeout=60s 2>/dev/null || \
        log "$exp_dir" "  WARNING: Consul restart timeout"
    
    # Wait for Consul to be fully ready and services to re-register
    log "$exp_dir" "Waiting for Consul to stabilize and services to re-register..."
    sleep 45
    
    # Monitor service registration with extended timeout
    if monitor_consul_service_registration "$exp_dir" 120 10; then
        log "$exp_dir" " Service registration refresh completed successfully"
    else
        log "$exp_dir" " Service registration refresh failed"
        return 1
    fi
    
    # Additional wait for connections to fully stabilize
    log "$exp_dir" "Allowing additional time for service connections to stabilize..."
    sleep 30
    
    # Final connectivity verification
    log "$exp_dir" "Verifying service connectivity after refresh..."
    local connectivity_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
    if [[ "$connectivity_test" == "200" ]]; then
        log "$exp_dir" "   Service connectivity verified (HTTP 200)"
    else
        log "$exp_dir" "   Service connectivity test failed (HTTP $connectivity_test)"
    fi
    
    # Save refresh details to metadata
    {
        echo "=== CONSUL SERVICE DISCOVERY REFRESH ==="
        echo "Refreshed at: $(date -Iseconds)"
        echo "Method: Consul restart only (preserves service pods and Jaeger config)"
        echo "Consul restarted: Yes"
        echo "Service pods restarted: No"
        echo "Final connectivity test: HTTP $connectivity_test"
        echo "Total wait time: ~80s (30s + 30s + monitoring time)"
    } > "$exp_dir/metadata/consul_refresh.txt"
    
    log "$exp_dir" "Consul service discovery refresh completed"
}

# Comprehensive system readiness validation
validate_system_readiness() {
    local exp_dir="$1"
    
    log "$exp_dir" "=== COMPREHENSIVE SYSTEM READINESS VALIDATION ==="
    
    local validation_failed=false
    
    # 1. Validate all expected services are running
    log "$exp_dir" "1. Validating service deployments..."
    local expected_services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
    local failed_deployments=()
    
    for service in "${expected_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            local ready_replicas=$(kubectl get deployment "$service" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired_replicas=$(kubectl get deployment "$service" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            
            if [[ "$ready_replicas" == "$desired_replicas" && "$ready_replicas" != "0" ]]; then
                log "$exp_dir" "    $service: $ready_replicas/$desired_replicas pods ready"
            else
                log "$exp_dir" "    $service: $ready_replicas/$desired_replicas pods ready (FAILED)"
                failed_deployments+=("$service")
                validation_failed=true
            fi
        else
            log "$exp_dir" "    $service: deployment not found (FAILED)"
            failed_deployments+=("$service")
            validation_failed=true
        fi
    done
    
    # 2. Validate Consul service registration
    log "$exp_dir" "2. Validating Consul service registration..."
    local consul_services=$(kubectl exec -it deployment/consul -- consul catalog services 2>/dev/null | grep -E "srv-" | tr -d '\r' | head -10)
    local expected_consul_services=("srv-search" "srv-geo" "srv-profile" "srv-rate" "srv-recommendation" "srv-reservation" "srv-user")
    local missing_consul_services=()
    
    if [[ -n "$consul_services" ]]; then
        local registered_count=$(echo "$consul_services" | wc -l)
        log "$exp_dir" "   Registered services: $registered_count"
        
        for expected in "${expected_consul_services[@]}"; do
            if echo "$consul_services" | grep -q "$expected"; then
                log "$exp_dir" "    $expected: registered"
            else
                log "$exp_dir" "    $expected: missing from Consul"
                missing_consul_services+=("$expected")
                validation_failed=true
            fi
        done
    else
        log "$exp_dir" "    No services found in Consul registry (CRITICAL FAILURE)"
        validation_failed=true
    fi
    
    # 3. Test critical service connectivity
    log "$exp_dir" "3. Testing critical service connectivity..."
    
    # Test recommendations endpoint (should work)
    local rec_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/recommendations?require=price&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
    if [[ "$rec_test" == "200" ]]; then
        log "$exp_dir" "    Recommendations endpoint: HTTP 200"
    else
        log "$exp_dir" "    Recommendations endpoint: HTTP $rec_test (FAILED)"
        validation_failed=true
    fi
    
    # Test hotels endpoint (requires search service via Consul)
    local hotel_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
    if [[ "$hotel_test" == "200" ]]; then
        log "$exp_dir" "    Hotels endpoint: HTTP 200"
    else
        log "$exp_dir" "    Hotels endpoint: HTTP $hotel_test (FAILED - likely Consul issue)"
        validation_failed=true
    fi
    
    # 4. Summary
    log "$exp_dir" "=== VALIDATION SUMMARY ==="
    if [[ "$validation_failed" == "true" ]]; then
        log "$exp_dir" " VALIDATION FAILED"
        log "$exp_dir" "Failed deployments: ${failed_deployments[*]:-none}"
        log "$exp_dir" "Missing Consul services: ${missing_consul_services[*]:-none}"
        log "$exp_dir" "Recommendations test: HTTP $rec_test"
        log "$exp_dir" "Hotels test: HTTP $hotel_test"
        
        # Debug failed services for better troubleshooting
        for failed_service in "${failed_deployments[@]}"; do
            debug_service_registration "$exp_dir" "$failed_service"
        done
        
        # Debug missing Consul services
        for missing_service in "${missing_consul_services[@]}"; do
            local service_name=${missing_service#srv-}  # Remove srv- prefix
            debug_service_registration "$exp_dir" "$service_name"
        done
        
        # Save validation failure details
        {
            echo "=== SYSTEM VALIDATION FAILURE ==="
            echo "Failed at: $(date -Iseconds)"
            echo "Failed deployments: ${failed_deployments[*]:-none}"
            echo "Missing Consul services: ${missing_consul_services[*]:-none}"
            echo "Recommendations endpoint: HTTP $rec_test"
            echo "Hotels endpoint: HTTP $hotel_test"
        } > "$exp_dir/metadata/validation_failure.txt"
        
        return 1
    else
        log "$exp_dir" " ALL VALIDATIONS PASSED"
        log "$exp_dir" "System is ready for experiments"
        
        # Save successful validation details
        {
            echo "=== SYSTEM VALIDATION SUCCESS ==="
            echo "Validated at: $(date -Iseconds)"
            echo "All deployments: ready"
            echo "Consul services: ${#expected_consul_services[@]}/${#expected_consul_services[@]} registered"
            echo "Recommendations endpoint: HTTP $rec_test"
            echo "Hotels endpoint: HTTP $hotel_test"
        } > "$exp_dir/metadata/validation_success.txt"
        
        return 0
    fi
}

# Debug service registration issues
debug_service_registration() {
    local exp_dir="$1"
    local service_name="$2"
    
    log "$exp_dir" "=== DEBUGGING SERVICE REGISTRATION: $service_name ==="
    
    # Check if deployment exists and is ready
    if kubectl get deployment "$service_name" &>/dev/null; then
        local ready_replicas=$(kubectl get deployment "$service_name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired_replicas=$(kubectl get deployment "$service_name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        log "$exp_dir" "  Deployment status: $ready_replicas/$desired_replicas pods ready"
        
        # Get pod details
        log "$exp_dir" "  Pod details:"
        kubectl get pods -l app="$service_name" -o wide | while read -r line; do
            log "$exp_dir" "    $line"
        done
        
        # Check recent logs for registration attempts
        log "$exp_dir" "  Recent logs (last 20 lines):"
        kubectl logs deployment/"$service_name" --tail=20 2>/dev/null | while read -r line; do
            log "$exp_dir" "    $line"
        done | grep -E "(consul|register|error)" || log "$exp_dir" "    No registration-related logs found"
        
        # Check if service can connect to Consul
        log "$exp_dir" "  Testing Consul connectivity from $service_name:"
        kubectl exec -it deployment/"$service_name" -- sh -c "nc -z consul 8500 && echo 'Consul reachable' || echo 'Consul unreachable'" 2>/dev/null || \
            log "$exp_dir" "    Could not test Consul connectivity"
    else
        log "$exp_dir" "  Deployment $service_name does not exist"
    fi
    
    log "$exp_dir" "=== END DEBUG: $service_name ==="
}

# Clean up pending pods that might be stuck
cleanup_pending_pods() {
    local exp_dir="$1"
    
    log "$exp_dir" "Cleaning up any pending pods that might be stuck..."
    
    # Get pending pods in default namespace
    local pending_pods=$(kubectl get pods -n default --field-selector=status.phase=Pending -o name 2>/dev/null || echo "")
    
    if [[ -n "$pending_pods" ]]; then
        echo "$pending_pods" | while read -r pod; do
            if [[ -n "$pod" ]]; then
                log "$exp_dir" "  Deleting pending pod: $pod"
                kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
            fi
        done
        
        # Wait a moment for cleanup
        sleep 5
    else
        log "$exp_dir" "No pending pods found"
    fi
}

# Remove anti-affinity rules from deployments
remove_anti_affinity() {
    local deployments="$1"
    local exp_dir="$2"
    
    log "$exp_dir" "Removing anti-affinity rules from deployments: $deployments"
    
    for deployment in $deployments; do
        log "$exp_dir" "  Removing anti-affinity from $deployment"
        
        # First check if the deployment exists
        if kubectl get deployment "$deployment" -n default >/dev/null 2>&1; then
            # Check if the deployment has affinity rules
            local has_affinity=$(kubectl get deployment "$deployment" -n default -o jsonpath='{.spec.template.spec.affinity}' 2>/dev/null)
            
            if [[ -n "$has_affinity" && "$has_affinity" != "null" ]]; then
                # Deployment has affinity rules, remove them
                if kubectl patch deployment "$deployment" -n default --type='merge' -p '{
                  "spec": {
                    "template": {
                      "spec": {
                        "affinity": null
                      }
                    }
                  }
                }' >/dev/null 2>&1; then
                    log "$exp_dir" "    Successfully removed anti-affinity from $deployment"
                else
                    log "$exp_dir" "    Warning: Failed to remove anti-affinity from $deployment"
                fi
            else
                log "$exp_dir" "    No anti-affinity rules found in $deployment (skipping)"
            fi
        else
            log "$exp_dir" "    Deployment $deployment not found (skipping)"
        fi
    done
}

# Start wrk2 workload generation and collect e2e latency metrics
start_workload_and_latency() {
    local target_service="$1"
    local duration="$2"
    local exp_dir="$3"
    local iteration="$4"
    local workload_script="$5"
    local rate="$6"
    local threads="$7"
    local connections="$8"
    
    # Skip if no target service specified
    if [[ -z "$target_service" ]]; then
        log "$exp_dir" "No wrk2 target service specified, skipping workload generation"
        return
    fi
    
    # Skip if wrk2 not available
    if [[ ! -f "$WRK2_DIR/wrk" ]]; then
        log "$exp_dir" "wrk2 not found, skipping workload generation"
        return
    fi
    
    log "$exp_dir" "Starting wrk2 workload generation for $target_service"
    
    # Get service endpoint - try different methods
    local service_ip service_port target_url
    
    # Try cluster IP first
    service_ip=$(kubectl get service "$target_service" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    service_port=$(kubectl get service "$target_service" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "5000")
    
    if [[ -z "$service_ip" ]]; then
        log "$exp_dir" "WARNING: Could not get service IP for $target_service, trying external access"
        # Try to get external/nodeport access
        service_ip="${WRK2_TARGET_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
        service_port="${WRK2_TARGET_PORT:-$(kubectl get service "$target_service" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "5000")}"
    fi
    
    target_url="http://${service_ip}:${service_port}"
    log "$exp_dir" "Target URL: $target_url"
    log "$exp_dir" "Workload script: ${workload_script:-none}"
    log "$exp_dir" "Rate: ${rate} RPS, Threads: $threads, Connections: $connections, Duration: ${duration}s"
    
    # Construct wrk2 command
    local wrk2_cmd="$WRK2_DIR/wrk -D exp -t $threads -c $connections -d ${duration}s -L -R $rate"
    
    if [[ -n "$workload_script" && -f "$workload_script" ]]; then
        wrk2_cmd="$wrk2_cmd -s $workload_script"
    fi
    
    wrk2_cmd="$wrk2_cmd $target_url"
    
    log "$exp_dir" "Running: $wrk2_cmd"
    
    # Run wrk2 and capture output
    $wrk2_cmd > "$exp_dir/raw/latency/${target_service}_iter${iteration}.txt" 2>&1 &
    
    local wrk2_pid=$!
    echo "$wrk2_pid:$target_service" >> "$exp_dir/raw/latency/workload_pids_iter${iteration}.txt"
    
    log "$exp_dir" "wrk2 workload started for $target_service (PID: $wrk2_pid)"
    
    echo "$wrk2_pid"
}

# Collect system metrics
collect_system_metrics() {
    local exp_dir="$1"
    local iteration="$2"
    local phase="$3"  # baseline, during, end
    
    # Create aggregated system metrics file
    local metrics_file="$exp_dir/raw/system/metrics_${phase}_iter${iteration}.txt"
    
    {
        echo "=== SYSTEM METRICS - $phase (iteration $iteration) ==="
        echo "Timestamp: $(date -Iseconds)"
        echo ""
        echo "=== NODE METRICS ==="
        kubectl top nodes 2>/dev/null || echo "kubectl top nodes failed"
        echo ""
        echo "=== POD METRICS ==="
        kubectl top pods --all-namespaces 2>/dev/null || echo "kubectl top pods failed"
        echo ""
        echo "=== POD PLACEMENT ==="
        kubectl get pods -o wide
        echo ""
    } > "$metrics_file"
}

# Wait for background processes
wait_for_processes() {
    local pids=("$@")
    
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
        fi
    done
}

# Execute a single stress burst
execute_stress_burst() {
    local stress_type="$1"
    local intensity="$2"
    local duration="$3"
    local target_node="$4"
    local exp_dir="$5"
    local burst_id="$6"
    
    log "$exp_dir" "  Starting burst $burst_id: type=$stress_type intensity=$intensity duration=${duration}s"
    
    # Parse intensity based on stress type
    local stress_intensity=$(parse_stress_intensity "$stress_type" "$intensity")
    
    # Build stress args
    local stress_args="${stress_intensity} ${duration}s"
    
    # Execute stress in background
    "$STRESS_SCRIPT" "$stress_type" $stress_args --node "$target_node" \
        > "$exp_dir/raw/stress/stress_burst${burst_id}.txt" 2>&1 &
    
    local stress_pid=$!
    echo "$stress_pid" >> "$exp_dir/raw/stress/burst_pids.txt"
    
    log "$exp_dir" "  Burst $burst_id started (PID: $stress_pid)"
    echo "$stress_pid"
}

# Execute burst schedule with proper timing
execute_burst_schedule() {
    local exp_dir="$1"
    local iteration="$2"
    local target_node="$3"
    local stress_type="$4"
    local burst_schedule="$5"
    
    # Check for no-contention mode
    if [[ -z "$burst_schedule" || "$burst_schedule" == "none" || "$burst_schedule" == "0" ]]; then
        log "$exp_dir" "No-contention mode: skipping burst execution for iteration $iteration"
        echo ""
        return 0
    fi
    
    log "$exp_dir" "Executing burst schedule for iteration $iteration"
    
    local bursts=($burst_schedule)
    local burst_pids=()
    local iteration_start=$(date +%s)
    
    # Clear previous burst PID file
    rm -f "$exp_dir/raw/stress/burst_pids.txt"
    
    local burst_num=0
    for burst_spec in "${bursts[@]}"; do
        IFS=':' read -r start_time duration intensity <<< "$burst_spec"
        ((burst_num++))
        
        # Skip bursts with zero intensity
        if [[ "$intensity" == "0" || -z "$intensity" ]]; then
            log "$exp_dir" "  Skipping burst $burst_num (intensity=0, no-contention)"
            continue
        fi
        
        local burst_id="iter${iteration}_burst${burst_num}"
        
        # Calculate when to start this burst
        local current_time=$(date +%s)
        local elapsed=$((current_time - iteration_start))
        local wait_time=$((start_time - elapsed))
        
        # Wait until it's time for this burst
        if [[ $wait_time -gt 0 ]]; then
            log "$exp_dir" "  Waiting ${wait_time}s before burst $burst_num..."
            sleep "$wait_time"
        elif [[ $wait_time -lt -5 ]]; then
            # If we're more than 5s behind schedule, log warning
            log "$exp_dir" "  WARNING: Burst $burst_num is ${wait_time#-}s behind schedule"
        fi
        
        # Start the burst in background
        local pid=$(execute_stress_burst "$stress_type" "$intensity" "$duration" "$target_node" "$exp_dir" "$burst_id")
        burst_pids+=("$pid")
    done
    
    log "$exp_dir" "All bursts scheduled (${#bursts[@]} total)"
    
    # Return PIDs as space-separated string
    echo "${burst_pids[@]}"
}

# Run single iteration
run_iteration() {
    local config_file="$1"
    local exp_dir="$2"
    local iteration="$3"
    
    source "$config_file"
    
    log "$exp_dir" "Starting iteration $iteration"
    
    # Generate burst schedule for this iteration
    local burst_schedule=$(generate_burst_schedule "$exp_dir" "$iteration")
    if [[ -z "$burst_schedule" ]]; then
        log "$exp_dir" "ERROR: Failed to generate burst schedule"
        return 1
    fi
    
    # Calculate total iteration duration
    local total_duration=$(calculate_iteration_duration "$burst_schedule")
    log "$exp_dir" "Total iteration duration: ${total_duration}s (including buffer time)"
    
    # Save burst schedule to metadata
    echo "$burst_schedule" > "$exp_dir/metadata/burst_schedule_iter${iteration}.txt"
    
    # Update EXPERIMENT_DURATION for this iteration (used by windowed sampling)
    local experiment_duration=$((total_duration - 10))  # Exclude buffer time
    export EXPERIMENT_DURATION=$experiment_duration
    
    # Update iteration ID and duration for all victim services (only needed when windowed sampling is enabled)
    if [[ "${ENABLE_WINDOWED_SAMPLING:-true}" == "true" ]] && [[ $iteration -gt 1 ]]; then
        update_iteration_id "$exp_dir" "$iteration" "$VICTIM_SERVICES" "$experiment_duration"
    fi
    
    # Collect baseline metrics
    collect_system_metrics "$exp_dir" "$iteration" "baseline"
    
    # Record iteration start time
    local iteration_start=$(date +%s)
    echo "$iteration_start" > "$exp_dir/metadata/iteration_${iteration}_start.txt"
    
    # Start workload generation early (at +5s)
    log "$exp_dir" "Waiting 5s before starting workload generation..."
    sleep 5
    
    local workload_start=$(date +%s)
    echo "$workload_start" > "$exp_dir/metadata/iteration_${iteration}_workload_start.txt"
    
    # Start workload generation (runs for entire iteration duration)
    local wrk2_pid=""
    if [[ -n "${WRK2_TARGET_SERVICE:-}" ]]; then
        log "$exp_dir" "Starting workload generation (duration: ${total_duration}s)"
        wrk2_pid=$(start_workload_and_latency \
            "${WRK2_TARGET_SERVICE}" \
            "$total_duration" \
            "$exp_dir" \
            "$iteration" \
            "${WRK2_SCRIPT:-}" \
            "${WRK2_RATE:-200}" \
            "${WRK2_THREADS:-2}" \
            "${WRK2_CONNECTIONS:-2}")
    fi
    
    # Start burst schedule execution
    log "$exp_dir" "Starting burst schedule execution"
    local burst_pids=$(execute_burst_schedule "$exp_dir" "$iteration" "$TARGET_NODE" "$NOISY_NEIGHBOR_TYPE" "$burst_schedule")
    
    # NOTE: Windowed sampling runs automatically inside service containers (if enabled)
    if [[ "${ENABLE_WINDOWED_SAMPLING:-true}" == "true" ]]; then
        log "$exp_dir" "Windowed sampling is running inside service containers"
        log "$exp_dir" "  Sampling duration: ${experiment_duration}s"
        log "$exp_dir" "  Window interval: ${WINDOW_INTERVAL_MS}ms"
        log "$exp_dir" "  Expected samples: $((experiment_duration * 1000 / WINDOW_INTERVAL_MS))"
        log "$exp_dir" "  Note: Samples include idle periods between bursts"
    else
        log "$exp_dir" "Windowed sampling is disabled - only collecting latency data"
    fi
    
    # Collect metrics during stress (sample at 1/4 point)
    local sample_time=$((experiment_duration / 4))
    log "$exp_dir" "Waiting ${sample_time}s before collecting 'during' metrics..."
    sleep "$sample_time"
    collect_system_metrics "$exp_dir" "$iteration" "during"
    
    # Wait for the rest of the experiment to complete
    local remaining_time=$((total_duration - sample_time - 5))  # -5 for initial wait
    if [[ $remaining_time -gt 0 ]]; then
        log "$exp_dir" "Waiting ${remaining_time}s for experiment to complete..."
        sleep "$remaining_time"
    fi
    
    # Collect end metrics
    collect_system_metrics "$exp_dir" "$iteration" "end"
    
    # Record iteration end time
    local iteration_end=$(date +%s)
    echo "$iteration_end" > "$exp_dir/metadata/iteration_${iteration}_end.txt"
    
    # Calculate actual duration
    local actual_duration=$((iteration_end - iteration_start))
    log "$exp_dir" "Iteration actual duration: ${actual_duration}s (planned: ${total_duration}s)"
    
    # Wait a bit more for data to be written to disk
    log "$exp_dir" "Waiting 5s for data to be flushed to disk..."
    sleep 5
    
    # Retrieve windowed run data from all victim services (only if enabled)
    if [[ "${ENABLE_WINDOWED_SAMPLING:-true}" == "true" ]]; then
        log "$exp_dir" "Retrieving windowed run data from victim services"
        for service in $VICTIM_SERVICES; do
            if validate_timing_service "$service"; then
                retrieve_windowed_run_data "$service" "$exp_dir" "$iteration"
            fi
        done
    else
        log "$exp_dir" "Windowed sampling disabled, skipping windowed data retrieval"
    fi
    
    # Wait for wrk2 to complete if it was started
    if [[ -n "$wrk2_pid" ]]; then
        log "$exp_dir" "Waiting for workload generation to complete..."
        wait "$wrk2_pid" 2>/dev/null || true
    fi
    
    # Wait for all burst stress processes to complete
    if [[ -n "$burst_pids" ]]; then
        log "$exp_dir" "Waiting for all stress bursts to complete..."
        wait_for_processes $burst_pids
    fi
    
    # Cleanup stress pods
    log "$exp_dir" "Cleaning up stress pods..."
    "$STRESS_SCRIPT" cleanup
    
    log "$exp_dir" "Iteration $iteration completed"
}

# Generate experiment metadata
generate_metadata() {
    local config_file="$1"
    local exp_dir="$2"
    local exp_id="$3"
    
    source "$config_file"
    
    # Determine contention model and duration info
    local contention_model="legacy-single-burst"
    local duration_info=""
    local burst_info=""
    
    if [[ -n "${CONTENTION_SHAPE:-}" ]]; then
        contention_model="burst-based"
        burst_info=",
        \"contention_bursts\": {
            \"shape\": \"$CONTENTION_SHAPE\",
            \"shape_args\": \"${CONTENTION_SHAPE_ARGS}\",
            \"randomize\": ${CONTENTION_RANDOMIZE:-false},
            \"random_seed\": \"${CONTENTION_RANDOM_SEED:-auto}\",
            \"note\": \"Duration varies per iteration based on burst schedule\"
        }"
    else
        duration_info=",
        \"experiment_duration\": $EXPERIMENT_DURATION,
        \"timing\": {
            \"base_duration\": $EXPERIMENT_DURATION,
            \"stressor_duration\": \"$((EXPERIMENT_DURATION + 10))\",
            \"workload_duration\": \"$((EXPERIMENT_DURATION + 5))\",
            \"startup_delays\": {
                \"stressor_to_workload\": 15,
                \"workload_start\": 15
            }
        }"
    fi
    
    cat > "$exp_dir/metadata/experiment.json" << EOF
{
    "experiment_id": "$exp_id",
    "experiment_name": "$EXPERIMENT_NAME",
    "timestamp": "$(date -Iseconds)",
    "contention_model": "$contention_model",
    "configuration": {
        "target_node": "$TARGET_NODE",
        "victim_services": "$VICTIM_SERVICES",
        "windowed_sampling": {
            "enabled": ${ENABLE_WINDOWED_SAMPLING:-true},
            "window_interval_ms": ${WINDOW_INTERVAL_MS:-100},
            "perf_events": "${PERF_EVENTS:-cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,dtlb-load-misses,itlb-load-misses,page-faults,minor-faults,major-faults,context-switches,cpu-migrations}",
            "data_collection": "Full timeline from workload start to iteration end, including idle periods",
            "rationale": "Captures development of contention and performance changes when approaching/leaving contention"
        },
        "noisy_neighbor": {
            "type": "$NOISY_NEIGHBOR_TYPE",
            "args": "${NOISY_NEIGHBOR_ARGS:-}",
            "command": "$NOISY_NEIGHBOR_TYPE ${NOISY_NEIGHBOR_ARGS:-}"
        }${duration_info}${burst_info},
        "iterations": ${ITERATIONS:-3},
        "iteration_delay": ${ITERATION_DELAY:-60},
        "wrk2_config": {
            "target_service": "${WRK2_TARGET_SERVICE:-none}",
            "target_ip": "${WRK2_TARGET_IP:-auto}",
            "target_port": "${WRK2_TARGET_PORT:-5000}",
            "script": "${WRK2_SCRIPT:-none}",
            "rate": ${WRK2_RATE:-200},
            "threads": ${WRK2_THREADS:-2},
            "connections": ${WRK2_CONNECTIONS:-2},
            "start_timing": "5s after iteration start (early start)"
        }
    },
    "system_info": {
        "kubernetes_version": "$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo 'unknown')",
        "target_node_info": $(kubectl get node "$TARGET_NODE" -o json 2>/dev/null | { if command -v jq >/dev/null 2>&1; then jq '{name: .metadata.name, capacity: .status.capacity, allocatable: .status.allocatable}'; else echo '{"name": "'$TARGET_NODE'", "info": "jq not available"}'; fi } 2>/dev/null || echo '{"name": "'$TARGET_NODE'", "error": "node info unavailable"}')
    },
    "scripts_used": {
        "stress_script": "$STRESS_SCRIPT",
        "taint_script": "$TAINT_SCRIPT",
        "shapes_script": "$SHAPES_SCRIPT"
    },
    "data_structure": {
        "raw/windowed/": "Windowed sampling data (perf + timing) per service per iteration - includes idle periods",
        "raw/latency/": "End-to-end latency metrics from wrk2",
        "raw/system/": "System-wide metrics (nodes, pods) per phase",
        "raw/stress/": "Stress burst logs per iteration",
        "metadata/burst_schedule_iterN.txt": "Burst schedule for each iteration",
        "metadata/iteration_N_*.txt": "Timing metadata for each iteration (start, workload_start, end)",
        "processed/aggregated/": "Aggregated data across all iterations"
    }
}
EOF

sudo lshw -json > $exp_dir/metadata/hardware.json

}

# Aggregate windowed sampling data across iterations
aggregate_windowed_data() {
    local exp_dir="$1"
    local total_iterations="$2"
    local services="$3"
    
    log "$exp_dir" "Aggregating windowed data across $total_iterations iterations"
    
    for service in $services; do
        log "$exp_dir" "  Aggregating data for service: $service"
        
        local input_dir="$exp_dir/raw/windowed/$service"
        local output_dir="$exp_dir/processed/aggregated"
        mkdir -p "$output_dir"
        
        if [[ ! -d "$input_dir" ]]; then
            log "$exp_dir" "    No windowed data found for $service, skipping"
            continue
        fi
        
        # Use Python for JSON aggregation (if available)
        if command -v python3 >/dev/null 2>&1; then
            python3 - <<EOF
import json
import glob
import os

service = "$service"
input_dir = "$input_dir"
output_dir = "$output_dir"
total_iterations = int("$total_iterations")

# Collect all run data files
runs = []
for iter_num in range(1, total_iterations + 1):
    run_file = os.path.join(input_dir, f"run_data_iter{iter_num}.json")
    if os.path.exists(run_file):
        try:
            with open(run_file) as f:
                data = json.load(f)
                runs.append({
                    "iteration_id": data.get("iteration_id", iter_num),
                    "run_file": os.path.basename(run_file),
                    "run_duration_ms": data.get("run_duration_ms", 0),
                    "sample_count": data.get("sample_count", 0),
                    "total_requests": data.get("aggregates", {}).get("total_requests", 0),
                    "cycles_total": data.get("aggregates", {}).get("perf_totals", {}).get("cycles", 0),
                    "instructions_total": data.get("aggregates", {}).get("perf_totals", {}).get("instructions", 0)
                })
        except Exception as e:
            print(f"Error processing {run_file}: {e}")

if not runs:
    print(f"No run data found for {service}")
    exit(0)

# Calculate experiment-level aggregates
total_samples = sum(r["sample_count"] for r in runs)
total_requests = sum(r["total_requests"] for r in runs)
cycles_mean = sum(r["cycles_total"] for r in runs) / len(runs) if runs else 0
instructions_mean = sum(r["instructions_total"] for r in runs) / len(runs) if runs else 0

experiment_summary = {
    "service_name": service,
    "total_iterations": len(runs),
    "runs": runs,
    "experiment_aggregates": {
        "total_samples": total_samples,
        "total_requests": total_requests,
        "avg_requests_per_run": total_requests / len(runs) if runs else 0,
        "cycles_mean": cycles_mean,
        "instructions_mean": instructions_mean,
        "ipc_mean": instructions_mean / cycles_mean if cycles_mean > 0 else 0
    }
}

# Write experiment summary
output_file = os.path.join(output_dir, f"experiment_summary_{service}.json")
with open(output_file, "w") as f:
    json.dump(experiment_summary, f, indent=2)

print(f"Created experiment summary: {output_file}")
EOF
        else
            log "$exp_dir" "    Python3 not available, skipping JSON aggregation for $service"
        fi
    done
}

# Aggregate iteration data into summary files
aggregate_data() {
    local exp_dir="$1"
    local total_iterations="$2"
    
    log "$exp_dir" "Aggregating data across $total_iterations iterations"
    
    # Aggregate windowed sampling data (perf + timing integrated)
    if [[ "${ENABLE_WINDOWED_SAMPLING:-true}" == "true" ]]; then
        aggregate_windowed_data "$exp_dir" "$total_iterations" "$VICTIM_SERVICES"
    fi
    
    # Aggregate latency data
    if ls "$exp_dir/raw/latency/"*_iter*.txt 1> /dev/null 2>&1; then
        {
            echo "=== AGGREGATED LATENCY METRICS ==="
            echo "Generated: $(date -Iseconds)"
            echo ""
            for i in $(seq 1 $total_iterations); do
                echo "=== ITERATION $i ==="
                for file in "$exp_dir/raw/latency/"*_iter${i}.txt; do
                    if [[ -f "$file" ]]; then
                        echo "--- $(basename "$file") ---"
                        cat "$file"
                        echo ""
                    fi
                done
            done
        } > "$exp_dir/processed/latency_summary.txt"
    fi
    
    # Create experiment summary
    {
        echo "=== EXPERIMENT SUMMARY ==="
        echo "Generated: $(date -Iseconds)"
        echo ""
        
        # Check if windowed sampling data was collected
        local windowed_enabled="false"
        local windowed_services_count=0
        if [[ -d "$exp_dir/raw/windowed" ]]; then
            windowed_services_count=$(find "$exp_dir/raw/windowed" -name "run_data_iter*.json" 2>/dev/null | wc -l)
            if [[ $windowed_services_count -gt 0 ]]; then
                windowed_enabled="true"
            fi
        fi
        
        echo "Windowed Sampling: $windowed_enabled"
        if [[ "$windowed_enabled" == "true" ]]; then
            echo "  Run data files: $windowed_services_count"
            echo "  Window interval: ${WINDOW_INTERVAL_MS}ms"
            echo "  Perf events: ${PERF_EVENTS}"
            local windowed_services=$(ls -d "$exp_dir/raw/windowed/"*/ 2>/dev/null | xargs -n1 basename | tr '\n' ' ')
            echo "  Services with windowed data: $windowed_services"
        fi
        
        echo ""
        echo "Raw data files: $(find "$exp_dir/raw" -type f -name "*.txt" -o -name "*.json" | wc -l)"
        echo "Total data size: $(du -sh "$exp_dir" 2>/dev/null | cut -f1 || echo 'unknown')"
        echo ""
        echo "=== FILE STRUCTURE ==="
        find "$exp_dir" -type f | sort
    } > "$exp_dir/processed/experiment_summary.txt"
}

# Main experiment execution
run_experiment() {
    local config_file="$1"
    local exp_dir="$2"
    local exp_id="$3"
    
    source "$config_file"
    
    local total_iterations=${ITERATIONS:-3}
    local iteration_delay=${ITERATION_DELAY:-60}
    
    log "$exp_dir" "Starting experiment: $EXPERIMENT_NAME"
    log "$exp_dir" "Total iterations: $total_iterations"
    log "$exp_dir" "Data directory: $exp_dir"
    
    # Clean up any existing stress pods first
    cleanup_existing_stress_pods "$exp_dir"
    
    # Clean up any pending pods that might be stuck
    cleanup_pending_pods "$exp_dir"
    
    # Remove any existing anti-affinity rules that might be causing issues
    log "$exp_dir" "Removing any existing anti-affinity rules from all deployments..."
    local all_deployments=$(kubectl get deployments -n default -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
    if [[ -n "$all_deployments" ]]; then
        remove_anti_affinity "$all_deployments" "$exp_dir"
        sleep 10  # Wait for changes to take effect
    fi
    
    # Check and untolerate existing pods on target node first
    check_and_untolerate_pods "$TARGET_NODE" "$exp_dir"
    
    # Read the list of untolerated deployments for later cleanup
    local untolerated_deployments=""
    if [[ -f "$exp_dir/metadata/untolerated_deployments.txt" ]]; then
        untolerated_deployments=$(cat "$exp_dir/metadata/untolerated_deployments.txt")
    fi
    
    # Pre-calculate experiment duration from burst schedule for initial deployment
    if [[ -n "${CONTENTION_BURSTS:-}" ]]; then
        local initial_duration=$(calculate_iteration_duration "$CONTENTION_BURSTS")
        export EXPERIMENT_DURATION=$((initial_duration - 10))  # Exclude buffer time
        log "$exp_dir" "Calculated EXPERIMENT_DURATION from burst schedule: ${EXPERIMENT_DURATION}s"
    fi
    
    # Reset non-victim services to default images BEFORE deploying victims
    # This prevents contamination from previous experiments
    reset_non_victim_services "$VICTIM_SERVICES" "$exp_dir"
    
    # Deploy victim services
    deploy_victim_services "$VICTIM_SERVICES" "$TARGET_NODE" "$exp_dir"
    
    # Wait for services to stabilize after deployment
    log "$exp_dir" "Waiting for services to stabilize after deployment..."
    sleep 45  # Increased from 30s to 45s
    
    # Monitor initial service registration
    log "$exp_dir" "Monitoring initial service registration in Consul..."
    monitor_consul_service_registration "$exp_dir" 90 10
    
    # Configure Jaeger tracing for all services after deployment
    configure_jaeger_tracing "$exp_dir"
    
    # Final validation before starting experiments
    log "$exp_dir" "Performing final system validation before starting experiments..."
    if ! validate_system_readiness "$exp_dir"; then
        log "$exp_dir" "WARNING: Initial system validation failed. Attempting recovery..."
        
        # Try manual registration as last resort
        if manual_register_all_services "$exp_dir"; then
            log "$exp_dir" "Manual registration successful. Re-validating system..."
            if validate_system_readiness "$exp_dir"; then
                log "$exp_dir" " System validation passed after manual registration. Ready to start experiments."
            else
                log "$exp_dir" "ERROR: System validation still failed after manual registration. Aborting experiment."
                exit 1
            fi
        else
            log "$exp_dir" "ERROR: Manual registration failed. System validation failed. Aborting experiment."
            exit 1
        fi
    else
        log "$exp_dir" " System validation passed. Ready to start experiments."
    fi
    
    # Run iterations
    for iteration in $(seq 1 $total_iterations); do
        log "$exp_dir" "=== Iteration $iteration/$total_iterations ==="
        
        run_iteration "$config_file" "$exp_dir" "$iteration"
        
        # Wait between iterations
        if [[ $iteration -lt $total_iterations ]]; then
            log "$exp_dir" "Waiting ${iteration_delay}s before next iteration"
            sleep "$iteration_delay"
        fi
    done
    
    # Aggregate data
    aggregate_data "$exp_dir" "$total_iterations"
    
    log "$exp_dir" "Experiment completed successfully"
    
    # Show windowed sampling summary if available
    if [[ -d "$exp_dir/raw/windowed" ]]; then
        log "$exp_dir" "Windowed sampling data collected and aggregated:"
        log "$exp_dir" "  Raw data: $exp_dir/raw/windowed/"
        log "$exp_dir" "  Aggregated: $exp_dir/processed/aggregated/"
        
        # Show which services had windowed data
        local windowed_services=$(ls -d "$exp_dir/raw/windowed/"*/ 2>/dev/null | xargs -n1 basename | tr '\n' ' ')
        if [[ -n "$windowed_services" ]]; then
            log "$exp_dir" "  Services with windowed data:$windowed_services"
            
            # Show sample counts
            for service in $windowed_services; do
                local first_run="$exp_dir/raw/windowed/$service/run_data_iter1.json"
                if [[ -f "$first_run" ]]; then
                    local sample_count="unknown"
                    if command -v jq >/dev/null 2>&1; then
                        sample_count=$(jq -r '.sample_count // "unknown"' "$first_run" 2>/dev/null)
                    fi
                    log "$exp_dir" "    $service: $sample_count samples per run"
                fi
            done
        fi
    else
        log "$exp_dir" "No windowed sampling data was collected in this experiment"
    fi
}

# Main execution
main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <experiment-config-file>"
        echo ""
        echo "=== BURST-BASED CONTENTION EXPERIMENTS ==="
        echo ""
        echo "Define burst schedules to study contention dynamics with idle periods."
        echo "Captures full timeline for performance degradation/recovery analysis."
        echo ""
        echo "=== COMPLETE CONFIGURATION EXAMPLE ==="
        echo ""
        cat << 'EXAMPLE_EOF'
#!/bin/bash
# Periodic CPU Contention Experiment

EXPERIMENT_NAME='Periodic CPU Contention'
TARGET_NODE='node-1'  # CHANGE TO YOUR NODE
VICTIM_SERVICES='frontend search'
NOISY_NEIGHBOR_TYPE='cpu'

# Define burst schedule using helper functions (auto-sourced by data-collector.sh)
# repeat_burst <start> <duration> <idle> <num_bursts> <intensity>
#   start:      first burst starts at this time (seconds from iteration start)
#   duration:   each burst runs for this many seconds
#   idle:       seconds of rest between end of one burst and start of next
#   num_bursts: total number of bursts to create
#   intensity:  workers per burst (CPU cores for 'cpu', MB for 'mem', workers for 'io')
CONTENTION_BURSTS=$(repeat_burst 0 30 10 5 4)
# This generates: 5 bursts, each 30s long, 10s idle between, using 4 CPU workers

# Experiment configuration
ITERATIONS=3
ITERATION_DELAY=60

# Windowed sampling
ENABLE_WINDOWED_SAMPLING=true
WINDOW_INTERVAL_MS=100
PERF_EVENTS='cycles,instructions,cache-references,cache-misses,branch-misses'
TIMING_BUFFER_SIZE=16384

# Jaeger tracing
JAEGER_SAMPLE_RATIO=0.01  # 1% sampling, set to 0 to disable

# wrk2 workload
WRK2_TARGET_SERVICE='frontend'
WRK2_TARGET_IP='192.168.1.100'  # CHANGE TO YOUR IP
WRK2_TARGET_PORT=5000
WRK2_SCRIPT='../wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua'
WRK2_RATE=200
WRK2_THREADS=3
WRK2_CONNECTIONS=3

# Timeline (per iteration):
#   0-30s:   Burst 1 (4 CPUs) - active samples
#  30-40s:   Idle (10s) - idle samples ✓
#  40-70s:   Burst 2 (4 CPUs)
#  70-80s:   Idle (10s) ✓
#  80-110s:  Burst 3 (4 CPUs)
# 110-120s:  Idle (10s) ✓
# 120-150s:  Burst 4 (4 CPUs)
# 150-160s:  Idle (10s) ✓
# 160-190s:  Burst 5 (4 CPUs)
# Total: ~200s per iteration
EXAMPLE_EOF
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        echo "=== HELPER FUNCTIONS (contention-shapes.sh) ==="
        echo ""
        echo "  burst <start> <duration> <intensity>"
        echo "    Single burst. Output: \"start:duration:intensity\""
        echo ""
        echo "  repeat_burst <start> <duration> <idle> <num_bursts> <intensity>"
        echo "    Multiple identical bursts."
        echo "    Parameters:"
        echo "      start      - first burst starts at this second"
        echo "      duration   - each burst runs for this many seconds"
        echo "      idle       - seconds between end of one burst and start of next"
        echo "      num_bursts - total number of bursts"
        echo "      intensity  - workers per burst"
        echo ""
        echo "  linear_intensity <start> <duration> <idle> <num_bursts> <start_int> <end_int>"
        echo "    Bursts with linearly changing intensity (escalating/de-escalating)."
        echo ""
        echo "Run './contention-shapes.sh help' for more details"
        echo ""
        echo "=== INTENSITY VALUES ==="
        echo ""
        echo "  cpu type: number of CPU workers (cores to stress)"
        echo "  mem type: number of stream workers (memory bandwidth stress)"
        echo "            Set MEMORY_L3_SIZE env var to override L3 cache size (default: 64M)"
        echo "            Buffer per worker = 4x L3 size (default: 256MB/worker)"
        echo "  io type:  number of IO workers"
        echo ""
        echo "=== SUPPORTED SERVICES ==="
        echo ""
        echo "  user, frontend, search, profile, rate, recommendation, reservation, geo"
        echo ""
        echo "=== AVAILABLE PERFORMANCE COUNTERS ==="
        echo ""
        echo "  CPU:      cycles (cpu-cycles), instructions, bus-cycles, ref-cycles"
        echo "            stalled-cycles-frontend, stalled-cycles-backend"
        echo "  Cache L1: L1-dcache-loads, L1-dcache-load-misses, L1-dcache-stores"
        echo "            L1-icache-load-misses"
        echo "  Cache LLC: LLC-loads, LLC-load-misses, LLC-stores, LLC-store-misses"
        echo "             cache-references, cache-misses"
        echo "  Branch:   branch-instructions (branches), branch-misses"
        echo "            branch-loads, branch-load-misses"
        echo "  TLB Data: dTLB-loads, dTLB-load-misses, dTLB-stores, dTLB-store-misses"
        echo "  TLB Inst: iTLB-loads, iTLB-load-misses"
        echo "  Memory:   page-faults, minor-faults, major-faults"
        echo "  NUMA:     node-loads, node-load-misses, node-stores, node-store-misses"
        echo "  System:   context-switches, cpu-migrations, task-clock, alignment-faults"
        echo ""
        echo "Note: Run 'perf list hardware' and 'perf list cache' on your node to see available events"
        echo ""
        exit 1
    fi
    
    local config_file="$1"
    
    # Validate configuration
    validate_config "$config_file"
    
    # Generate experiment ID
    local exp_id=$(generate_exp_id)
    echo "Generated experiment ID: $exp_id"
    
    # Create experiment directory
    local exp_dir=$(create_exp_directory "$exp_id")
    echo "Experiment directory: $exp_dir"
    
    # Generate metadata
    generate_metadata "$config_file" "$exp_dir" "$exp_id"
    
    # Run experiment
    run_experiment "$config_file" "$exp_dir" "$exp_id"
    
    echo "Experiment completed successfully!"
    echo "Data location: $exp_dir"
    echo "Summary: $exp_dir/processed/experiment_summary.txt"
    
    # Show windowed sampling data information if available
    if [[ -d "$exp_dir/raw/windowed" ]]; then
        echo "Windowed sampling data: $exp_dir/raw/windowed/"
        echo "Aggregated data: $exp_dir/processed/aggregated/"
    fi

    # Optional: sync to remote server (if 4th argument provided)
    if [[ -n "$4" ]]; then
        log "$exp_dir" "Syncing data to remote server..."
        rsync -av "./$exp_dir" "$4"@linux.eecs.tufts.edu:/r/docclab_traces/contention_exp_data/"$exp_dir" || \
            log "$exp_dir" "WARNING: Failed to sync data to remote server"
    fi
    
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
