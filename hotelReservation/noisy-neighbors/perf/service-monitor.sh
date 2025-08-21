#!/bin/bash
# service-monitor.sh - Enhanced with perf counter sets

# Define counter sets for different experiments
declare -A COUNTER_SETS=(
    ["basic"]="cycles,instructions,cache-references,cache-misses"
    ["cpu"]="cycles,instructions,branch-instructions,branch-misses,cpu-clock,task-clock"
    ["memory"]="cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses"
    ["scheduling"]="context-switches,cpu-migrations,page-faults,minor-faults,major-faults"
    ["bandwidth"]="cycles,instructions,cache-references,cache-misses,bus-cycles"
    ["interference"]="cycles,instructions,cache-misses,context-switches,page-faults,L1-dcache-load-misses"
)

resolve_service_to_pod() {
    local service_name=$1
    local namespace=${2:-default}
    
    # Send informational messages to stderr so they don't get captured
    echo "Resolving service '$service_name' to pod name..." >&2
    
    local pod_name=$(kubectl get pods -n $namespace --no-headers | grep "^${service_name}-" | head -1 | awk '{print $1}')
    
    if [[ -z "$pod_name" ]]; then
        echo "Error: No pod found for service '$service_name'" >&2
        echo "Available services:" >&2
        kubectl get pods -n $namespace --no-headers | awk '{print $1}' | sed 's/-[^-]*-[^-]*$//' | sort -u | sed 's/^/  /' >&2
        return 1
    fi
    
    echo "Found pod: $pod_name" >&2
    echo "$pod_name"  # Only this goes to stdout
}

monitor_service_remote() {
    local service_name=$1
    local namespace=${2:-default}
    local duration=${3:-30}
    local counter_set=${4:-basic}
    
    echo "=== Monitoring Service: $service_name ==="
    
    # Resolve service name to actual pod name
    local pod_name=$(resolve_service_to_pod $service_name $namespace)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # Now use the existing monitoring logic
    monitor_pod_remote $pod_name $namespace $duration $counter_set
}

monitor_pod_remote() {
    local pod_name=$1
    local namespace=${2:-default}
    local duration=${3:-30}
    local counter_set=${4:-basic}
    
    # Get counter list
    local counters="${COUNTER_SETS[$counter_set]}"
    if [[ -z "$counters" ]]; then
        echo "Error: Unknown counter set '$counter_set'"
        echo "Available counter sets: ${!COUNTER_SETS[@]}"
        return 1
    fi
    
    echo "=== Monitoring Pod: $pod_name ==="
    echo "Counter set: $counter_set"
    echo "Counters: $counters"
    echo "Duration: ${duration}s"
    
    # Validate pod exists and get info
    if ! kubectl get pod $pod_name -n $namespace &>/dev/null; then
        echo "Error: Pod $pod_name not found in namespace $namespace"
        return 1
    fi
    
    local node_name=$(kubectl get pod $pod_name -n $namespace -o jsonpath='{.spec.nodeName}')
    local container_id=$(kubectl get pod $pod_name -n $namespace -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|docker://||')
    local pod_status=$(kubectl get pod $pod_name -n $namespace -o jsonpath='{.status.phase}')
    
    echo "Pod status: $pod_status"
    echo "Node: $node_name"
    echo "Container ID: $container_id"
    
    if [[ "$pod_status" != "Running" ]]; then
        echo "Error: Pod is not in Running state"
        return 1
    fi
    
    # Test SSH connectivity
    if ! ssh -o ConnectTimeout=5 $node_name "echo 'SSH test'" &>/dev/null; then
        echo "Error: Cannot SSH to node $node_name"
        return 1
    fi
    
    # Execute monitoring with specified counters
    ssh $node_name "
        set -e
        
        echo 'Getting container PID...'
        PID=\$(docker inspect $container_id --format '{{.State.Pid}}' 2>/dev/null)
        
        if [[ -z \"\$PID\" || \"\$PID\" == \"0\" ]]; then
            echo 'Error: Could not get container PID or container not running'
            exit 1
        fi
        
        echo \"Container PID: \$PID\"
        
        if ! command -v perf &>/dev/null; then
            echo 'Error: perf command not found on this node'
            exit 1
        fi
        
        if ! sudo kill -0 \$PID 2>/dev/null; then
            echo 'Error: Cannot access process \$PID'
            exit 1
        fi
        
        echo 'Starting perf monitoring with counters: $counters'
        sudo perf stat -e $counters -p \$PID sleep $duration
    "
    
    local ssh_exit_code=$?
    
    if [[ $ssh_exit_code -eq 0 ]]; then
        echo "=== Monitoring completed successfully ==="
    else
        echo "=== Monitoring failed with exit code: $ssh_exit_code ==="
        return $ssh_exit_code
    fi
}

# Main execution
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <service_name|pod_name> [namespace] [duration] [counter_set]"
    echo ""
    echo "Parameters:"
    echo "  service_name     Service name (e.g., frontend, search) or full pod name"
    echo "  namespace        Kubernetes namespace (default: default)"
    echo "  duration         Monitoring duration in seconds (default: 30)"
    echo "  counter_set      Performance counter set (default: basic)"
    echo ""
    echo "Available counter sets:"
    for set in "${!COUNTER_SETS[@]}"; do
        echo "  $set: ${COUNTER_SETS[$set]}"
    done
    echo ""
    echo "Examples:"
    echo "  $0 frontend                           # Basic monitoring"
    echo "  $0 search default 60 cpu             # CPU interference study"
    echo "  $0 mongodb-user default 120 memory   # Memory interference study"
    echo "  $0 memcached-profile default 90 bandwidth  # Bandwidth study"
    echo ""
    echo "Available services in default namespace:"
    kubectl get pods --no-headers 2>/dev/null | awk '{print $1}' | sed 's/-[^-]*-[^-]*$//' | sort -u | sed 's/^/  /' || echo "  (kubectl not available)"
    exit 1
fi

# Parse arguments
input_name=$1
namespace=${2:-default}
duration=${3:-30}
counter_set=${4:-basic}

# Determine if input is a service name or full pod name
if [[ "$input_name" =~ -[a-z0-9]+-[a-z0-9]+$ ]]; then
    # Input looks like a full pod name (ends with -hash-hash)
    echo "Input appears to be a full pod name"
    monitor_pod_remote "$input_name" "$namespace" "$duration" "$counter_set"
else
    # Input looks like a service name
    echo "Input appears to be a service name"
    monitor_service_remote "$input_name" "$namespace" "$duration" "$counter_set"
fi