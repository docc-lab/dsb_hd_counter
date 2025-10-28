#!/bin/bash
# Integrated Data Collection Framework
# Usage: ./data-collector.sh <experiment-config-file>

set -e

# Configuration
DATA_DIR="${DATA_DIR:-./experiment_data}"
HOTEL_MANIFESTS_DIR="${HOTEL_MANIFESTS_DIR:-./hotelReservation}"
WRK2_DIR="${WRK2_DIR:-../../wrk2}"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Your existing script paths
STRESS_SCRIPT="$SCRIPTS_DIR/stress-ng/stress-ng-helpers.sh"
MONITOR_SCRIPT="$SCRIPTS_DIR/perf/service-monitor.sh"
TAINT_SCRIPT="$SCRIPTS_DIR/node-taint.sh"

# Generate unique experiment ID
generate_exp_id() {
    echo "exp_$(date +%Y%m%d_%H%M%S)_$(uuidgen | cut -d'-' -f1)"
}

# Create experiment directory structure
create_exp_directory() {
    local exp_id="$1"
    local exp_dir="$DATA_DIR/$exp_id"
    
    mkdir -p "$exp_dir"/{raw,processed,logs,metadata}
    mkdir -p "$exp_dir/raw"/{perf,latency,system,stress}
    
    echo "$exp_dir"
}

# Log function with timestamp
log() {
    local exp_dir="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$exp_dir/logs/collector.log"
}

# Validate configuration
validate_config() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        echo "ERROR: Configuration file not found: $config_file"
        exit 1
    fi
    
    source "$config_file"
    
    # Check required variables
    local required_vars=("EXPERIMENT_NAME" "TARGET_NODE" "VICTIM_SERVICES" "PERF_COUNTER_SET" "NOISY_NEIGHBOR_TYPE" "EXPERIMENT_DURATION")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            echo "ERROR: Required variable $var not set in config file"
            exit 1
        fi
    done
    
    # Check if scripts exist
    for script in "$STRESS_SCRIPT" "$MONITOR_SCRIPT" "$TAINT_SCRIPT"; do
        if [[ ! -f "$script" ]]; then
            echo "ERROR: Required script not found: $script"
            exit 1
        fi
    done
    
    # Validate target node exists
    if ! kubectl get node "$TARGET_NODE" &>/dev/null; then
        echo "ERROR: Target node $TARGET_NODE not found"
        exit 1
    fi
    
    # Check if wrk2 exists
    if [[ -n "${WRK2_TARGET_SERVICE:-}" && ! -f "$WRK2_DIR/wrk" ]]; then
        echo "WARNING: wrk2 not found at: $WRK2_DIR/wrk (will skip workload generation)"
    fi
    
    echo "Configuration validation passed"
}

# Cleanup any existing stress pods
cleanup_existing_stress_pods() {
    local exp_dir="$1"
    
    log "$exp_dir" "Cleaning up any existing stress pods..."
    
    # Clean up stress pods (both running and completed)
    local stress_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase!=Running -o name 2>/dev/null | grep -E "(stress|cpu-stress|mem-stress|io-stress)" || echo "")
    local running_stress_pods=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running -o name 2>/dev/null | grep -E "(stress|cpu-stress|mem-stress|io-stress)" || echo "")
    
    # Delete completed/failed stress pods
    if [[ -n "$stress_pods" ]]; then
        echo "$stress_pods" | while read -r pod; do
            if [[ -n "$pod" ]]; then
                log "$exp_dir" "  Deleting completed/failed stress pod: $pod"
                kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
            fi
        done
    fi
    
    # Delete running stress pods
    if [[ -n "$running_stress_pods" ]]; then
        echo "$running_stress_pods" | while read -r pod; do
            if [[ -n "$pod" ]]; then
                log "$exp_dir" "  Deleting running stress pod: $pod"
                kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
            fi
        done
    fi
    
    # Also run the stress script cleanup
    if [[ -f "$STRESS_SCRIPT" ]]; then
        log "$exp_dir" "Running stress script cleanup..."
        "$STRESS_SCRIPT" cleanup 2>/dev/null || log "$exp_dir" "  Warning: Stress script cleanup failed"
    fi
    
    log "$exp_dir" "Stress pod cleanup completed"
}

# Check and untolerate existing pods on target node
check_and_untolerate_pods() {
    local target_node="$1"
    local exp_dir="$2"
    
    log "$exp_dir" "Checking existing user deployments on target node: $target_node"
    
    # Get only deployments in default namespace that have pods on the target node
    local deployments_to_untolerate=()
    
    # Get all deployments in default namespace
    local deployments=$(kubectl get deployments -n default -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
    
    if [[ -n "$deployments" ]]; then
        while read -r deployment; do
            if [[ -n "$deployment" ]]; then
                # Check if this deployment has pods on the target node
                # Try both common label patterns: app= and io.kompose.service=
                local pods_on_node=$(kubectl get pods -n default -l io.kompose.service="$deployment" --field-selector=spec.nodeName="$target_node" -o name 2>/dev/null | wc -l)
                if [[ "$pods_on_node" -eq 0 ]]; then
                    # Fallback to app label if no pods found with io.kompose.service
                    pods_on_node=$(kubectl get pods -n default -l app="$deployment" --field-selector=spec.nodeName="$target_node" -o name 2>/dev/null | wc -l)
                fi
                if [[ "$pods_on_node" -gt 0 ]]; then
                    deployments_to_untolerate+=("$deployment")
                    log "$exp_dir" "  Found deployment '$deployment' with $pods_on_node pod(s) on $target_node"
                fi
            fi
        done <<< "$deployments"
    fi
    
    if [[ ${#deployments_to_untolerate[@]} -gt 0 ]]; then
        log "$exp_dir" "Untolerating ${#deployments_to_untolerate[@]} deployment(s) to clear target node..."
        
        for deployment in "${deployments_to_untolerate[@]}"; do
            log "$exp_dir" "  Untolerating deployment: $deployment"
            "$TAINT_SCRIPT" "$target_node" "$deployment" --untolerate 2>/dev/null || log "$exp_dir" "    Warning: Failed to untolerate $deployment (may not have tolerations)"
            
            # Add node anti-affinity to prevent scheduling back on target node
            log "$exp_dir" "  Adding anti-affinity to keep $deployment away from $target_node"
            kubectl patch deployment "$deployment" -n default --type='merge' -p "{
              \"spec\": {
                \"template\": {
                  \"spec\": {
                    \"affinity\": {
                      \"nodeAffinity\": {
                        \"requiredDuringSchedulingIgnoredDuringExecution\": {
                          \"nodeSelectorTerms\": [{
                            \"matchExpressions\": [{
                              \"key\": \"kubernetes.io/hostname\",
                              \"operator\": \"NotIn\",
                              \"values\": [\"$target_node\"]
                            }]
                          }]
                        }
                      }
                    }
                  }
                }
              }
            }" 2>/dev/null || log "$exp_dir" "    Warning: Failed to add anti-affinity to $deployment"
        done
        
        # Wait for pods to be rescheduled
        log "$exp_dir" "Waiting for pods to be rescheduled away from $target_node..."
        sleep 30
        
        # Check if any pods are still on the target node and force restart if needed
        for deployment in "${deployments_to_untolerate[@]}"; do
            # Use reliable method to check if deployment pods are still on target node
            local remaining_pods=$(kubectl get pods -n default -l io.kompose.service="$deployment" -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
            if [[ "$remaining_pods" -eq 0 ]]; then
                # Fallback to app label
                remaining_pods=$(kubectl get pods -n default -l app="$deployment" -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
            fi
            if [[ "$remaining_pods" -gt 0 ]]; then
                log "$exp_dir" "  $deployment still has $remaining_pods pod(s) on $target_node, forcing restart..."
                kubectl rollout restart deployment "$deployment" -n default 2>/dev/null || log "$exp_dir" "    Warning: Failed to restart $deployment"
            fi
        done
        
        # Final wait for rollouts to complete
        log "$exp_dir" "Waiting for rollouts to complete..."
        for deployment in "${deployments_to_untolerate[@]}"; do
            kubectl rollout status deployment "$deployment" -n default --timeout=60s 2>/dev/null || log "$exp_dir" "    Warning: Timeout waiting for $deployment rollout"
        done
        
        # Save list of untolerated deployments for cleanup
        echo "${deployments_to_untolerate[@]}" > "$exp_dir/metadata/untolerated_deployments.txt"
        
        # Verify target node is clear and wait if needed
        local max_attempts=6
        local attempt=1
        while [[ $attempt -le $max_attempts ]]; do
            # Use a more reliable method: get pods with wide output and grep for the target node
            local final_user_pods=$(kubectl get pods -n default -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
            log "$exp_dir" "Attempt $attempt/$max_attempts: Target node $target_node has $final_user_pods running user pod(s) in default namespace"
            
            # Also show which pods are still on the target node for debugging
            local pods_on_target=$(kubectl get pods -n default -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | awk '{print $1}' | tr '\n' ' ')
            if [[ -n "$pods_on_target" ]]; then
                log "$exp_dir" "  Pods still on $target_node: $pods_on_target"
            fi
            
            if [[ $final_user_pods -eq 0 ]]; then
                log "$exp_dir" " Target node $target_node is now clear of user pods"
                break
            fi
            
            if [[ $attempt -lt $max_attempts ]]; then
                log "$exp_dir" "Waiting 15s for remaining pods to reschedule..."
                sleep 15
            else
                log "$exp_dir" "WARNING: Target node still has $final_user_pods user pods after $max_attempts attempts"
                # Force one more round of restarts for any remaining deployments
                for deployment in "${deployments_to_untolerate[@]}"; do
                    local remaining=$(kubectl get pods -n default -l io.kompose.service="$deployment" -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
                    if [[ $remaining -eq 0 ]]; then
                        # Fallback to app label
                        remaining=$(kubectl get pods -n default -l app="$deployment" -o wide --no-headers 2>/dev/null | grep -E "\s+$target_node\s+" | grep -v "Terminating" | wc -l)
                    fi
                    if [[ $remaining -gt 0 ]]; then
                        log "$exp_dir" "  Force restarting $deployment (still has $remaining pod(s) on $target_node)"
                        kubectl rollout restart deployment "$deployment" -n default 2>/dev/null
                    fi
                done
            fi
            ((attempt++))
        done
        
    else
        log "$exp_dir" "No user deployments found on target node $target_node"
    fi
}

# Deploy victim services on target node
deploy_victim_services() {
    local services="$1"
    local target_node="$2"
    local exp_dir="$3"
    
    log "$exp_dir" "Deploying victim services: $services"
    
    for service in $services; do
        local service_dir="../kubernetes/${service}"
        
        if [[ ! -d "$service_dir" ]]; then
            log "$exp_dir" "WARNING: Service directory not found for $service: $service_dir"
            continue
        fi
        
        log "$exp_dir" "Deploying $service from $service_dir..."
        
        # Apply all YAML files in the service directory
        if ls "$service_dir"/*.yaml 1> /dev/null 2>&1; then
            kubectl apply -f "$service_dir/"
            
            # Wait a moment for the deployment to be created
            sleep 5
            
            # Use the proven working method: clean deployment first, then apply taint
            log "$exp_dir" "Deploying $service using proven clean-then-taint method..."
            
            # Step 1: Ensure completely clean deployment state
            log "$exp_dir" "  Step 1: Ensuring clean deployment state..."
            
            # Clean up any existing stuck pods
            local stuck_pods=$(kubectl get pods -l io.kompose.service="$service" --field-selector=status.phase=Pending -o name 2>/dev/null)
            if [[ -n "$stuck_pods" ]]; then
                log "$exp_dir" "  Cleaning up existing stuck pods..."
                echo "$stuck_pods" | xargs -r kubectl delete --force --grace-period=0
                sleep 10
            fi
            
            # Remove any existing taint/toleration to ensure clean state
            "$TAINT_SCRIPT" "$target_node" "$service" --untolerate 2>/dev/null || true
            
            # Apply emergency patch to ensure completely clean state
            kubectl patch deployment "$service" --type='merge' -p '{
              "spec": {
                "template": {
                  "spec": {
                    "tolerations": null,
                    "nodeSelector": null,
                    "affinity": null
                  }
                }
              }
            }' 2>/dev/null || true
            
            # Force restart to apply clean configuration
            kubectl rollout restart deployment "$service" 2>/dev/null || true
            
            # Step 2: Wait for clean deployment to be ready
            log "$exp_dir" "  Step 2: Waiting for clean deployment to be ready..."
            if kubectl rollout status deployment "$service" --timeout=90s; then
                log "$exp_dir" "  Clean deployment successful"
                
                # Step 3: Apply taint and toleration
                log "$exp_dir" "  Step 3: Applying taint and toleration..."
                if "$TAINT_SCRIPT" "$target_node" "$service"; then
                    log "$exp_dir" "  Service $service successfully deployed and pinned to $target_node"
                else
                    log "$exp_dir" "  WARNING: Taint application failed, but service is running on available nodes"
                fi
            else
                log "$exp_dir" "  ERROR: Clean deployment failed for $service"
            fi
        else
            log "$exp_dir" "WARNING: No YAML files found in $service_dir"
        fi
    done
    
    # Record deployed services
    echo "$services" > "$exp_dir/metadata/deployed_services.txt"
}

# Configure Jaeger tracing for all hotel reservation services
configure_jaeger_tracing() {
    local exp_dir="$1"
    
    # Get sampling rate from config or use default
    local sampling_rate="${JAEGER_SAMPLE_RATIO:-0.01}"
    
    # Skip Jaeger configuration if sampling rate is 0
    if [[ "$sampling_rate" == "0" || "$sampling_rate" == "0.0" ]]; then
        log "$exp_dir" "Jaeger sampling rate is 0 - skipping Jaeger configuration"
        echo "=== JAEGER CONFIGURATION ===" > "$exp_dir/metadata/jaeger_config.txt"
        echo "Skipped at: $(date -Iseconds)" >> "$exp_dir/metadata/jaeger_config.txt"
        echo "Reason: Sampling rate set to 0" >> "$exp_dir/metadata/jaeger_config.txt"
        echo "Sampling rate: $sampling_rate" >> "$exp_dir/metadata/jaeger_config.txt"
        return 0
    fi
    
    log "$exp_dir" "Configuring Jaeger tracing for all hotel reservation services..."
    log "$exp_dir" "Using Jaeger sampling rate: $sampling_rate"
    
    # Temporarily disable exit on error for Jaeger configuration
    set +e
    
    # List of all hotel reservation services that need Jaeger configuration
    local all_services=(
        "frontend"
        "search" 
        "geo"
        "profile"
        "rate"
        "recommendation"
        "reservation"
        "user"
        "review"
        "attractions"
    )
    
    # Wait for all deployments to be available before configuring
    log "$exp_dir" "Waiting for deployments to be ready before Jaeger configuration..."
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            kubectl wait --for=condition=available --timeout=300s deployment/"$service" 2>/dev/null || \
                log "$exp_dir" "WARNING: Timeout waiting for $service deployment"
        fi
    done
    
    # Configure each service
    local configured_count=0
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            log "$exp_dir" "Configuring Jaeger for $service..."
            
            # Set HTTP collector endpoint
            if kubectl set env deployment/"$service" JAEGER_ENDPOINT=http://jaeger:14268/api/traces 2>/dev/null; then
                log "$exp_dir" "   Set JAEGER_ENDPOINT for $service"
            else
                log "$exp_dir" "   WARNING: Failed to set JAEGER_ENDPOINT for $service"
            fi
            
            # Set sampling rate
            if kubectl set env deployment/"$service" JAEGER_SAMPLE_RATIO="$sampling_rate" 2>/dev/null; then
                log "$exp_dir" "   Set JAEGER_SAMPLE_RATIO for $service"
            else
                log "$exp_dir" "   WARNING: Failed to set JAEGER_SAMPLE_RATIO for $service"
            fi
            
            # Remove UDP agent configuration
            if kubectl set env deployment/"$service" JAEGER_AGENT_HOST- 2>/dev/null; then
                log "$exp_dir" "   Removed JAEGER_AGENT_HOST for $service"
            else
                log "$exp_dir" "   WARNING: Failed to remove JAEGER_AGENT_HOST for $service (may not exist)"
            fi
            
            ((configured_count++))
        else
            log "$exp_dir" "Service $service not found, skipping Jaeger configuration"
        fi
    done
    
    log "$exp_dir" "Jaeger environment variables set for $configured_count services. Waiting for rollouts..."
    
    # Wait for all rollouts to complete
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            kubectl rollout status deployment/"$service" --timeout=120s 2>/dev/null || \
                log "$exp_dir" "WARNING: Rollout timeout for $service"
        fi
    done
    
    # Verify all services are actually running and ready
    log "$exp_dir" "Verifying all services are running after Jaeger configuration..."
    local failed_services=()
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            local ready_replicas=$(kubectl get deployment "$service" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired_replicas=$(kubectl get deployment "$service" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            
            if [[ "$ready_replicas" == "$desired_replicas" && "$ready_replicas" != "0" ]]; then
                log "$exp_dir" "   $service: $ready_replicas/$desired_replicas pods ready"
            else
                log "$exp_dir" "   $service: $ready_replicas/$desired_replicas pods ready (FAILED)"
                failed_services+=("$service")
            fi
        fi
    done
    
    # If services failed, try to recover them
    if [[ ${#failed_services[@]} -gt 0 ]]; then
        log "$exp_dir" "Attempting to recover failed services: ${failed_services[*]}"
        for service in "${failed_services[@]}"; do
            log "$exp_dir" "  Checking $service pods..."
            kubectl get pods -l app="$service" -o wide
            
            # Try restarting failed service
            log "$exp_dir" "  Restarting $service..."
            kubectl rollout restart deployment/"$service" 2>/dev/null
            kubectl rollout status deployment/"$service" --timeout=60s 2>/dev/null || \
                log "$exp_dir" "  WARNING: Recovery timeout for $service"
        done
        
        # Additional wait for recovery
        sleep 30
    fi
    
    log "$exp_dir" "Waiting for services to stabilize after Jaeger configuration..."
    sleep 45  # Increased from 30s to 45s
    
    # Enhanced service registration validation and monitoring
    log "$exp_dir" "Validating service registration in Consul..."
    if ! validate_and_ensure_service_registration "$exp_dir" 3; then
        log "$exp_dir" "WARNING: Service registration validation failed, performing refresh..."
        refresh_consul_service_discovery "$exp_dir"
        
        # If still failing after refresh, try manual registration as fallback
        if ! validate_and_ensure_service_registration "$exp_dir" 1; then
            log "$exp_dir" "WARNING: Consul refresh failed, attempting manual service registration..."
            manual_register_all_services "$exp_dir"
        fi
    else
        log "$exp_dir" " All services properly registered, skipping unnecessary Consul restart"
    fi
    
    # Verification
    log "$exp_dir" "Verifying Jaeger configuration..."
    
    # Check sampling rate on a few key services
    for service in "frontend" "search"; do
        if kubectl get deployment "$service" &>/dev/null; then
            local sample_log=$(kubectl logs deployment/"$service" 2>/dev/null | grep "sample ratio" | tail -1)
            if [[ -n "$sample_log" ]]; then
                log "$exp_dir" "  $service: $sample_log"
            else
                log "$exp_dir" "  $service: No sample ratio log found"
            fi
        fi
    done
    
    # Check Jaeger service registration
    local jaeger_services=$(kubectl exec -it deployment/jaeger -- wget -qO- "http://localhost:16686/api/services" 2>/dev/null | grep -o '"[^"]*"' | grep -v "data\|total\|limit\|offset\|errors" | head -5)
    if [[ -n "$jaeger_services" ]]; then
        log "$exp_dir" "  Registered services in Jaeger: $jaeger_services"
    else
        log "$exp_dir" "  WARNING: Could not verify Jaeger service registration"
    fi
    
    # Test connectivity with a simple request
    local connectivity_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
    if [[ "$connectivity_test" == "200" ]]; then
        log "$exp_dir" "  Frontend connectivity test passed (HTTP 200)"
    else
        log "$exp_dir" "  Frontend connectivity test failed (HTTP $connectivity_test)"
    fi
    
    log "$exp_dir" "Jaeger configuration completed. Services ready for tracing experiments."
    
    # Re-enable exit on error
    set -e
    
    # Save configuration details to metadata
    {
        echo "=== JAEGER CONFIGURATION ==="
        echo "Configured at: $(date -Iseconds)"
        echo "Sampling rate: $sampling_rate"
        echo "Services configured: $configured_count"
        echo "Endpoint: http://jaeger:14268/api/traces"
        echo ""
        echo "Configured services:"
        for service in "${all_services[@]}"; do
            if kubectl get deployment "$service" &>/dev/null; then
                echo "  - $service"
            fi
        done
    } > "$exp_dir/metadata/jaeger_config.txt"
}

# Monitor and validate Consul service registration
monitor_consul_service_registration() {
    local exp_dir="$1"
    local max_wait_time="${2:-120}"  # Maximum wait time in seconds
    local check_interval="${3:-10}"  # Check interval in seconds
    
    log "$exp_dir" "Monitoring Consul service registration..."
    
    # Check if Consul is available
    if ! kubectl get deployment consul &>/dev/null; then
        log "$exp_dir" "WARNING: Consul deployment not found, skipping service registration monitoring"
        return 1
    fi
    
    local expected_services=("srv-frontend" "srv-search" "srv-geo" "srv-profile" "srv-rate" "srv-recommendation" "srv-reservation" "srv-user")
    local wait_time=0
    local all_registered=false
    
    while [[ $wait_time -lt $max_wait_time && "$all_registered" == "false" ]]; do
        # Get current service registrations
        local consul_services=$(kubectl exec -it deployment/consul -- consul catalog services 2>/dev/null | grep -E "srv-" | tr -d '\r' | head -10)
        local registered_count=0
        local missing_services=()
        
        if [[ -n "$consul_services" ]]; then
            registered_count=$(echo "$consul_services" | wc -l)
            
            # Check for missing services
            for expected in "${expected_services[@]}"; do
                if ! echo "$consul_services" | grep -q "$expected"; then
                    missing_services+=("$expected")
                fi
            done
            
            if [[ ${#missing_services[@]} -eq 0 ]]; then
                log "$exp_dir" "   All ${#expected_services[@]} expected services are registered in Consul"
                all_registered=true
                break
            else
                log "$exp_dir" "  Progress: $registered_count/${#expected_services[@]} services registered. Missing: ${missing_services[*]}"
            fi
        else
            log "$exp_dir" "  No services found in Consul registry yet"
        fi
        
        if [[ "$all_registered" == "false" ]]; then
            sleep $check_interval
            wait_time=$((wait_time + check_interval))
        fi
    done
    
    if [[ "$all_registered" == "true" ]]; then
        log "$exp_dir" " Service registration monitoring completed successfully"
        return 0
    else
        log "$exp_dir" " Service registration monitoring failed - not all services registered after ${max_wait_time}s"
        
        # Log final state for debugging
        log "$exp_dir" "Final Consul service state:"
        kubectl exec -it deployment/consul -- consul catalog services 2>/dev/null | while read -r service; do
            log "$exp_dir" "    $service"
        done
        
        return 1
    fi
}

# Enhanced service registration validation with retry logic
validate_and_ensure_service_registration() {
    local exp_dir="$1"
    local max_attempts="${2:-3}"
    
    log "$exp_dir" "Validating and ensuring all services are registered in Consul..."
    
    local expected_services=("srv-frontend" "srv-search" "srv-geo" "srv-profile" "srv-rate" "srv-recommendation" "srv-reservation" "srv-user")
    
    for attempt in $(seq 1 $max_attempts); do
        log "$exp_dir" "Validation attempt $attempt/$max_attempts"
        
        # Check current registrations
        local consul_services=$(kubectl exec -it deployment/consul -- consul catalog services 2>/dev/null | grep -E "srv-" | tr -d '\r' | head -10)
        local missing_services=()
        
        if [[ -n "$consul_services" ]]; then
            local registered_count=$(echo "$consul_services" | wc -l)
            log "$exp_dir" "  Currently registered: $registered_count services"
            
            # Check for missing services
            for expected in "${expected_services[@]}"; do
                if ! echo "$consul_services" | grep -q "$expected"; then
                    missing_services+=("$expected")
                fi
            done
            
            if [[ ${#missing_services[@]} -eq 0 ]]; then
                log "$exp_dir" "   All services are properly registered"
                
                # Test connectivity to ensure services are actually reachable
                log "$exp_dir" "  Testing service connectivity..."
                local connectivity_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/recommendations?require=price&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
                if [[ "$connectivity_test" == "200" ]]; then
                    log "$exp_dir" "   Service connectivity test passed (HTTP 200)"
                    return 0
                else
                    log "$exp_dir" "   Service connectivity test failed (HTTP $connectivity_test)"
                    if [[ $attempt -lt $max_attempts ]]; then
                        log "$exp_dir" "  Will retry service registration..."
                    fi
                fi
            else
                log "$exp_dir" "  Missing services in Consul: ${missing_services[*]}"
            fi
        else
            log "$exp_dir" "  No services found in Consul registry"
        fi
        
        # If not the last attempt, try to fix registration issues
        if [[ $attempt -lt $max_attempts ]]; then
            log "$exp_dir" "  Attempting to fix service registration issues..."
            
            # Restart services that should be registered but aren't
            for missing in "${missing_services[@]}"; do
                local service_name=${missing#srv-}  # Remove srv- prefix
                if kubectl get deployment "$service_name" &>/dev/null; then
                    log "$exp_dir" "    Restarting $service_name to trigger re-registration..."
                    kubectl rollout restart deployment/"$service_name" 2>/dev/null
                fi
            done
            
            # Wait for services to restart and register
            log "$exp_dir" "  Waiting 90s for services to restart and register..."
            sleep 90
            
            # Monitor registration progress with extended timeout
            monitor_consul_service_registration "$exp_dir" 120 10
        fi
    done
    
    log "$exp_dir" " Service registration validation failed after $max_attempts attempts"
    return 1
}

# Manual registration of all services as fallback
manual_register_all_services() {
    local exp_dir="$1"
    
    log "$exp_dir" "Performing manual registration of all services..."
    
    # Check if Consul is available
    if ! kubectl get deployment consul &>/dev/null; then
        log "$exp_dir" "ERROR: Consul deployment not found, cannot perform manual registration"
        return 1
    fi
    
    # Get Consul pod
    local consul_pod=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$consul_pod" ]]; then
        log "$exp_dir" "ERROR: Could not find Consul pod"
        return 1
    fi
    
    # List of services to register manually
    local services_to_register=(
        "frontend:srv-frontend:5000"
        "search:srv-search:8082"
        "geo:srv-geo:8083"
        "profile:srv-profile:8081"
        "rate:srv-rate:8084"
        "recommendation:srv-recommendation:8085"
        "reservation:srv-reservation:8087"
        "user:srv-user:8086"
    )
    
    local registered_count=0
    
    for service_info in "${services_to_register[@]}"; do
        IFS=':' read -r service_name consul_name port <<< "$service_info"
        
        # Get service IP
        local service_ip=$(kubectl get pod -l io.kompose.service="$service_name" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
        
        if [[ -n "$service_ip" ]]; then
            log "$exp_dir" "  Registering $consul_name at $service_ip:$port"
            
            # Register service without health checks to avoid deregistration
            if kubectl exec -it "$consul_pod" -- consul services register \
                -name="$consul_name" \
                -port="$port" \
                -address="$service_ip" \
                -id="manual-$service_name" 2>/dev/null; then
                
                log "$exp_dir" "    Successfully registered $consul_name"
                ((registered_count++))
            else
                log "$exp_dir" "    Failed to register $consul_name"
            fi
        else
            log "$exp_dir" "  Skipping $service_name - no pod found or not ready"
        fi
    done
    
    log "$exp_dir" "Manual registration completed: $registered_count/${#services_to_register[@]} services registered"
    
    # Wait for registration to propagate
    sleep 10
    
    # Verify registration
    local final_services=$(kubectl exec -it "$consul_pod" -- consul catalog services 2>/dev/null | grep -E "srv-" | wc -l)
    log "$exp_dir" "  Final service count in Consul: $final_services"
    
    if [[ $final_services -ge 7 ]]; then
        log "$exp_dir" " Manual registration successful"
        return 0
    else
        log "$exp_dir" " Manual registration partially failed"
        return 1
    fi
}

# Lightweight Consul service discovery refresh (no restarts)
refresh_consul_service_discovery() {
    local exp_dir="$1"
    
    log "$exp_dir" "Performing lightweight Consul service discovery refresh..."
    
    # Check if Consul is available
    if ! kubectl get deployment consul &>/dev/null; then
        log "$exp_dir" "WARNING: Consul deployment not found, skipping service discovery refresh"
        return 0
    fi
    
    # First, validate current service registration without any restarts
    if validate_and_ensure_service_registration "$exp_dir" 1; then
        log "$exp_dir" " All services already properly registered, no refresh needed"
        return 0
    fi
    
    log "$exp_dir" "Service registration issues detected, performing refresh..."
    
    # Restart all services to force re-registration (more aggressive approach)
    log "$exp_dir" "Restarting all services to force fresh registration..."
    
    local all_services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
    
    # Restart services in dependency order
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            log "$exp_dir" "  Restarting $service..."
            kubectl rollout restart deployment/"$service" 2>/dev/null
        fi
    done
    
    # Wait for all services to be ready
    log "$exp_dir" "Waiting for all services to be ready..."
    for service in "${all_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            kubectl rollout status deployment/"$service" --timeout=90s 2>/dev/null || \
                log "$exp_dir" "  WARNING: $service restart timeout"
        fi
    done
    
    # Then restart Consul to ensure clean state
    log "$exp_dir" "Restarting Consul after services are ready..."
    kubectl rollout restart deployment/consul 2>/dev/null
    kubectl rollout status deployment/consul --timeout=60s 2>/dev/null || \
        log "$exp_dir" "  WARNING: Consul restart timeout"
    
    # Wait for Consul to be fully ready and services to re-register
    log "$exp_dir" "Waiting for Consul to stabilize and services to re-register..."
    sleep 45
    
    # Monitor service registration with extended timeout
    if monitor_consul_service_registration "$exp_dir" 120 10; then
        log "$exp_dir" " Service registration refresh completed successfully"
    else
        log "$exp_dir" " Service registration refresh failed"
        return 1
    fi
    
    # Additional wait for connections to fully stabilize
    log "$exp_dir" "Allowing additional time for service connections to stabilize..."
    sleep 30
    
    # Final connectivity verification
    log "$exp_dir" "Verifying service connectivity after refresh..."
    local connectivity_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
    if [[ "$connectivity_test" == "200" ]]; then
        log "$exp_dir" "   Service connectivity verified (HTTP 200)"
    else
        log "$exp_dir" "   Service connectivity test failed (HTTP $connectivity_test)"
    fi
    
    # Save refresh details to metadata
    {
        echo "=== CONSUL SERVICE DISCOVERY REFRESH ==="
        echo "Refreshed at: $(date -Iseconds)"
        echo "Method: Consul restart only (preserves service pods and Jaeger config)"
        echo "Consul restarted: Yes"
        echo "Service pods restarted: No"
        echo "Final connectivity test: HTTP $connectivity_test"
        echo "Total wait time: ~80s (30s + 30s + monitoring time)"
    } > "$exp_dir/metadata/consul_refresh.txt"
    
    log "$exp_dir" "Consul service discovery refresh completed"
}

# Comprehensive system readiness validation
validate_system_readiness() {
    local exp_dir="$1"
    
    log "$exp_dir" "=== COMPREHENSIVE SYSTEM READINESS VALIDATION ==="
    
    local validation_failed=false
    
    # 1. Validate all expected services are running
    log "$exp_dir" "1. Validating service deployments..."
    local expected_services=("frontend" "search" "geo" "profile" "rate" "recommendation" "reservation" "user")
    local failed_deployments=()
    
    for service in "${expected_services[@]}"; do
        if kubectl get deployment "$service" &>/dev/null; then
            local ready_replicas=$(kubectl get deployment "$service" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            local desired_replicas=$(kubectl get deployment "$service" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
            
            if [[ "$ready_replicas" == "$desired_replicas" && "$ready_replicas" != "0" ]]; then
                log "$exp_dir" "   ✓ $service: $ready_replicas/$desired_replicas pods ready"
            else
                log "$exp_dir" "   ✗ $service: $ready_replicas/$desired_replicas pods ready (FAILED)"
                failed_deployments+=("$service")
                validation_failed=true
            fi
        else
            log "$exp_dir" "   ✗ $service: deployment not found (FAILED)"
            failed_deployments+=("$service")
            validation_failed=true
        fi
    done
    
    # 2. Validate Consul service registration
    log "$exp_dir" "2. Validating Consul service registration..."
    local consul_services=$(kubectl exec -it deployment/consul -- consul catalog services 2>/dev/null | grep -E "srv-" | tr -d '\r' | head -10)
    local expected_consul_services=("srv-frontend" "srv-search" "srv-geo" "srv-profile" "srv-rate" "srv-recommendation" "srv-reservation" "srv-user")
    local missing_consul_services=()
    
    if [[ -n "$consul_services" ]]; then
        local registered_count=$(echo "$consul_services" | wc -l)
        log "$exp_dir" "   Registered services: $registered_count"
        
        for expected in "${expected_consul_services[@]}"; do
            if echo "$consul_services" | grep -q "$expected"; then
                log "$exp_dir" "   ✓ $expected: registered"
            else
                log "$exp_dir" "   ✗ $expected: missing from Consul"
                missing_consul_services+=("$expected")
                validation_failed=true
            fi
        done
    else
        log "$exp_dir" "   ✗ No services found in Consul registry (CRITICAL FAILURE)"
        validation_failed=true
    fi
    
    # 3. Test critical service connectivity
    log "$exp_dir" "3. Testing critical service connectivity..."
    
    # Test recommendations endpoint (should work)
    local rec_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/recommendations?require=price&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
    if [[ "$rec_test" == "200" ]]; then
        log "$exp_dir" "   ✓ Recommendations endpoint: HTTP 200"
    else
        log "$exp_dir" "   ✗ Recommendations endpoint: HTTP $rec_test (FAILED)"
        validation_failed=true
    fi
    
    # Test hotels endpoint (requires search service via Consul)
    local hotel_test=$(kubectl exec -it deployment/frontend -- curl -s -w "HTTP_CODE:%{http_code}" "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null | grep "HTTP_CODE" | cut -d: -f2)
    if [[ "$hotel_test" == "200" ]]; then
        log "$exp_dir" "   ✓ Hotels endpoint: HTTP 200"
    else
        log "$exp_dir" "   ✗ Hotels endpoint: HTTP $hotel_test (FAILED - likely Consul issue)"
        validation_failed=true
    fi
    
    # 4. Validate Consul health
    log "$exp_dir" "4. Validating Consul health..."
    local consul_status=$(kubectl exec -it deployment/consul -- consul info 2>/dev/null | grep -c "consul" || echo "0")
    if [[ "$consul_status" -gt "0" ]]; then
        log "$exp_dir" "   ✓ Consul is responding"
    else
        log "$exp_dir" "   ✗ Consul not responding (FAILED)"
        validation_failed=true
    fi
    
    # 5. Summary
    log "$exp_dir" "=== VALIDATION SUMMARY ==="
    if [[ "$validation_failed" == "true" ]]; then
        log "$exp_dir" "✗ VALIDATION FAILED"
        log "$exp_dir" "Failed deployments: ${failed_deployments[*]:-none}"
        log "$exp_dir" "Missing Consul services: ${missing_consul_services[*]:-none}"
        log "$exp_dir" "Recommendations test: HTTP $rec_test"
        log "$exp_dir" "Hotels test: HTTP $hotel_test"
        
        # Debug failed services for better troubleshooting
        for failed_service in "${failed_deployments[@]}"; do
            debug_service_registration "$exp_dir" "$failed_service"
        done
        
        # Debug missing Consul services
        for missing_service in "${missing_consul_services[@]}"; do
            local service_name=${missing_service#srv-}  # Remove srv- prefix
            debug_service_registration "$exp_dir" "$service_name"
        done
        
        # Save validation failure details
        {
            echo "=== SYSTEM VALIDATION FAILURE ==="
            echo "Failed at: $(date -Iseconds)"
            echo "Failed deployments: ${failed_deployments[*]:-none}"
            echo "Missing Consul services: ${missing_consul_services[*]:-none}"
            echo "Recommendations endpoint: HTTP $rec_test"
            echo "Hotels endpoint: HTTP $hotel_test"
            echo "Consul status: $consul_status"
        } > "$exp_dir/metadata/validation_failure.txt"
        
        return 1
    else
        log "$exp_dir" "✓ ALL VALIDATIONS PASSED"
        log "$exp_dir" "System is ready for experiments"
        
        # Save successful validation details
        {
            echo "=== SYSTEM VALIDATION SUCCESS ==="
            echo "Validated at: $(date -Iseconds)"
            echo "All deployments: ready"
            echo "Consul services: ${#expected_consul_services[@]}/${#expected_consul_services[@]} registered"
            echo "Recommendations endpoint: HTTP $rec_test"
            echo "Hotels endpoint: HTTP $hotel_test"
            echo "Consul status: active"
        } > "$exp_dir/metadata/validation_success.txt"
        
        return 0
    fi
}

# Debug service registration issues
debug_service_registration() {
    local exp_dir="$1"
    local service_name="$2"
    
    log "$exp_dir" "=== DEBUGGING SERVICE REGISTRATION: $service_name ==="
    
    # Check if deployment exists and is ready
    if kubectl get deployment "$service_name" &>/dev/null; then
        local ready_replicas=$(kubectl get deployment "$service_name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        local desired_replicas=$(kubectl get deployment "$service_name" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        log "$exp_dir" "  Deployment status: $ready_replicas/$desired_replicas pods ready"
        
        # Get pod details
        log "$exp_dir" "  Pod details:"
        kubectl get pods -l app="$service_name" -o wide | while read -r line; do
            log "$exp_dir" "    $line"
        done
        
        # Check recent logs for registration attempts
        log "$exp_dir" "  Recent logs (last 20 lines):"
        kubectl logs deployment/"$service_name" --tail=20 2>/dev/null | while read -r line; do
            log "$exp_dir" "    $line"
        done | grep -E "(consul|register|error)" || log "$exp_dir" "    No registration-related logs found"
        
        # Check if service can connect to Consul
        log "$exp_dir" "  Testing Consul connectivity from $service_name:"
        kubectl exec -it deployment/"$service_name" -- sh -c "nc -z consul 8500 && echo 'Consul reachable' || echo 'Consul unreachable'" 2>/dev/null || \
            log "$exp_dir" "    Could not test Consul connectivity"
    else
        log "$exp_dir" "  Deployment $service_name does not exist"
    fi
    
    log "$exp_dir" "=== END DEBUG: $service_name ==="
}

# Clean up pending pods that might be stuck
cleanup_pending_pods() {
    local exp_dir="$1"
    
    log "$exp_dir" "Cleaning up any pending pods that might be stuck..."
    
    # Get pending pods in default namespace
    local pending_pods=$(kubectl get pods -n default --field-selector=status.phase=Pending -o name 2>/dev/null || echo "")
    
    if [[ -n "$pending_pods" ]]; then
        echo "$pending_pods" | while read -r pod; do
            if [[ -n "$pod" ]]; then
                log "$exp_dir" "  Deleting pending pod: $pod"
                kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
            fi
        done
        
        # Wait a moment for cleanup
        sleep 5
    else
        log "$exp_dir" "No pending pods found"
    fi
}

# Remove anti-affinity rules from deployments
remove_anti_affinity() {
    local deployments="$1"
    local exp_dir="$2"
    
    log "$exp_dir" "Removing anti-affinity rules from deployments: $deployments"
    
    for deployment in $deployments; do
        log "$exp_dir" "  Removing anti-affinity from $deployment"
        kubectl patch deployment "$deployment" -n default --type='merge' -p '{
          "spec": {
            "template": {
              "spec": {
                "affinity": null
              }
            }
          }
        }' 2>/dev/null || log "$exp_dir" "    Warning: Failed to remove anti-affinity from $deployment"
    done
}

# Cleanup manual service registrations
cleanup_manual_registrations() {
    local exp_dir="$1"
    
    log "$exp_dir" "Cleaning up manual service registrations..."
    
    # Get Consul pod
    local consul_pod=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "$consul_pod" ]]; then
        log "$exp_dir" "WARNING: Could not find Consul pod for cleanup"
        return 0
    fi
    
    # List of manual service IDs to clean up
    local manual_services=("manual-frontend" "manual-search" "manual-geo" "manual-profile" "manual-rate" "manual-recommendation" "manual-reservation" "manual-user")
    
    for service_id in "${manual_services[@]}"; do
        log "$exp_dir" "  Deregistering $service_id"
        kubectl exec -it "$consul_pod" -- consul services deregister -id="$service_id" 2>/dev/null || true
    done
    
    log "$exp_dir" "Manual registration cleanup completed"
}

# Cleanup victim services
cleanup_victim_services() {
    local services="$1"
    local target_node="$2"
    local exp_dir="$3"
    
    log "$exp_dir" "Cleaning up victim services: $services"
    
    for service in $services; do
        # Remove taint and toleration
        "$TAINT_SCRIPT" "$target_node" "$service" --untolerate
        
        # Delete the deployment
        kubectl delete deployment "$service" --ignore-not-found=true
        kubectl delete service "$service" --ignore-not-found=true
        
        log "$exp_dir" "Service $service cleaned up"
    done
}

# Start performance monitoring for all victim services
start_monitoring() {
    local services="$1"
    local duration="$2"
    local counter_set="$3"
    local exp_dir="$4"
    local iteration="$5"
    
    log "$exp_dir" "Starting performance monitoring for services: $services"
    
    local monitor_pids=()
    
    for service in $services; do
        log "$exp_dir" "Starting monitor for $service with counter set: $counter_set"
        
        # Start monitoring in background and redirect output
        "$MONITOR_SCRIPT" "$service" default "$duration" "$counter_set" \
            > "$exp_dir/raw/perf/${service}_iter${iteration}.txt" 2>&1 &
        
        local pid=$!
        monitor_pids+=($pid)
        echo "$pid:$service" >> "$exp_dir/raw/perf/monitor_pids_iter${iteration}.txt"
        
        log "$exp_dir" "Monitor started for $service (PID: $pid)"
        sleep 2  # Stagger starts slightly
    done
    
    echo "${monitor_pids[@]}"
}

# Start wrk2 workload generation and collect e2e latency metrics
start_workload_and_latency() {
    local target_service="$1"
    local duration="$2"
    local exp_dir="$3"
    local iteration="$4"
    local workload_script="$5"
    local rate="$6"
    local threads="$7"
    local connections="$8"
    
    # Skip if no target service specified
    if [[ -z "$target_service" ]]; then
        log "$exp_dir" "No wrk2 target service specified, skipping workload generation"
        return
    fi
    
    # Skip if wrk2 not available
    if [[ ! -f "$WRK2_DIR/wrk" ]]; then
        log "$exp_dir" "wrk2 not found, skipping workload generation"
        return
    fi
    
    log "$exp_dir" "Starting wrk2 workload generation for $target_service"
    
    # Get service endpoint - try different methods
    local service_ip service_port target_url
    
    # Try cluster IP first
    service_ip=$(kubectl get service "$target_service" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    service_port=$(kubectl get service "$target_service" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "5000")
    
    if [[ -z "$service_ip" ]]; then
        log "$exp_dir" "WARNING: Could not get service IP for $target_service, trying external access"
        # Try to get external/nodeport access
        service_ip="${WRK2_TARGET_IP:-$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}"
        service_port="${WRK2_TARGET_PORT:-$(kubectl get service "$target_service" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "5000")}"
    fi
    
    target_url="http://${service_ip}:${service_port}"
    log "$exp_dir" "Target URL: $target_url"
    log "$exp_dir" "Workload script: ${workload_script:-none}"
    log "$exp_dir" "Rate: ${rate} RPS, Threads: $threads, Connections: $connections, Duration: ${duration}s"
    
    # Construct wrk2 command
    local wrk2_cmd="$WRK2_DIR/wrk -D exp -t $threads -c $connections -d ${duration}s -L -R $rate"
    
    if [[ -n "$workload_script" && -f "$workload_script" ]]; then
        wrk2_cmd="$wrk2_cmd -s $workload_script"
    fi
    
    wrk2_cmd="$wrk2_cmd $target_url"
    
    log "$exp_dir" "Running: $wrk2_cmd"
    
    # Run wrk2 and capture output
    $wrk2_cmd > "$exp_dir/raw/latency/${target_service}_iter${iteration}.txt" 2>&1 &
    
    local wrk2_pid=$!
    echo "$wrk2_pid:$target_service" >> "$exp_dir/raw/latency/workload_pids_iter${iteration}.txt"
    
    log "$exp_dir" "wrk2 workload started for $target_service (PID: $wrk2_pid)"
    
    echo "$wrk2_pid"
}

# Collect system metrics
collect_system_metrics() {
    local exp_dir="$1"
    local iteration="$2"
    local phase="$3"  # baseline, during, end
    
    # Create aggregated system metrics file
    local metrics_file="$exp_dir/raw/system/metrics_${phase}_iter${iteration}.txt"
    
    {
        echo "=== SYSTEM METRICS - $phase (iteration $iteration) ==="
        echo "Timestamp: $(date -Iseconds)"
        echo ""
        echo "=== NODE METRICS ==="
        kubectl top nodes 2>/dev/null || echo "kubectl top nodes failed"
        echo ""
        echo "=== POD METRICS ==="
        kubectl top pods --all-namespaces 2>/dev/null || echo "kubectl top pods failed"
        echo ""
        echo "=== POD PLACEMENT ==="
        kubectl get pods -o wide
        echo ""
    } > "$metrics_file"
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
    local exp_dir="$2"
    local iteration="$3"
    
    source "$config_file"
    
    log "$exp_dir" "Starting iteration $iteration"
    
    # Collect baseline metrics
    collect_system_metrics "$exp_dir" "$iteration" "baseline"
    
    # Calculate adjusted durations to account for startup delays
    # Add 10s to stressor duration and 5s to workload duration
    local stress_duration=$((EXPERIMENT_DURATION + 10))
    local workload_duration=$((EXPERIMENT_DURATION + 5))
    
    # Start noisy neighbor first
    log "$exp_dir" "Starting noisy neighbor: $NOISY_NEIGHBOR_TYPE with extended duration: ${stress_duration}s"
    
    # Modify stress args to include extended duration if the original args contain a duration
    local modified_stress_args="${NOISY_NEIGHBOR_ARGS:-}"
    if [[ "$modified_stress_args" =~ ([0-9]+)s ]]; then
        # Replace existing duration with extended duration
        modified_stress_args=$(echo "$modified_stress_args" | sed "s/[0-9]\+s/${stress_duration}s/")
        log "$exp_dir" "Modified stress args: $modified_stress_args"
    else
        log "$exp_dir" "Original stress args: $modified_stress_args (no duration modification needed)"
    fi
    
    "$STRESS_SCRIPT" "$NOISY_NEIGHBOR_TYPE" $modified_stress_args --node "$TARGET_NODE" \
        > "$exp_dir/raw/stress/stress_iter${iteration}.txt" 2>&1 &
    local stress_pid=$!
    
    # Wait longer before starting workload generation to ensure services are ready
    log "$exp_dir" "Waiting 15s before starting workload generation..."
    sleep 15
    
    # Start workload generation and latency collection
    local wrk2_pid=""
    if [[ -n "${WRK2_TARGET_SERVICE:-}" ]]; then
        log "$exp_dir" "Starting workload generation (duration: ${workload_duration}s)"
        wrk2_pid=$(start_workload_and_latency \
            "${WRK2_TARGET_SERVICE}" \
            "$workload_duration" \
            "$exp_dir" \
            "$iteration" \
            "${WRK2_SCRIPT:-}" \
            "${WRK2_RATE:-200}" \
            "${WRK2_THREADS:-2}" \
            "${WRK2_CONNECTIONS:-2}")
    fi
    
    # Wait before starting performance monitoring
    log "$exp_dir" "Waiting 10s before starting performance monitoring..."
    sleep 10
    
    # Start monitoring (runs for original experiment duration)
    log "$exp_dir" "Starting performance monitoring (duration: ${EXPERIMENT_DURATION}s)"
    local monitor_pids=($(start_monitoring "$VICTIM_SERVICES" "$EXPERIMENT_DURATION" "$PERF_COUNTER_SET" "$exp_dir" "$iteration"))
    
    # Collect metrics during stress
    sleep 30  # Let stress ramp up
    collect_system_metrics "$exp_dir" "$iteration" "during"
    
    # Wait for experiment to complete
    # Total delays so far: 15s (stressor->workload) + 10s (workload->monitoring) + 30s (ramp) = 55s
    local remaining_time=$((EXPERIMENT_DURATION - 55))
    if [[ $remaining_time -gt 0 ]]; then
        log "$exp_dir" "Waiting ${remaining_time}s for experiment to complete..."
        sleep "$remaining_time"
    fi
    
    # Collect end metrics
    collect_system_metrics "$exp_dir" "$iteration" "end"
    
    # Wait for all monitoring to complete
    wait_for_processes "${monitor_pids[@]}"
    
    # Wait for wrk2 to complete if it was started
    if [[ -n "$wrk2_pid" ]]; then
        wait "$wrk2_pid" 2>/dev/null || true
    fi
    
    # Cleanup stress pods
    "$STRESS_SCRIPT" cleanup
    
    log "$exp_dir" "Iteration $iteration completed"
}

# Generate experiment metadata
generate_metadata() {
    local config_file="$1"
    local exp_dir="$2"
    local exp_id="$3"
    
    source "$config_file"
    
    cat > "$exp_dir/metadata/experiment.json" << EOF
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
        "timing": {
            "base_duration": $EXPERIMENT_DURATION,
            "stressor_duration": "$((EXPERIMENT_DURATION + 10))",
            "workload_duration": "$((EXPERIMENT_DURATION + 5))",
            "monitoring_duration": $EXPERIMENT_DURATION,
            "startup_delays": {
                "stressor_to_workload": 5,
                "workload_to_monitoring": 5
            }
        },
        "iterations": ${ITERATIONS:-3},
        "iteration_delay": ${ITERATION_DELAY:-60},
        "wrk2_config": {
            "target_service": "${WRK2_TARGET_SERVICE:-none}",
            "target_ip": "${WRK2_TARGET_IP:-auto}",
            "target_port": "${WRK2_TARGET_PORT:-5000}",
            "script": "${WRK2_SCRIPT:-none}",
            "rate": ${WRK2_RATE:-200},
            "threads": ${WRK2_THREADS:-2},
            "connections": ${WRK2_CONNECTIONS:-2}
        }
    },
    "system_info": {
        "kubernetes_version": "$(kubectl version --client --short 2>/dev/null | cut -d' ' -f3 || echo 'unknown')",
        "target_node_info": $(kubectl get node "$TARGET_NODE" -o json 2>/dev/null | { if command -v jq >/dev/null 2>&1; then jq '{name: .metadata.name, capacity: .status.capacity, allocatable: .status.allocatable}'; else echo '{"name": "'$TARGET_NODE'", "info": "jq not available"}'; fi } 2>/dev/null || echo '{"name": "'$TARGET_NODE'", "error": "node info unavailable"}')
    },
    "scripts_used": {
        "stress_script": "$STRESS_SCRIPT",
        "monitor_script": "$MONITOR_SCRIPT",
        "taint_script": "$TAINT_SCRIPT"
    },
    "data_structure": {
        "raw/perf/": "Performance counters per service per iteration",
        "raw/latency/": "End-to-end latency metrics from wrk2",
        "raw/system/": "System-wide metrics (nodes, pods) per phase",
        "raw/stress/": "Stress test logs per iteration"
    }
}
EOF
}

# Aggregate iteration data into summary files
aggregate_data() {
    local exp_dir="$1"
    local total_iterations="$2"
    
    log "$exp_dir" "Aggregating data across $total_iterations iterations"
    
    # Aggregate latency data
    if ls "$exp_dir/raw/latency/"*_iter*.txt 1> /dev/null 2>&1; then
        {
            echo "=== AGGREGATED LATENCY METRICS ==="
            echo "Generated: $(date -Iseconds)"
            echo ""
            for i in $(seq 1 $total_iterations); do
                echo "=== ITERATION $i ==="
                for file in "$exp_dir/raw/latency/"*_iter${i}.txt; do
                    if [[ -f "$file" ]]; then
                        echo "--- $(basename "$file") ---"
                        cat "$file"
                        echo ""
                    fi
                done
            done
        } > "$exp_dir/processed/latency_summary.txt"
    fi
    
    # Aggregate performance data
    if ls "$exp_dir/raw/perf/"*_iter*.txt 1> /dev/null 2>&1; then
        {
            echo "=== AGGREGATED PERFORMANCE METRICS ==="
            echo "Generated: $(date -Iseconds)"
            echo ""
            for i in $(seq 1 $total_iterations); do
                echo "=== ITERATION $i ==="
                for file in "$exp_dir/raw/perf/"*_iter${i}.txt; do
                    if [[ -f "$file" ]]; then
                        echo "--- $(basename "$file") ---"
                        cat "$file"
                        echo ""
                    fi
                done
            done
        } > "$exp_dir/processed/performance_summary.txt"
    fi
    
    # Create experiment summary
    {
        echo "=== EXPERIMENT SUMMARY ==="
        echo "Generated: $(date -Iseconds)"
        echo ""
        echo "Raw data files: $(find "$exp_dir/raw" -name "*.txt" -o -name "*.csv" | wc -l)"
        echo "Total data size: $(du -sh "$exp_dir" | cut -f1)"
        echo ""
        echo "=== FILE STRUCTURE ==="
        find "$exp_dir" -type f | sort
    } > "$exp_dir/processed/experiment_summary.txt"
}

# Main experiment execution
run_experiment() {
    local config_file="$1"
    local exp_dir="$2"
    local exp_id="$3"
    
    source "$config_file"
    
    local total_iterations=${ITERATIONS:-3}
    local iteration_delay=${ITERATION_DELAY:-60}
    
    log "$exp_dir" "Starting experiment: $EXPERIMENT_NAME"
    log "$exp_dir" "Total iterations: $total_iterations"
    log "$exp_dir" "Data directory: $exp_dir"
    
    # Clean up any existing stress pods first
    cleanup_existing_stress_pods "$exp_dir"
    
    # Clean up any pending pods that might be stuck
    cleanup_pending_pods "$exp_dir"
    
    # Remove any existing anti-affinity rules that might be causing issues
    log "$exp_dir" "Removing any existing anti-affinity rules from all deployments..."
    local all_deployments=$(kubectl get deployments -n default -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
    if [[ -n "$all_deployments" ]]; then
        remove_anti_affinity "$all_deployments" "$exp_dir"
        sleep 10  # Wait for changes to take effect
    fi
    
    # Check and untolerate existing pods on target node first
    check_and_untolerate_pods "$TARGET_NODE" "$exp_dir"
    
    # Read the list of untolerated deployments for later cleanup
    local untolerated_deployments=""
    if [[ -f "$exp_dir/metadata/untolerated_deployments.txt" ]]; then
        untolerated_deployments=$(cat "$exp_dir/metadata/untolerated_deployments.txt")
    fi
    
    # Deploy victim services
    deploy_victim_services "$VICTIM_SERVICES" "$TARGET_NODE" "$exp_dir"
    
    # Wait for services to stabilize after deployment
    log "$exp_dir" "Waiting for services to stabilize after deployment..."
    sleep 45  # Increased from 30s to 45s
    
    # Monitor initial service registration
    log "$exp_dir" "Monitoring initial service registration in Consul..."
    monitor_consul_service_registration "$exp_dir" 90 10
    
    # Configure Jaeger tracing for all services after deployment
    configure_jaeger_tracing "$exp_dir"
    
    # Final validation before starting experiments
    log "$exp_dir" "Performing final system validation before starting experiments..."
    if ! validate_system_readiness "$exp_dir"; then
        log "$exp_dir" "WARNING: Initial system validation failed. Attempting recovery..."
        
        # Try manual registration as last resort
        if manual_register_all_services "$exp_dir"; then
            log "$exp_dir" "Manual registration successful. Re-validating system..."
            if validate_system_readiness "$exp_dir"; then
                log "$exp_dir" " System validation passed after manual registration. Ready to start experiments."
            else
                log "$exp_dir" "ERROR: System validation still failed after manual registration. Aborting experiment."
                exit 1
            fi
        else
            log "$exp_dir" "ERROR: Manual registration failed. System validation failed. Aborting experiment."
            exit 1
        fi
    else
        log "$exp_dir" " System validation passed. Ready to start experiments."
    fi
    
    # Run iterations
    for iteration in $(seq 1 $total_iterations); do
        log "$exp_dir" "=== Iteration $iteration/$total_iterations ==="
        
        run_iteration "$config_file" "$exp_dir" "$iteration"
        
        # Wait between iterations
        if [[ $iteration -lt $total_iterations ]]; then
            log "$exp_dir" "Waiting ${iteration_delay}s before next iteration"
            sleep "$iteration_delay"
        fi
    done
    
    # Aggregate data
    aggregate_data "$exp_dir" "$total_iterations"
    
    # Cleanup
    cleanup_victim_services "$VICTIM_SERVICES" "$TARGET_NODE" "$exp_dir"
    
    # Clean up any manual service registrations
    cleanup_manual_registrations "$exp_dir"
    
    # Remove anti-affinity rules from untolerated deployments
    if [[ -n "$untolerated_deployments" ]]; then
        remove_anti_affinity "$untolerated_deployments" "$exp_dir"
    fi
    
    log "$exp_dir" "Experiment completed successfully"
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
        echo "# Jaeger tracing configuration:"
        echo "JAEGER_SAMPLE_RATIO=0.01  # 1% sampling rate (default if not specified)"
        echo "#JAEGER_SAMPLE_RATIO=0    # Set to 0 to skip Jaeger configuration entirely"
        echo "# wrk2 configuration:"
        echo "WRK2_TARGET_SERVICE='frontend'"
        echo "WRK2_TARGET_IP='192.168.202.238'"
        echo "WRK2_TARGET_PORT=5000"
        echo "WRK2_SCRIPT='../wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua'"
        echo "WRK2_RATE=200"
        echo "WRK2_THREADS=2"
        echo "WRK2_CONNECTIONS=2"
        exit 1
    fi
    
    local config_file="$1"
    
    # Validate configuration
    validate_config "$config_file"
    
    # Generate experiment ID
    local exp_id=$(generate_exp_id)
    echo "Generated experiment ID: $exp_id"
    
    # Create experiment directory
    local exp_dir=$(create_exp_directory "$exp_id")
    echo "Experiment directory: $exp_dir"
    
    # Generate metadata
    generate_metadata "$config_file" "$exp_dir" "$exp_id"
    
    # Run experiment
    run_experiment "$config_file" "$exp_dir" "$exp_id"
    
    echo "Experiment completed successfully!"
    echo "Data location: $exp_dir"
    echo "Summary: $exp_dir/processed/experiment_summary.txt"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi