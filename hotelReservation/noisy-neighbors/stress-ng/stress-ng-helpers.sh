#!/bin/bash
# Stress-ng Helper Functions for Kubernetes
# Source this file: source stress-ng-helpers.sh

# Change this to your Docker Hub username
USERNAME="royno7"
IMAGE="${USERNAME}/stress-ng:latest"

# Simple wrapper functions that map directly to stress-ng commands

cpu() {
    local workers=${1:-2}
    local duration=${2:-60s}
    kubectl run cpu-stress --image=$IMAGE --restart=Never -- --cpu $workers --timeout $duration
}

memory() {
    local workers=${1:-1}
    local duration=${2:-60s}
    kubectl run mem-stress --image=$IMAGE --restart=Never -- --brk $workers --timeout $duration
}

vm() {
    local workers=${1:-2}
    local size=${2:-512M}
    local duration=${3:-60s}
    kubectl run vm-stress --image=$IMAGE --restart=Never -- --vm $workers --vm-bytes $size --timeout $duration
}

pagefault() {
    local workers=${1:-1}
    local duration=${2:-60s}
    kubectl run page-fault --image=$IMAGE --restart=Never -- --fault $workers --timeout $duration
}

io() {
    local workers=${1:-2}
    local duration=${2:-60s}
    kubectl run io-stress --image=$IMAGE --restart=Never -- --io $workers --timeout $duration
}

network() {
    local workers=${1:-2}
    local duration=${2:-60s}
    kubectl run sock-stress --image=$IMAGE --restart=Never -- --sock $workers --timeout $duration
}

# Combined noisy neighbor
noisy() {
    local duration=${1:-0}  # 0 = infinite
    kubectl run noisy-neighbor --image=$IMAGE --restart=Never -- --cpu 2 --vm 1 --vm-bytes 1G --brk 1 --io 2 --sock 1 --timeout $duration
}

# Cleanup function
cleanup() {
    kubectl delete pod cpu-stress mem-stress vm-stress page-fault io-stress sock-stress noisy-neighbor heavy-load 2>/dev/null || true
    echo "Cleaned up stress test pods"
}

# Show current stress pods
status() {
    echo "Current stress test pods:"
    kubectl get pods | grep -E "(cpu-stress|mem-stress|vm-stress|page-fault|io-stress|sock-stress|noisy-neighbor|heavy-load)" || echo "No stress test pods running"
}

# Help function
help() {
    echo "Stress-ng Helper Functions"
    echo "========================="
    echo ""
    echo "Usage:"
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
    echo "  cpu 4 120s                         # 4 CPU workers for 2 minutes"
    echo "  vm 2 1G 60s                        # 2 VM workers with 1GB each"
    echo "  noisy 300s                         # Mixed load for 5 minutes"
    echo "  noisy                              # Infinite noisy neighbor"
    echo ""
    echo "Direct kubectl examples:"
    echo "  kubectl run test --image=$IMAGE --restart=Never -- --cpu 4 --vm 2 --vm-bytes 1G --timeout 60s"
}

# Show help if no arguments provided when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    help
fi