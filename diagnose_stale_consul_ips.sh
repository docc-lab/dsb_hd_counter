#!/bin/bash

echo "=== Diagnosing Consul Stale IP Issue ==="
echo "Timestamp: $(date -Iseconds)"
echo

# Get Consul pod
CONSUL_POD=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$CONSUL_POD" ]]; then
    echo "ERROR: Could not find Consul pod"
    exit 1
fi

echo "1. Current Consul Registrations with IPs:"
echo "=========================================="

services=("srv-search:search:8082" "srv-geo:geo:8083" "srv-profile:profile:8081" "srv-rate:rate:8084" "srv-recommendation:recommendation:8085" "srv-reservation:reservation:8087" "srv-user:user:8086")

for service_info in "${services[@]}"; do
    IFS=':' read -r consul_name k8s_name port <<< "$service_info"
    
    echo -e "\n=== $consul_name ==="
    
    # Get Consul registered IP
    consul_ip=$(kubectl exec -it "$CONSUL_POD" -- consul catalog service "$consul_name" 2>/dev/null | grep -E "Address.*:" | head -1 | awk '{print $2}' | tr -d '\r')
    
    # Get actual pod IP
    pod_ip=$(kubectl get pod -l io.kompose.service="$k8s_name" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    
    # Get pod name and status
    pod_name=$(kubectl get pod -l io.kompose.service="$k8s_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    pod_status=$(kubectl get pod -l io.kompose.service="$k8s_name" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    
    echo "Consul IP:  $consul_ip"
    echo "Pod IP:     $pod_ip"
    echo "Pod name:   $pod_name"
    echo "Pod status: $pod_status"
    
    if [[ "$consul_ip" != "$pod_ip" ]]; then
        echo "❌ IP MISMATCH DETECTED!"
        
        # Try to ping the Consul IP to see if it's reachable
        echo "Testing connectivity to Consul IP..."
        if kubectl exec -it "$CONSUL_POD" -- ping -c 1 -W 1 "$consul_ip" &>/dev/null; then
            echo "  Consul IP is pingable (old pod still exists?)"
        else
            echo "  Consul IP is NOT reachable (stale registration)"
        fi
    else
        echo "✓ IPs match"
    fi
done

echo -e "\n\n2. K8s DNS Resolution:"
echo "======================"
# Check DNS resolution from search service
SEARCH_POD=$(kubectl get pods -l io.kompose.service=search -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$SEARCH_POD" ]]; then
    echo "DNS resolution from search pod:"
    kubectl exec "$SEARCH_POD" -- getent hosts consul 2>/dev/null || echo "  getent failed"
    kubectl exec "$SEARCH_POD" -- getent hosts geo 2>/dev/null || echo "  getent failed"
fi

echo -e "\n\n3. Cluster IP (stable) vs Pod IPs (dynamic):"
echo "=============================================="
for service_info in "${services[@]}"; do
    IFS=':' read -r consul_name k8s_name port <<< "$service_info"
    cluster_ip=$(kubectl get service "$k8s_name" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    pod_ip=$(kubectl get pod -l io.kompose.service="$k8s_name" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)
    echo "$k8s_name: Cluster IP=$cluster_ip, Pod IP=$pod_ip"
done

echo -e "\n\n4. Recent Pod Events (looking for restarts):"
echo "=============================================="
kubectl get events --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' | grep -E "search|geo|profile|rate|recommendation|reservation|user" | tail -20

echo -e "\n\n=== Diagnosis Complete ==="
echo "If you see IP MISMATCHes above, Consul has stale registrations."
echo "The fix is to force services to re-register with their current IPs."

