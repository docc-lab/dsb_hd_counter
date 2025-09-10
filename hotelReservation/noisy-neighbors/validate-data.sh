#!/bin/bash
# Improved Data Validation Script
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
    local exp_dir="$DATA_DIR/$exp_id"
    local errors=0
    local warnings=0
    
    log "Validating experiment: $exp_id" "INFO"
    
    # Check if experiment directory exists
    if [[ ! -d "$exp_dir" ]]; then
        log "Experiment directory not found: $exp_dir" "ERROR"
        return 1
    fi
    
    # Check metadata exists
    local metadata_file="$exp_dir/metadata/experiment.json"
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
    
    local wrk2_target=$(python3 -c "
import json
try:
    with open('$metadata_file') as f:
        data = json.load(f)
    target = data.get('configuration', {}).get('wrk2_config', {}).get('target_service', '')
    print(target)
except:
    print('')
" 2>/dev/null)
    
    log "Expected iterations: $expected_iterations" "DEBUG"
    log "Victim services: $victim_services" "DEBUG"
    log "Workload target: ${wrk2_target:-none}" "DEBUG"
    
    # Check directory structure
    local required_dirs=("raw/perf" "raw/latency" "raw/system" "raw/stress" "processed" "logs" "metadata")
    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$exp_dir/$dir" ]]; then
            log "Missing directory: $exp_dir/$dir" "WARNING"
            ((warnings++))
        fi
    done
    
    # Check raw data files for each iteration and service
    for iteration in $(seq 1 $expected_iterations); do
        log "Checking iteration $iteration" "DEBUG"
        
        # Check performance files
        for service in $victim_services; do
            local perf_file="$exp_dir/raw/perf/${service}_iter${iteration}.txt"
            if [[ ! -f "$perf_file" ]]; then
                log "Missing perf file: $perf_file" "WARNING"
                ((warnings++))
            elif [[ ! -s "$perf_file" ]]; then
                log "Empty perf file: $perf_file" "WARNING"
                ((warnings++))
            else
                log "Found perf file for $service iteration $iteration" "DEBUG"
            fi
        done
        
        # Check latency files (only if wrk2 target is configured)
        if [[ -n "$wrk2_target" && "$wrk2_target" != "none" ]]; then
            local latency_file="$exp_dir/raw/latency/${wrk2_target}_iter${iteration}.txt"
            if [[ ! -f "$latency_file" ]]; then
                log "Missing latency file: $latency_file" "WARNING"
                ((warnings++))
            elif [[ ! -s "$latency_file" ]]; then
                log "Empty latency file: $latency_file" "WARNING"
                ((warnings++))
            else
                # Check if wrk2 output contains expected sections
                if ! grep -q "Thread Stats" "$latency_file" 2>/dev/null; then
                    log "Latency file appears incomplete (missing Thread Stats): $latency_file" "WARNING"
                    ((warnings++))
                fi
                log "Found latency file for $wrk2_target iteration $iteration" "DEBUG"
            fi
        fi
        
        # Check system metrics files
        for phase in baseline during end; do
            local system_file="$exp_dir/raw/system/metrics_${phase}_iter${iteration}.txt"
            
            if [[ ! -f "$system_file" ]]; then
                log "Missing system metrics: $system_file" "WARNING"
                ((warnings++))
            elif [[ ! -s "$system_file" ]]; then
                log "Empty system metrics: $system_file" "WARNING"
                ((warnings++))
            else
                # Check if system metrics contain expected sections
                if ! grep -q "=== NODE METRICS ===" "$system_file" 2>/dev/null; then
                    log "System metrics file appears incomplete: $system_file" "WARNING"
                    ((warnings++))
                fi
            fi
        done
        
        # Check stress log
        local stress_file="$exp_dir/raw/stress/stress_iter${iteration}.txt"
        if [[ ! -f "$stress_file" ]]; then
            log "Missing stress log: $stress_file" "WARNING"
            ((warnings++))
        elif [[ ! -s "$stress_file" ]]; then
            log "Empty stress log: $stress_file" "WARNING"
            ((warnings++))
        fi
    done
    
    # Check processed files
    local summary_files=("latency_summary.txt" "performance_summary.txt" "experiment_summary.txt")
    for file in "${summary_files[@]}"; do
        if [[ ! -f "$exp_dir/processed/$file" ]]; then
            log "Missing processed file: $exp_dir/processed/$file" "WARNING"
            ((warnings++))
        fi
    done
    
    # Check log file
    if [[ ! -f "$exp_dir/logs/collector.log" ]]; then
        log "Missing collector log: $exp_dir/logs/collector.log" "WARNING"
        ((warnings++))
    fi
    
    # Data quality checks
    local total_files=$(find "$exp_dir/raw" -name "*.txt" -o -name "*.csv" | wc -l)
    local empty_files=$(find "$exp_dir/raw" -name "*.txt" -o -name "*.csv" -empty | wc -l)
    
    if [[ $empty_files -gt 0 ]]; then
        log "Found $empty_files empty data files" "WARNING"
        ((warnings++))
    fi
    
    # Summary
    log "Validation complete - Errors: $errors, Warnings: $warnings" "INFO"
    log "Total raw files: $total_files, Empty files: $empty_files" "INFO"
    
    # Generate validation report
    cat > "$exp_dir/validation_report.txt" << EOF
=== VALIDATION REPORT ===
Experiment ID: $exp_id
Generated: $(date -Iseconds)
Errors: $errors
Warnings: $warnings

=== CONFIGURATION ===
Expected iterations: $expected_iterations
Victim services: $victim_services
Workload target: ${wrk2_target:-none}

=== FILE STATISTICS ===
Total raw data files: $total_files
Empty files: $empty_files
Total experiment size: $(du -sh "$exp_dir" | cut -f1)

=== DIRECTORY STRUCTURE ===
$(find "$exp_dir" -type d | sort)

=== RAW DATA BREAKDOWN ===
Performance files: $(find "$exp_dir/raw/perf" -name "*.txt" | wc -l)
Latency files: $(find "$exp_dir/raw/latency" -name "*.txt" | wc -l)
System metrics files: $(find "$exp_dir/raw/system" -name "*.txt" | wc -l)
Stress files: $(find "$exp_dir/raw/stress" -name "*.txt" | wc -l)

=== PROCESSED FILES ===
$(ls -la "$exp_dir/processed/" 2>/dev/null || echo "No processed files found")

=== RECENT LOG ENTRIES ===
$(tail -10 "$exp_dir/logs/collector.log" 2>/dev/null || echo "No log file found")
EOF
    
    return $errors
}

# List all experiments
list_experiments() {
    echo "Available experiments in $DATA_DIR:"
    echo ""
    
    if [[ ! -d "$DATA_DIR" ]]; then
        echo "Data directory not found: $DATA_DIR"
        return 1
    fi
    
    local found_any=false
    for exp_dir in "$DATA_DIR"/exp_*; do
        if [[ -d "$exp_dir" ]]; then
            found_any=true
            local exp_id=$(basename "$exp_dir")
            local metadata_file="$exp_dir/metadata/experiment.json"
            
            if [[ -f "$metadata_file" ]]; then
                local exp_name=$(python3 -c "
import json
try:
    with open('$metadata_file') as f:
        data = json.load(f)
    print(data.get('experiment_name', 'Unknown'))
except:
    print('Unknown')
" 2>/dev/null)
                local timestamp=$(python3 -c "
import json
try:
    with open('$metadata_file') as f:
        data = json.load(f)
    print(data.get('timestamp', 'Unknown'))
except:
    print('Unknown')
" 2>/dev/null)
                
                echo "$exp_id: $exp_name ($timestamp)"
            else
                echo "$exp_id: (no metadata)"
            fi
        fi
    done
    
    if [[ "$found_any" == "false" ]]; then
        echo "No experiments found."
        return 1
    fi
}

# Generate summary across all experiments
generate_global_summary() {
    local summary_file="$DATA_DIR/validation_summary.txt"
    
    {
        echo "=== GLOBAL EXPERIMENT VALIDATION SUMMARY ==="
        echo "Generated: $(date -Iseconds)"
        echo "Data directory: $DATA_DIR"
        echo ""
        
        local total_experiments=0
        local total_errors=0
        local total_warnings=0
        
        for exp_dir in "$DATA_DIR"/exp_*; do
            if [[ -d "$exp_dir" ]]; then
                ((total_experiments++))
                local exp_id=$(basename "$exp_dir")
                
                # Run validation and capture results
                local validation_output=$(validate_experiment "$exp_id" 2>&1)
                local exp_errors=$(echo "$validation_output" | grep -c "ERROR" || echo 0)
                local exp_warnings=$(echo "$validation_output" | grep -c "WARNING" || echo 0)
                
                total_errors=$((total_errors + exp_errors))
                total_warnings=$((total_warnings + exp_warnings))
                
                echo "$exp_id: $exp_errors errors, $exp_warnings warnings"
            fi
        done
        
        echo ""
        echo "=== SUMMARY ==="
        echo "Total experiments: $total_experiments"
        echo "Total errors: $total_errors"
        echo "Total warnings: $total_warnings"
        echo "Overall data size: $(du -sh "$DATA_DIR" | cut -f1)"
        
    } > "$summary_file"
    
    echo "Global summary written to: $summary_file"
}

# Main execution
main() {
    if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        echo "Usage: $0 [experiment-id] [--verbose] [--list] [--summary]"
        echo ""
        echo "Options:"
        echo "  --list      List all available experiments"
        echo "  --summary   Generate global validation summary"
        echo "  --verbose   Show detailed validation output"
        echo ""
        echo "Examples:"
        echo "  $0                           # Validate all experiments"
        echo "  $0 --list                    # List all experiments"
        echo "  $0 exp_20241201_143022       # Validate specific experiment"
        echo "  $0 exp_20241201_143022 --verbose  # Detailed output"
        echo "  $0 --summary                 # Generate global summary"
        exit 0
    fi
    
    if [[ "$1" == "--list" ]]; then
        list_experiments
        exit $?
    fi
    
    if [[ "$1" == "--summary" ]]; then
        generate_global_summary
        exit $?
    fi
    
    if [[ ! -d "$DATA_DIR" ]]; then
        log "Data directory not found: $DATA_DIR" "ERROR"
        exit 1
    fi
    
    local total_errors=0
    
    if [[ -n "$EXPERIMENT_ID" && "$EXPERIMENT_ID" != "--verbose" ]]; then
        # Validate specific experiment
        validate_experiment "$EXPERIMENT_ID"
        total_errors=$?
    else
        # Validate all experiments
        local found_any=false
        for exp_dir in "$DATA_DIR"/exp_*; do
            if [[ -d "$exp_dir" ]]; then
                found_any=true
                local exp_id=$(basename "$exp_dir")
                validate_experiment "$exp_id"
                total_errors=$((total_errors + $?))
                echo ""
            fi
        done
        
        if [[ "$found_any" == "false" ]]; then
            log "No experiments found in $DATA_DIR" "ERROR"
            exit 1
        fi
    fi
    
    if [[ $total_errors -eq 0 ]]; then
        log "All experiments validated successfully" "INFO"
        exit 0
    else
        log "Validation completed with $total_errors errors across all experiments" "ERROR"
        exit 1
    fi
}

main "$@"