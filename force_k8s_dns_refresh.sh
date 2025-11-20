#!/bin/bash
# Force Kubernetes DNS cache refresh

set -e

echo "=== Forcing Kubernetes DNS Cache Refresh ==="
echo "Timestamp: $(date -Iseconds)"
echo

echo "Step 1: Restarting CoreDNS (cluster-level DNS cache)..."
echo "========================================================="
if kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null; then
    echo "  ✓ CoreDNS restart initiated"
    
    # Wait for CoreDNS to be ready
    echo "  Waiting for CoreDNS to be ready..."
    kubectl rollout status deployment/coredns -n kube-system --timeout=60s 2>/dev/null && \
        echo "  ✓ CoreDNS is ready" || echo "  ⚠ CoreDNS restart timeout"
else
    echo "  ⚠ WARNING: Could not restart CoreDNS (insufficient permissions?)"
    echo "  This may require cluster admin privileges"
fi

echo
echo "Step 2: Restarting service pods (pod-level DNS cache)..."
echo "=========================================================="
services=("search" "geo" "profile" "rate" "recommendation" "reservation" "user" "frontend")

for service in "${services[@]}"; do
    if kubectl get deployment "$service" &>/dev/null; then
        echo "Restarting $service pods..."
        
        # Delete pods to force DNS cache clear (faster than rollout restart)
        if kubectl delete pod -l io.kompose.service="$service" --grace-period=5 2>/dev/null; then
            echo "  ✓ Pods deleted"
        else
            echo "  ⚠ Failed to delete pods, trying rollout restart..."
            kubectl rollout restart deployment/"$service" 2>/dev/null || echo "  ✗ Failed"
        fi
    fi
done

echo
echo "Step 3: Waiting for all pods to be ready..."
echo "============================================"
sleep 10

for service in "${services[@]}"; do
    if kubectl get deployment "$service" &>/dev/null; then
        printf "  %-20s " "$service:"
        
        if kubectl wait --for=condition=ready pod -l io.kompose.service="$service" --timeout=60s &>/dev/null; then
            echo "✓ Ready"
        else
            echo "⚠ Timeout (may still be starting)"
        fi
    fi
done

echo
echo "Step 4: Verifying DNS resolution..."
echo "===================================="
# Test DNS resolution from a service pod
SEARCH_POD=$(kubectl get pods -l io.kompose.service=search -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -n "$SEARCH_POD" ]]; then
    echo "DNS resolution from search pod:"
    echo "  Consul:"
    kubectl exec "$SEARCH_POD" -- getent hosts consul 2>/dev/null | head -1 || echo "    ✗ Failed"
    
    echo "  Geo service:"
    kubectl exec "$SEARCH_POD" -- getent hosts geo 2>/dev/null | head -1 || echo "    ✗ Failed"
    
    echo "  Profile service:"
    kubectl exec "$SEARCH_POD" -- getent hosts profile 2>/dev/null | head -1 || echo "    ✗ Failed"
else
    echo "  ⚠ Search pod not ready yet, skipping DNS test"
fi

echo
echo "=== DNS Cache Refresh Complete ==="
echo
echo "Next: Test connectivity with:"
echo "  kubectl exec -it deployment/frontend -- curl -s \"http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194\""

