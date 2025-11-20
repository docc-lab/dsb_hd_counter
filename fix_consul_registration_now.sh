#!/bin/bash
# Emergency fix script for Consul stale IP issue
# Run this to immediately fix the current broken state

set -e

echo "=== Emergency Consul Registration Fix ==="
echo "Timestamp: $(date -Iseconds)"
echo

# Get Consul pod
CONSUL_POD=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$CONSUL_POD" ]]; then
    echo "ERROR: Could not find Consul pod"
    exit 1
fi

echo "Found Consul pod: $CONSUL_POD"
echo

# Service definitions: k8s_name:consul_name:port
services=(
    "search:srv-search:8082"
    "geo:srv-geo:8083"
    "profile:srv-profile:8081"
    "rate:srv-rate:8084"
    "recommendation:srv-recommendation:8085"
    "reservation:srv-reservation:8087"
    "user:srv-user:8086"
)

echo "Step 1: Deregistering all stale service entries..."
echo "=================================================="
for service_info in "${services[@]}"; do
    IFS=':' read -r k8s_name consul_name port <<< "$service_info"
    
    echo "Deregistering $consul_name..."
    
    # Try multiple ID patterns to catch all stale registrations
    for id_pattern in "manual-${k8s_name}" "${k8s_name}-auto" "$k8s_name"; do
        kubectl exec -it "$CONSUL_POD" -- consul services deregister -id="$id_pattern" 2>/dev/null || true
    done
done

echo
echo "Step 2: Registering services with current pod IPs..."
echo "======================================================"
registered_count=0

for service_info in "${services[@]}"; do
    IFS=':' read -r k8s_name consul_name port <<< "$service_info"
    
    # Get current pod IP
    pod_ip=$(kubectl get pod -l io.kompose.service="$k8s_name" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    
    if [[ -n "$pod_ip" ]]; then
        echo "Registering $consul_name at $pod_ip:$port"
        
        if kubectl exec -it "$CONSUL_POD" -- consul services register \
            -name="$consul_name" \
            -port="$port" \
            -address="$pod_ip" \
            -id="${k8s_name}-fixed" 2>/dev/null; then
            
            echo "  ✓ Success"
            ((registered_count++))
        else
            echo "  ✗ Failed"
        fi
    else
        echo "Skipping $k8s_name - pod not found"
    fi
done

echo
echo "Step 3: Waiting for registration to propagate..."
sleep 10

echo
echo "Step 4: Verifying registrations..."
echo "===================================="
echo "Services registered in Consul:"
kubectl exec -it "$CONSUL_POD" -- consul catalog services 2>/dev/null | grep -E "srv-" || echo "  No srv-* services found!"

echo
echo "Step 5: Testing connectivity..."
echo "================================"
FRONTEND_POD=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -n "$FRONTEND_POD" ]]; then
    echo "Testing /hotels endpoint..."
    http_code=$(kubectl exec -it "$FRONTEND_POD" -- curl -s -w "%{http_code}" -o /dev/null "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null || echo "000")
    
    if [[ "$http_code" == "200" ]]; then
        echo "  ✓ Success! HTTP $http_code"
    else
        echo "  ✗ Failed! HTTP $http_code"
        echo
        echo "  Checking error details..."
        kubectl exec -it "$FRONTEND_POD" -- curl -s "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null || echo "  (no response)"
    fi
else
    echo "  WARNING: Frontend pod not found, cannot test"
fi

echo
echo "=== Fix Complete ==="
echo "Registered: $registered_count/${#services[@]} services"
echo
echo "If the test still fails, run:"
echo "  1. ./diagnose_stale_consul_ips.sh  # to verify IPs now match"
echo "  2. Check service logs for other errors"

