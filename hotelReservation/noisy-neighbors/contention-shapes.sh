#!/bin/bash
# Contention Base Functions
# Simple building blocks for manually defining burst schedules
# Format: "start_time:duration:intensity"

# Base function: Create a single burst
# Args: start_time duration intensity
burst() {
    local start_time="$1"
    local duration="$2"
    local intensity="$3"
    
    echo "${start_time}:${duration}:${intensity}"
}

# Base function: Create multiple identical bursts
# Args: start_time burst_duration idle_time num_bursts intensity
repeat_burst() {
    local start_time="$1"
    local burst_duration="$2"
    local idle_time="$3"
    local num_bursts="$4"
    local intensity="$5"
    
    local bursts=()
    local current_time=$start_time
    
    for ((i=0; i<num_bursts; i++)); do
        bursts+=("${current_time}:${burst_duration}:${intensity}")
        current_time=$((current_time + burst_duration + idle_time))
    done
    
    echo "${bursts[@]}"
}

# Base function: Create bursts with linearly changing intensity
# Args: start_time burst_duration idle_time num_bursts start_intensity end_intensity
linear_intensity() {
    local start_time="$1"
    local burst_duration="$2"
    local idle_time="$3"
    local num_bursts="$4"
    local start_intensity="$5"
    local end_intensity="$6"
    
    local bursts=()
    local current_time=$start_time
    
    for ((i=0; i<num_bursts; i++)); do
        # Linear interpolation
        local intensity=$(awk "BEGIN {printf \"%.0f\", $start_intensity + ($end_intensity - $start_intensity) * $i / ($num_bursts - 1)}")
        bursts+=("${current_time}:${burst_duration}:${intensity}")
        current_time=$((current_time + burst_duration + idle_time))
    done
    
    echo "${bursts[@]}"
}

# Helper: Parse burst specification string
# Returns: start_time duration intensity (space-separated)
parse_burst_spec() {
    local spec="$1"
    echo "$spec" | tr ':' ' '
}

# Helper: Calculate total experiment duration from burst list
calculate_total_duration() {
    local bursts=("$@")
    local max_end_time=0
    
    for burst in "${bursts[@]}"; do
        IFS=':' read -r start duration intensity <<< "$burst"
        local end_time=$((start + duration))
        [[ $end_time -gt $max_end_time ]] && max_end_time=$end_time
    done
    
    echo "$max_end_time"
}

# Helper: Validate burst specification
validate_burst_spec() {
    local spec="$1"
    
    if [[ ! "$spec" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
        echo "ERROR: Invalid burst specification: $spec" >&2
        echo "Expected format: start_time:duration:intensity" >&2
        return 1
    fi
    
    return 0
}

# Helper: Combine multiple burst arrays
combine_bursts() {
    local bursts=("$@")
    echo "${bursts[@]}"
}

# Print usage information
print_usage() {
    cat << 'EOF'
Contention Base Functions:

Simple building blocks for manually defining burst schedules.

Available Functions:

1. burst <start_time> <duration> <intensity>
   Create a single burst
   Example: burst 0 30 4
   Output: "0:30:4"

2. repeat_burst <start_time> <burst_duration> <idle_time> <num_bursts> <intensity>
   Create multiple identical bursts
   Example: repeat_burst 0 30 10 5 4
   Output: "0:30:4 40:30:4 80:30:4 120:30:4 160:30:4"

3. linear_intensity <start_time> <burst_duration> <idle_time> <num_bursts> <start_intensity> <end_intensity>
   Create bursts with linearly changing intensity
   Example: linear_intensity 0 20 10 5 2 10
   Output: "0:20:2 30:20:4 60:20:6 90:20:8 120:20:10"

Usage in Config:

# Method 1: Direct burst specification
CONTENTION_BURSTS="0:30:4 40:30:4 80:30:6"

# Method 2: Using helper functions (must source contention-shapes.sh)
source ./contention-shapes.sh
CONTENTION_BURSTS=$(repeat_burst 0 30 10 5 4)

# Method 3: Combining multiple patterns
BURST1=$(repeat_burst 0 30 10 3 4)
BURST2=$(burst 150 60 8)
CONTENTION_BURSTS="$BURST1 $BURST2"

Burst Format:
  "start_time:duration:intensity"
  - start_time: seconds from iteration start
  - duration: seconds
  - intensity: workload-specific (e.g., CPU count, memory MB)

Examples:

  # Simple fixed pattern (5 bursts, 30s each, 10s idle, 4 CPUs)
  repeat_burst 0 30 10 5 4

  # Escalating intensity (2→10 CPUs)
  linear_intensity 0 20 10 5 2 10

  # Spike pattern (minor + major + minor)
  MINOR=$(repeat_burst 0 15 30 3 2)
  MAJOR=$(burst 135 60 8)
  MINOR2=$(repeat_burst 225 15 30 3 2)
  CONTENTION_BURSTS="$MINOR $MAJOR $MINOR2"

EOF
}

# Main: Allow script to be sourced or run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being run directly - provide CLI interface
    if [[ $# -eq 0 || "$1" == "help" || "$1" == "--help" ]]; then
        print_usage
        exit 0
    fi
    
    # Execute function with arguments
    "$@"
fi
