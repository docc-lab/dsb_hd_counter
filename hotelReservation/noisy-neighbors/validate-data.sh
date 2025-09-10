#!/bin/bash
# Simple Data Validation Script
# Usage: ./validate-data.sh [experiment-id] [--verbose] 

DATA_DIR="${DATA_DIR:-./experiment_data}"
EXPERIMENT_ID="$1"
VERBOSE="$2"

log() {
    if [[ "$VERBOSE" == "--verbose" ]] || [[ "$2" == "ERROR" ]] || [[ "$2" == "WARNING" ]]; then
        echo "[$(date '+%H:%M:%S')] [$2] $1"
    fi
}

validate_experiment() {
    local exp_id="$1"
    local errors=0
    local warnings=0
    
    log "Validating experiment: $exp_id" "INFO"
    
    # Check metadata exists
    local metadata_file="$DATA_DIR/metadata/${exp_id}_metadata.json"
    if [[ ! -f "$metadata_file" ]]; then
        log "Missing metadata file: $metadata_file" "ERROR"
        ((errors++))
        return $errors
    fi
    
    # Parse metadata to get expected iterations and services
    local expected_iterations=$(python3 -c "
import json
try:
    with open('$metadata_file') as f:
        data = json.load(f)
    print(data.get('configuration', {}).get('iterations', 1))
except:
    print('1')
" 2>/dev/null)
    
    local victim_services=$(python3 -c "
import json
try:
    with open('$metadata_file') as f:
        data = json.load(f)
    services = data.get('configuration', {}).get('victim_services', '')
    print(services)
except:
    print('')
" 2>/dev/null)
    
    log "Expected iterations: $expected_iterations" "DEBUG"
    log "Victim services: $victim_services" "DEBUG"
    
    # Check raw data files for each iteration and service
    for iteration in $(seq 1 $expected_iterations); do
        log "Checking iteration $iteration" "DEBUG"
        
        # Check perf files
        for service in $victim_services; do
            local perf_file="$DATA_DIR/raw/${exp_id}_perf_${service}_${iteration}.txt"
            if [[ ! -f "$perf_file" ]]; then
                log "Missing perf file: $perf_file" "WARNING"
                ((warnings++))
            elif [[ ! -s "$perf_file" ]]; then
                log "Empty perf file: $perf_file" "WARNING"
                ((warnings++))
            else
                log "Found perf file for $service iteration $iteration" "DEBUG"
            fi
            
            # Check trace files
            local trace_file="$DATA_DIR/raw/${exp_id}_traces_${service}_${iteration}.csv"
            if [[ ! -f "$trace_file" ]]; then
                log "Missing trace file: $trace_file" "WARNING"
                ((warnings++))
            elif [[ ! -s "$trace_file" ]]; then
                log "Empty trace file: $trace_file" "WARNING"
                ((warnings++))
            else
                local line_count=$(wc -l < "$trace_file")
                if [[ $line_count -lt 2 ]]; then
                    log "Insufficient trace data in $trace_file (lines: $line_count)" "WARNING"
                    ((warnings++))
                fi
                log "Found trace file for $service iteration $iteration ($line_count lines)" "DEBUG"
            fi
        done
        
        # Check system metrics files
        for phase in baseline during end; do
            local nodes_file="$DATA_DIR/raw/${exp_id}_nodes_${phase}_${iteration}.txt"
            local pods_file="$DATA_DIR/raw/${exp_id}_pods_${phase}_${iteration}.txt"
            
            if [[ ! -f "$nodes_file" ]]; then
                log "Missing nodes metrics: $nodes_file" "WARNING"
                ((warnings++))
            fi
            
            if [[ ! -f "$pods_file" ]]; then
                log "Missing pods metrics: $pods_file" "WARNING"
                ((warnings++))
            fi
        done
        
        # Check stress log
        local stress_file="$DATA_DIR/raw/${exp_id}_stress_${iteration}.txt"
        if [[ ! -f "$stress_file" ]]; then
            log "Missing stress log: $stress_file" "WARNING"
            ((warnings++))
        fi
    done
    
    # Summary
    log "Validation complete - Errors: $errors, Warnings: $warnings" "INFO"
    
    # Generate simple report
    cat > "$DATA_DIR/validation_${exp_id}.txt" << EOF
Validation Report for $exp_id
Generated: $(date)
Errors: $errors
Warnings: $warnings

Raw data files found:
$(find "$DATA_DIR/raw" -name "${exp_id}_*" | wc -l) files

File breakdown:
$(find "$DATA_DIR/raw" -name "${exp_id}_*" -type f -exec basename {} \; | cut -d'_' -f3 | sort | uniq -c)

Total data size: $(du -sh "$DATA_DIR/raw" | cut -f1)
EOF
    
    return $errors
}

# Main execution
main() {
    if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        echo "Usage: $0 [experiment-id] [--verbose]"
        echo ""
        echo "Examples:"
        echo "  $0                           # Validate all experiments"
        echo "  $0 exp_20241201_143022       # Validate specific experiment"
        echo "  $0 exp_20241201_143022 --verbose  # Detailed output"
        exit 0
    fi
    
    if [[ ! -d "$DATA_DIR" ]]; then
        log "Data directory not found: $DATA_DIR" "ERROR"
        exit 1
    fi
    
    local total_errors=0
    
    if [[ -n "$EXPERIMENT_ID" ]]; then
        # Validate specific experiment
        validate_experiment "$EXPERIMENT_ID"
        total_errors=$?
    else
        # Validate all experiments
        for metadata_file in "$DATA_DIR/metadata/"*_metadata.json; do
            if [[ -f "$metadata_file" ]]; then
                local exp_id=$(basename "$metadata_file" | sed 's/_metadata.json$//')
                validate_experiment "$exp_id"
                total_errors=$((total_errors + $?))
            fi
        done
    fi
    
    if [[ $total_errors -eq 0 ]]; then
        log "All experiments validated successfully" "INFO"
        exit 0
    else
        log "Validation completed with $total_errors errors" "ERROR"
        exit 1
    fi
}

main "$@"