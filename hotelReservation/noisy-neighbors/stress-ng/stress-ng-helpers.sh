#!/bin/bash
# Stress-ng Helper Script for Kubernetes
# Usage: ./stress-ng-helpers.sh <command> [args...]
# Or create alias: alias my-stressng='./stress-ng-helpers.sh'

# Change this to your Docker Hub username
USERNAME="royno7"
IMAGE="${USERNAME}/stress-ng:latest"

# Main command function
my_stressng() {
    case "$1" in
        cpu)
            local workers=${2:-2}
            local duration=${3:-60s}
            kubectl run cpu-stress --image=$IMAGE --restart=Never -- --cpu $workers --timeout $duration
            ;;
        memory)
            local workers=${2:-1}
            local duration=${3:-60s}
            kubectl run mem-stress --image=$IMAGE --restart=Never -- --brk $workers --timeout $duration
            ;;
        vm)
            local workers=${2:-2}
            local size=${3:-512M}
            local duration=${4:-60s}
            kubectl run vm-stress --image=$IMAGE --restart=Never -- --vm $workers --vm-bytes $size --timeout $duration
            ;;
        pagefault)
            local workers=${2:-1}
            local duration=${3:-60s}
            kubectl run page-fault --image=$IMAGE --restart=Never -- --fault $workers --timeout $duration
            ;;
        io)
            local workers=${2:-2}
            local duration=${3:-60s}
            kubectl run io-stress --image=$IMAGE --restart=Never -- --io $workers --timeout $duration
            ;;
        network)
            local workers=${2:-2}
            local duration=${3:-60s}
            kubectl run sock-stress --image=$IMAGE --restart=Never -- --sock $workers --timeout $duration
            ;;
        noisy)
            local duration=${2:-0}  # 0 = infinite
            kubectl run noisy-neighbor --image=$IMAGE --restart=Never -- --cpu 2 --vm 1 --vm-bytes 1G --brk 1 --io 2 --sock 1 --timeout $duration
            ;;
        cleanup)
            kubectl delete pod cpu-stress mem-stress vm-stress page-fault io-stress sock-stress noisy-neighbor heavy-load 2>/dev/null || true
            echo "Cleaned up stress test pods"
            ;;
        status)
            echo "Current stress test pods:"
            kubectl get pods | grep -E "(cpu-stress|mem-stress|vm-stress|page-fault|io-stress|sock-stress|noisy-neighbor|heavy-load)" || echo "No stress test pods running"
            ;;
        help|--help|-h)
            echo "Stress-ng Helper Commands"
            echo "========================="
            echo ""
            echo "Usage: my-stressng <command> [args...]"
            echo ""
            echo "Commands:"
            echo "  cpu [workers] [duration]           # Default: 2 workers, 60s"
            echo "  memory [workers] [duration]        # Default: 1 worker, 60s"
            echo "  vm [workers] [size] [duration]     # Default: 2 workers, 512M, 60s"
            echo "  pagefault [workers] [duration]     # Default: 1 worker, 60s"
            echo "  io [workers] [duration]            # Default: 2 workers, 60s"
            echo "  network [workers] [duration]       # Default: 2 workers, 60s"
            echo "  noisy [duration]                   # Combined load (default: infinite)"
            echo ""
            echo "Utilities:"
            echo "  cleanup                            # Remove all stress test pods"
            echo "  status                             # Show running stress test pods"
            echo "  help                               # Show this help"
            echo ""
            echo "Examples:"
            echo "  my-stressng cpu 4 120s             # 4 CPU workers for 2 minutes"
            echo "  my-stressng vm 2 1G 60s            # 2 VM workers with 1GB each"
            echo "  my-stressng noisy 300s             # Mixed load for 5 minutes"
            echo "  my-stressng noisy                  # Infinite noisy neighbor"
            echo "  my-stressng status                 # Check running pods"
            echo "  my-stressng cleanup                # Clean up all stress pods"
            echo ""
            echo "Setup:"
            echo "  # Option 1: Use directly"
            echo "  ./stress-ng-helpers.sh cpu 4 60s"
            echo ""
            echo "  # Option 2: Create alias (recommended)"
            echo "  alias my-stressng='$(pwd)/stress-ng-helpers.sh'"
            echo "  my-stressng cpu 4 60s"
            echo ""
            echo "  # Option 3: Add to PATH"
            echo "  sudo cp stress-ng-helpers.sh /usr/local/bin/my-stressng"
            echo "  my-stressng cpu 4 60s"
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