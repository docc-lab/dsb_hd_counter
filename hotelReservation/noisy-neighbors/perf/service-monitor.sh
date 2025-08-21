#!/bin/bash
# service-monitor.sh - Fixed version

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
    
    echo "=== Monitoring Service: $service_name ==="
    
    # Resolve service name to actual pod name
    local pod_name=$(resolve_service_to_pod $service_name $namespace)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # Now use the existing monitoring logic
    monitor_pod_remote $pod_name $namespace $duration
}

monitor_pod_remote() {
    local pod_name=$1
    local namespace=${2:-default}
    local duration=${3:-30}
    
    echo "=== Monitoring Pod: $pod_name ==="
    
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
    
    # Execute monitoring
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
        
        echo 'Starting perf monitoring for $duration seconds...'
        sudo perf stat -p \$PID sleep $duration
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
    echo "Usage: $0 <service_name|pod_name> [namespace] [duration]"
    echo ""
    echo "Examples:"
    echo "  $0 frontend              # Monitor frontend service"
    echo "  $0 mongodb-user         # Monitor mongodb-user service"  
    echo "  $0 memcached-profile    # Monitor memcached-profile service"
    echo "  $0 frontend default 60  # Monitor for 60 seconds"
    echo ""
    echo "Available services in default namespace:"
    kubectl get pods --no-headers 2>/dev/null | awk '{print $1}' | sed 's/-[^-]*-[^-]*$//' | sort -u | sed 's/^/  /' || echo "  (kubectl not available)"
    exit 1
fi

# Determine if input is a service name or full pod name
input_name=$1
if [[ "$input_name" =~ -[a-z0-9]+-[a-z0-9]+$ ]]; then
    # Input looks like a full pod name (ends with -hash-hash)
    echo "Input appears to be a full pod name"
    monitor_pod_remote "$@"
else
    # Input looks like a service name
    echo "Input appears to be a service name"
    monitor_service_remote "$@"
fi