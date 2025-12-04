#!/bin/bash

echo "=== Force DNS Cache Refresh ==="

# The DNS cache might be at the node level, not just pod level
# Let's try a more aggressive approach

echo "1. Checking current DNS resolution from multiple services..."
for service in rate profile search; do
    SERVICE_POD=$(kubectl get pods -l io.kompose.service=$service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$SERVICE_POD" ]; then
        echo "DNS from $service:"
        kubectl exec $SERVICE_POD -- getent hosts consul 2>/dev/null || echo "  getent failed"
        kubectl exec $SERVICE_POD -- nslookup consul 2>/dev/null | grep Address || echo "  nslookup failed"
    fi
done

echo -e "\n2. Forcing DNS cache flush by restarting CoreDNS..."
kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || echo "CoreDNS restart failed (might not have permissions)"

echo -e "\n3. Alternative: Delete pods to force complete restart..."
echo "This will cause brief downtime but ensures fresh DNS cache..."
read -p "Delete and recreate all service pods? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    for service in geo rate profile recommendation user reservation search frontend; do
        echo "Deleting $service pod..."
        kubectl delete pod -l io.kompose.service=$service
    done
    
    echo "Waiting for pods to restart..."
    sleep 30
    
    echo "Checking new DNS resolution..."
    RATE_POD=$(kubectl get pods -l io.kompose.service=rate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$RATE_POD" ]; then
        kubectl wait --for=condition=ready pod/$RATE_POD --timeout=60s
        echo "New DNS resolution:"
        kubectl exec $RATE_POD -- getent hosts consul 2>/dev/null || echo "Still failing"
    fi
else
    echo "Skipping pod deletion."
fi

echo -e "\n4. Checking if services are still working despite DNS cache..."
CONSUL_POD=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}')
echo "Services in catalog:"
kubectl exec -it $CONSUL_POD -- consul catalog services

echo -e "\nDNS refresh attempt complete."
