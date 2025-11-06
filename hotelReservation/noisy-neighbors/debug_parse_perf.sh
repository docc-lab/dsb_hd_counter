#!/bin/bash
# Debug script to test perf log parsing

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <perf_log_file.txt>"
    echo "Example: $0 experiment_data/exp_xxx/raw/perf/logs/search_perf_iter1.txt"
    exit 1
fi

perf_log_file="$1"

if [[ ! -f "$perf_log_file" ]]; then
    echo "Error: File not found: $perf_log_file"
    exit 1
fi

echo "Parsing: $perf_log_file"
echo "Lines in file: $(wc -l < "$perf_log_file")"
echo ""

# Test parsing
echo "["
first=true
while IFS= read -r line; do
    # Check if line contains perf_data_type field
    if [[ "$line" =~ perf_data_type ]]; then
        echo "DEBUG: Found line with perf_data_type" >&2
        
        # Extract fields using pure bash regex
        local svc="unknown"
        local meth="unknown"
        local proc_time="0"
        local total_time="0"
        local block_time="0"
        local perf_total_str=""
        local perf_exec_str="{}"
        
        # Extract service
        if [[ "$line" =~ service=([^[:space:]]+) ]]; then
            svc="${BASH_REMATCH[1]}"
            echo "DEBUG: Extracted service=$svc" >&2
        fi
        
        # Extract method
        if [[ "$line" =~ method=([^[:space:]]+) ]]; then
            meth="${BASH_REMATCH[1]}"
            echo "DEBUG: Extracted method=$meth" >&2
        fi
        
        # Extract timing values
        if [[ "$line" =~ processing_time_ms=([0-9.]+) ]]; then
            proc_time="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ total_time_ms=([0-9.]+) ]]; then
            total_time="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ blocking_time_ms=([0-9.]+) ]]; then
            block_time="${BASH_REMATCH[1]}"
        fi
        
        # Extract perf_total
        if [[ "$line" =~ perf_total=(\{[^}]*\}) ]]; then
            perf_total_str="${BASH_REMATCH[1]}"
            echo "DEBUG: Extracted perf_total=$perf_total_str" >&2
        else
            echo "DEBUG: perf_total NOT matched" >&2
        fi
        
        # Extract perf_execution
        if [[ "$line" =~ perf_execution=(\{[^}]*\}) ]]; then
            perf_exec_str="${BASH_REMATCH[1]}"
            echo "DEBUG: Extracted perf_execution=$perf_exec_str" >&2
        fi
        
        # Only output if we have perf data
        if [[ -n "$perf_total_str" ]]; then
            if [[ "$first" == "false" ]]; then
                echo ","
            fi
            first=false
            
            echo "  {"
            echo "    \"service\": \"${svc}\","
            echo "    \"method\": \"${meth}\","
            echo "    \"processing_time_ms\": ${proc_time},"
            echo "    \"total_time_ms\": ${total_time},"
            echo "    \"blocking_time_ms\": ${block_time},"
            echo "    \"perf_total\": ${perf_total_str},"
            echo "    \"perf_execution\": ${perf_exec_str}"
            echo -n "  }"
        else
            echo "DEBUG: Skipping line - no perf_total_str" >&2
        fi
    fi
done < "$perf_log_file"
echo ""
echo "]"

echo "" >&2
echo "Parsing complete" >&2

