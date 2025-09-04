#!/bin/bash
# Stress-ng Helper Script for Kubernetes
# Usage: ./stress-ng-helpers.sh <command> [args...] [--node <node-name>] [--image-tag <tag>]
# Or create alias: alias my-stressng='./stress-ng-helpers.sh'

# Change this to your Docker Hub username
USERNAME="royno7"
IMAGE="${USERNAME}/stress-ng:latest"

# Function to extract node parameter from arguments
extract_node_param() {
    local node=""
    local args=()
    
    for ((i=0; i<${#@}; i++)); do
        if [[ "${@:$((i+1)):1}" == "--node" ]] || [[ "${@:$((i+1)):1}" == "-n" ]]; then
            if [[ $((i+2)) -le ${#@} ]]; then
                node="${@:$((i+2)):1}"
                i=$((i+1))  # Skip the next argument since we consumed it
            fi
        elif [[ "${@:$((i+1)):1}" != "--node" ]] && [[ "${@:$((i+1)):1}" != "-n" ]]; then
            args+=("${@:$((i+1)):1}")
        fi
    done
    
    echo "$node"
}

# Function to extract image tag parameter from arguments
extract_image_tag_param() {
    local image_tag=""
    
    for ((i=0; i<${#@}; i++)); do
        if [[ "${@:$((i+1)):1}" == "--image-tag" ]] || [[ "${@:$((i+1)):1}" == "-t" ]]; then
            if [[ $((i+2)) -le ${#@} ]]; then
                image_tag="${@:$((i+2)):1}"
                break
            fi
        fi
    done
    
    echo "$image_tag"
}

# Function to create kubectl command with optional node selection and toleration
create_kubectl_cmd() {
    local pod_name="$1"
    local image="$2"
    local args="$3"
    local node="$4"
    
    local cmd="kubectl run $pod_name --image=$image --restart=Never"
    
    if [[ -n "$node" ]]; then
        # Add both nodeSelector and toleration for tainted nodes
        local overrides="{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$node\"},\"tolerations\":[{\"key\":\"dedicated\",\"operator\":\"Equal\",\"value\":\"special\",\"effect\":\"NoSchedule\"}]}}"
        cmd="$cmd --overrides='$overrides'"
    fi
    
    cmd="$cmd -- $args"
    echo "$cmd"
}

# Main command function
my_stressng() {
    # Extract node and image tag parameters if present
    local node=$(extract_node_param "$@")
    local image_tag=$(extract_image_tag_param "$@")
    local args=()
    
    # Set image with custom tag if provided
    local current_image="$IMAGE"
    if [[ -n "$image_tag" ]]; then
        current_image="${USERNAME}/stress-ng:${image_tag}"
    fi
    
    # Rebuild arguments without node and image-tag parameters
    for ((i=0; i<${#@}; i++)); do
        if [[ "${@:$((i+1)):1}" == "--node" ]] || [[ "${@:$((i+1)):1}" == "-n" ]]; then
            i=$((i+1))  # Skip the node parameter
        elif [[ "${@:$((i+1)):1}" == "--image-tag" ]] || [[ "${@:$((i+1)):1}" == "-t" ]]; then
            i=$((i+1))  # Skip the image-tag parameter
        elif [[ "${@:$((i+1)):1}" != "--node" ]] && [[ "${@:$((i+1)):1}" != "-n" ]] && [[ "${@:$((i+1)):1}" != "--image-tag" ]] && [[ "${@:$((i+1)):1}" != "-t" ]]; then
            args+=("${@:$((i+1)):1}")
        fi
    done
    
    case "${args[0]}" in
        cpu)
            local workers=${args[1]:-2}
            local duration=${args[2]:-60s}
            local cmd=$(create_kubectl_cmd "cpu-stress" "$current_image" "--cpu $workers --timeout $duration" "$node")
            eval $cmd
            ;;
        memory)
            local workers=${args[1]:-1}
            local duration=${args[2]:-60s}
            local cmd=$(create_kubectl_cmd "mem-stress" "$current_image" "--stream $workers --timeout $duration" "$node")
            eval $cmd
            ;;
        vm)
            local workers=${args[1]:-2}
            local size=${args[2]:-512M}
            local duration=${args[3]:-60s}
            local cmd=$(create_kubectl_cmd "vm-stress" "$current_image" "--vm $workers --vm-bytes $size --timeout $duration" "$node")
            eval $cmd
            ;;
        pagefault)
            local workers=${args[1]:-1}
            local duration=${args[2]:-60s}
            local cmd=$(create_kubectl_cmd "page-fault" "$current_image" "--fault $workers --timeout $duration" "$node")
            eval $cmd
            ;;
        io)
            local workers=${args[1]:-2}
            local duration=${args[2]:-60s}
            local cmd=$(create_kubectl_cmd "io-stress" "$current_image" "--io $workers --timeout $duration" "$node")
            eval $cmd
            ;;
        network)
            local workers=${args[1]:-2}
            local duration=${args[2]:-60s}
            local cmd=$(create_kubectl_cmd "udp-stress" "$current_image" "--udp $workers --timeout $duration" "$node")
            eval $cmd
            ;;
        noisy)
            local duration=${args[1]:-0}  # 0 = infinite
            local cmd=$(create_kubectl_cmd "noisy-neighbor" "$current_image" "--cpu 2 --vm 1 --vm-bytes 1G --stream 1 --io 2 --udp 1 --timeout $duration" "$node")
            eval $cmd
            ;;
        cleanup)
            kubectl delete pod cpu-stress mem-stress vm-stress page-fault io-stress udp-stress noisy-neighbor heavy-load 2>/dev/null || true
            echo "Cleaned up stress test pods"
            ;;
        status)
            echo "Current stress test pods:"
            kubectl get pods -o wide | grep -E "(cpu-stress|mem-stress|vm-stress|page-fault|io-stress|udp-stress|noisy-neighbor|heavy-load)" || echo "No stress test pods running"
            ;;
        nodes)
            echo "Available nodes:"
            kubectl get nodes -o custom-columns="NAME:.metadata.name,STATUS:.status.conditions[?(@.type=='Ready')].status,ROLES:.metadata.labels.kubernetes\.io/role"
            ;;
        help|--help|-h)
            echo "Stress-ng Helper Commands"
            echo "========================="
            echo ""
            echo "Usage: my-stressng <command> [args...] [--node <node-name>] [--image-tag <tag>]"
            echo ""
            echo "Commands:"
            echo "  cpu [workers] [duration] [--node <node>] [--image-tag <tag>]           # Default: 2 workers, 60s"
            echo "  memory [workers] [duration] [--node <node>] [--image-tag <tag>]        # Default: 1 worker, 60s"
            echo "  vm [workers] [size] [duration] [--node <node>] [--image-tag <tag>]     # Default: 2 workers, 512M, 60s"
            echo "  pagefault [workers] [duration] [--node <node>] [--image-tag <tag>]     # Default: 1 worker, 60s"
            echo "  io [workers] [duration] [--node <node>] [--image-tag <tag>]            # Default: 2 workers, 60s"
            echo "  network [workers] [duration] [--node <node>] [--image-tag <tag>]       # Default: 2 workers, 60s"
            echo "  noisy [duration] [--node <node>] [--image-tag <tag>]                   # Combined load (default: infinite)"
            echo ""
            echo "Utilities:"
            echo "  cleanup                            # Remove all stress test pods"
            echo "  status                             # Show running stress test pods"
            echo "  nodes                              # List available nodes"
            echo "  help                               # Show this help"
            echo ""
            echo "Options:"
            echo "  --node <node-name>                 # Deploy pod to specific node (includes toleration for tainted nodes)"
            echo "  -n <node-name>                     # Short form for node selection"
            echo "  --image-tag <tag>                  # Use specific image tag (default: latest)"
            echo "  -t <tag>                           # Short form for image tag selection"
            echo ""
            echo "Examples:"
            echo "  my-stressng cpu 4 120s --node node-0               # 4 CPU workers for 2 minutes on node-0"
            echo "  my-stressng vm 2 1G 60s -n node-1                 # 2 VM workers with 1GB each on node-1"
            echo "  my-stressng noisy 300s --node node-2               # Mixed load for 5 minutes on node-2"
            echo "  my-stressng noisy --node node-3                    # Infinite noisy neighbor on node-3"
            echo "  my-stressng cpu 2 60s --image-tag v1.2.3           # Use specific image tag"
            echo "  my-stressng memory 1 30s -t dev --node node-1      # Use dev tag on specific node"
            echo "  my-stressng status                                 # Check running pods"
            echo "  my-stressng nodes                                  # List available nodes"
            echo "  my-stressng cleanup                                # Clean up all stress pods"
            echo ""
            echo "Setup:"
            echo "  # Option 1: Use directly"
            echo "  ./stress-ng-helpers.sh cpu 4 60s --node node-0 --image-tag v1.2.3"
            echo ""
            echo "  # Option 2: Create alias (recommended)"
            echo "  alias my-stressng='$(pwd)/stress-ng-helpers.sh'"
            echo "  my-stressng cpu 4 60s --node node-0 -t latest"
            echo ""
            echo "  # Option 3: Add to PATH"
            echo "  sudo cp stress-ng-helpers.sh /usr/local/bin/my-stressng"
            echo "  my-stressng cpu 4 60s --node node-0 --image-tag stable"
            ;;
        *)
            echo "Unknown command: $1"
            echo "Use 'my-stressng help' for usage information"
            exit 1
            ;;
    esac
}

# If script is run directly (not sourced), call the main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -eq 0 ]; then
        my_stressng help
    else
        my_stressng "$@"
    fi
fi

# Also define the function for sourcing (backwards compatibility)
alias my-stressng='my_stressng'