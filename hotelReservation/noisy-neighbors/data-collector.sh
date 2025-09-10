#!/bin/bash
# Integrated Data Collection Framework
# Usage: ./data-collector.sh <experiment-config-file>

set -e

# Configuration
DATA_DIR="${DATA_DIR:-./experiment_data}"
HOTEL_MANIFESTS_DIR="${HOTEL_MANIFESTS_DIR:-./hotelReservation}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Your existing script paths
STRESS_SCRIPT="$SCRIPTS_DIR/stress-ng/stress-ng-helpers.sh"
MONITOR_SCRIPT="$SCRIPTS_DIR/perf/service-monitor.sh"
TAINT_SCRIPT="$SCRIPTS_DIR/node-taint.sh"

# Ensure directories exist
mkdir -p "$DATA_DIR"/{raw,processed,metadata,logs}

# Generate unique experiment ID
generate_exp_id() {
    echo "exp_$(date +%Y%m%d_%H%M%S)_$(uuidgen | cut -d'-' -f1)"
}

# Log function with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$DATA_DIR/logs/collector.log"
}

# Validate configuration
validate_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log "ERROR: Configuration file not found: $config_file"
        exit 1
    fi
    
    source "$config_file"
    
    # Check required variables
    local required_vars=("EXPERIMENT_NAME" "TARGET_NODE" "VICTIM_SERVICES" "PERF_COUNTER_SET" "NOISY_NEIGHBOR_TYPE" "EXPERIMENT_DURATION")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            log "ERROR: Required variable $var not set in config file"
            exit 1
        fi
    done
    
    # Check if scripts exist
    for script in "$STRESS_SCRIPT" "$MONITOR_SCRIPT" "$TAINT_SCRIPT"; do
        if [[ ! -f "$script" ]]; then
            log "ERROR: Required script not found: $script"
            exit 1
        fi
    done
    
    # Validate target node exists
    if ! kubectl get node "$TARGET_NODE" &>/dev/null; then
        log "ERROR: Target node $TARGET_NODE not found"
        exit 1
    fi
    
    log "Configuration validation passed"
}

# Check available stressor types from stress-ng-helpers.sh
get_available_stressors() {
    if [[ -f "$STRESS_SCRIPT" ]]; then
        # Extract case statements from the script to get available commands
        grep -A 1 "case.*in" "$STRESS_SCRIPT" | grep -E "^\s*(cpu|memory|vm|pagefault|io|network|noisy)" | sed 's/[^a-z]//g' | sort -u
    fi
}

# Deploy victim services on target node
deploy_victim_services() {
    local services="$1"
    local target_node="$2"
    local exp_id="$3"
    
    log "Deploying victim services: $services"
    
    for service in $services; do
        local manifest_file="$HOTEL_MANIFESTS_DIR/${service}.yaml"
        
        if [[ ! -f "$manifest_file" ]]; then
            log "WARNING: Manifest not found for service $service: $manifest_file"
            continue
        fi
        
        log "Deploying $service..."
        
        # Apply the manifest
        kubectl apply -f "$manifest_file"
        
        # Add toleration and node selector to the deployment
        "$TAINT_SCRIPT" "$target_node" "$service"
        
        # Wait for deployment to be ready
        kubectl rollout status deployment "$service" --timeout=120s
        
        log "Service $service deployed and ready"
    done
    
    # Record deployed services
    echo "$services" > "$DATA_DIR/raw/${exp_id}_deployed_services.txt"
}

# Cleanup victim services
cleanup_victim_services() {
    local services="$1"
    local target_node="$2"
    
    log "Cleaning up victim services: $services"
    
    for service in $services; do
        # Remove taint and toleration
        "$TAINT_SCRIPT" "$target_node" "$service" --untolerate
        
        # Delete the deployment
        kubectl delete deployment "$service" --ignore-not-found=true
        kubectl delete service "$service" --ignore-not-found=true
        
        log "Service $service cleaned up"
    done
}

# Start performance monitoring for all victim services
start_monitoring() {
    local services="$1"
    local duration="$2"
    local counter_set="$3"
    local exp_id="$4"
    local iteration="$5"
    
    log "Starting performance monitoring for services: $services"
    
    local monitor_pids=()
    
    for service in $services; do
        log "Starting monitor for $service with counter set: $counter_set"
        
        # Start monitoring in background and redirect output
        "$MONITOR_SCRIPT" "$service" default "$duration" "$counter_set" \
            > "$DATA_DIR/raw/${exp_id}_perf_${service}_${iteration}.txt" 2>&1 &
        
        local pid=$!
        monitor_pids+=($pid)
        echo "$pid:$service" >> "$DATA_DIR/raw/${exp_id}_monitor_pids_${iteration}.txt"
        
        log "Monitor started for $service (PID: $pid)"
        sleep 2  # Stagger starts slightly
    done
    
    echo "${monitor_pids[@]}"
}

# Collect application response time metrics
start_trace_collection() {
    local services="$1"
    local duration="$2"
    local exp_id="$3"
    local iteration="$4"
    
    log "Starting trace collection for services: $services"
    
    for service in $services; do
        # Get service endpoint
        local service_ip=$(kubectl get service "$service" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
        local service_port=$(kubectl get service "$service" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")
        
        if [[ -z "$service_ip" ]]; then
            log "WARNING: Could not get service IP for $service, skipping trace collection"
            continue
        fi
        
        log "Collecting traces for $service at $service_ip:$service_port"
        
        # Create curl monitoring pod
        kubectl run trace-collector-${service}-${iteration} \
            --image=curlimages/curl:latest \
            --restart=Never \
            --rm -i --quiet \
            -- sh -c "
                echo 'timestamp,status_code,total_time,connect_time,starttransfer_time'
                for i in \$(seq 1 $duration); do
                    start=\$(date +%s%N)
                    response=\$(curl -s -o /dev/null -w '%{http_code},%{time_total},%{time_connect},%{time_starttransfer}' http://$service_ip:$service_port/ 2>/dev/null || echo 'FAILED,0,0,0')
                    end=\$(date +%s%N)
                    request_time=\$(((\$end-\$start)/1000000))
                    echo \"\$(date -Iseconds),\$response,\$request_time\"
                    sleep 1
                done
            " > "$DATA_DIR/raw/${exp_id}_traces_${service}_${iteration}.csv" 2>/dev/null &
        
        local trace_pid=$!
        echo "$trace_pid:$service" >> "$DATA_DIR/raw/${exp_id}_trace_pids_${iteration}.txt"
    done
}

# Collect system metrics
collect_system_metrics() {
    local exp_id="$1"
    local iteration="$2"
    local phase="$3"  # baseline, during, end
    
    kubectl top nodes > "$DATA_DIR/raw/${exp_id}_nodes_${phase}_${iteration}.txt" 2>/dev/null || echo "kubectl top nodes failed" > "$DATA_DIR/raw/${exp_id}_nodes_${phase}_${iteration}.txt"
    kubectl top pods --all-namespaces > "$DATA_DIR/raw/${exp_id}_pods_${phase}_${iteration}.txt" 2>/dev/null || echo "kubectl top pods failed" > "$DATA_DIR/raw/${exp_id}_pods_${phase}_${iteration}.txt"
    kubectl get pods -o wide > "$DATA_DIR/raw/${exp_id}_pod_placement_${phase}_${iteration}.txt"
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

# Run single iteration
run_iteration() {
    local config_file="$1"
    local exp_id="$2"
    local iteration="$3"
    
    source "$config_file"
    
    log "Starting iteration $iteration"
    
    # Collect baseline metrics
    collect_system_metrics "$exp_id" "$iteration" "baseline"
    
    # Start monitoring (runs for full duration)
    local monitor_pids=($(start_monitoring "$VICTIM_SERVICES" "$EXPERIMENT_DURATION" "$PERF_COUNTER_SET" "$exp_id" "$iteration"))
    
    # Start trace collection
    start_trace_collection "$VICTIM_SERVICES" "$EXPERIMENT_DURATION" "$exp_id" "$iteration"
    
    # Wait a bit for monitoring to stabilize
    sleep 10
    
    # Start noisy neighbor
    log "Starting noisy neighbor: $NOISY_NEIGHBOR_TYPE with args: ${NOISY_NEIGHBOR_ARGS:-}"
    "$STRESS_SCRIPT" "$NOISY_NEIGHBOR_TYPE" ${NOISY_NEIGHBOR_ARGS} --node "$TARGET_NODE" \
        > "$DATA_DIR/raw/${exp_id}_stress_${iteration}.txt" 2>&1 &
    local stress_pid=$!
    
    # Collect metrics during stress
    sleep 30  # Let stress ramp up
    collect_system_metrics "$exp_id" "$iteration" "during"
    
    # Wait for experiment to complete
    local remaining_time=$((EXPERIMENT_DURATION - 40))  # 10s initial + 30s ramp
    if [[ $remaining_time -gt 0 ]]; then
        sleep "$remaining_time"
    fi
    
    # Collect end metrics
    collect_system_metrics "$exp_id" "$iteration" "end"
    
    # Wait for all monitoring to complete
    wait_for_processes "${monitor_pids[@]}"
    
    # Cleanup stress pods
    "$STRESS_SCRIPT" cleanup
    
    # Cleanup trace collection pods
    kubectl delete pod --field-selector=metadata.name=~trace-collector --ignore-not-found=true
    
    log "Iteration $iteration completed"
}

# Generate experiment metadata
generate_metadata() {
    local config_file="$1"
    local exp_id="$2"
    
    source "$config_file"
    
    cat > "$DATA_DIR/metadata/${exp_id}_metadata.json" << EOF
{
    "experiment_id": "$exp_id",
    "experiment_name": "$EXPERIMENT_NAME",
    "timestamp": "$(date -Iseconds)",
    "configuration": {
        "target_node": "$TARGET_NODE",
        "victim_services": "$VICTIM_SERVICES",
        "perf_counter_set": "$PERF_COUNTER_SET",
        "noisy_neighbor": {
            "type": "$NOISY_NEIGHBOR_TYPE",
            "args": "${NOISY_NEIGHBOR_ARGS:-}",
            "command": "$NOISY_NEIGHBOR_TYPE ${NOISY_NEIGHBOR_ARGS:-}"
        },
        "experiment_duration": $EXPERIMENT_DURATION,
        "iterations": ${ITERATIONS:-3},
        "iteration_delay": ${ITERATION_DELAY:-60}
    },
    "system_info": {
        "kubernetes_version": "$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo 'unknown')",
        "target_node_info": $(kubectl get node "$TARGET_NODE" -o json | jq '{name: .metadata.name, capacity: .status.capacity, allocatable: .status.allocatable}'),
        "available_stressors": [$(get_available_stressors | tr '\n' ',' | sed 's/,$//' | sed 's/\([^,]*\)/"\1"/g')]
    },
    "scripts_used": {
        "stress_script": "$STRESS_SCRIPT",
        "monitor_script": "$MONITOR_SCRIPT",
        "taint_script": "$TAINT_SCRIPT"
    }
}
EOF
}

# Main experiment execution
run_experiment() {
    local config_file="$1"
    local exp_id="$2"
    
    source "$config_file"
    
    local total_iterations=${ITERATIONS:-3}
    local iteration_delay=${ITERATION_DELAY:-60}
    
    log "Starting experiment: $EXPERIMENT_NAME"
    log "Total iterations: $total_iterations"
    
    # Deploy victim services
    deploy_victim_services "$VICTIM_SERVICES" "$TARGET_NODE" "$exp_id"
    
    # Wait for services to stabilize
    sleep 30
    
    # Run iterations
    for iteration in $(seq 1 $total_iterations); do
        log "=== Iteration $iteration/$total_iterations ==="
        
        run_iteration "$config_file" "$exp_id" "$iteration"
        
        # Wait between iterations
        if [[ $iteration -lt $total_iterations ]]; then
            log "Waiting ${iteration_delay}s before next iteration"
            sleep "$iteration_delay"
        fi
    done
    
    # Cleanup
    cleanup_victim_services "$VICTIM_SERVICES" "$TARGET_NODE"
    
    log "Experiment completed successfully"
}

# Main execution
main() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $0 <experiment-config-file>"
        echo ""
        echo "Example config file:"
        echo "EXPERIMENT_NAME='CPU Heavy Neighbor Impact'"
        echo "TARGET_NODE='node-1'"
        echo "VICTIM_SERVICES='frontend search user'"
        echo "PERF_COUNTER_SET='interference'"
        echo "NOISY_NEIGHBOR_TYPE='cpu'"
        echo "NOISY_NEIGHBOR_ARGS='4 300s'"
        echo "EXPERIMENT_DURATION=300"
        echo "ITERATIONS=5"
        echo "ITERATION_DELAY=120"
        exit 1
    fi
    
    local config_file="$1"
    
    # Validate configuration
    validate_config "$config_file"
    
    # Generate experiment ID
    local exp_id=$(generate_exp_id)
    log "Generated experiment ID: $exp_id"
    
    # Generate metadata
    generate_metadata "$config_file" "$exp_id"
    
    # Run experiment
    run_experiment "$config_file" "$exp_id"
    
    log "Experiment data stored in: $DATA_DIR"
    log "Experiment ID: $exp_id"
    log "Metadata: $DATA_DIR/metadata/${exp_id}_metadata.json"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi