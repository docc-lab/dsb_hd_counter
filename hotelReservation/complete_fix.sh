#!/bin/bash

echo "=== Complete Service Discovery Fix ==="

# Get current Consul info
CONSUL_POD=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}')
CONSUL_IP=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].status.podIP}')

echo "Current Consul pod: $CONSUL_POD"
echo "Current Consul IP: $CONSUL_IP"

# Step 1: Clear any existing manual registrations
echo -e "\n=== 1. Cleaning up existing registrations ==="
kubectl exec -it $CONSUL_POD -- consul services deregister -id=manual-test 2>/dev/null || echo "No manual test service to deregister"

# Step 2: Force DNS cache refresh by restarting all services
echo -e "\n=== 2. Restarting services to fix DNS cache ==="

# Restart services in dependency order
services=("geo" "rate" "profile" "recommendation" "user" "reservation" "search" "frontend")

for service in "${services[@]}"; do
    echo "Restarting $service..."
    kubectl rollout restart deployment/$service
done

# Wait for services to be ready
echo -e "\n=== 3. Waiting for services to be ready ==="
for service in "${services[@]}"; do
    echo "Waiting for $service..."
    kubectl rollout status deployment/$service --timeout=120s
done

# Step 4: Monitor registration process
echo -e "\n=== 4. Monitoring service registration ==="
sleep 10

# Check what's registered now
echo "Services in catalog:"
kubectl exec -it $CONSUL_POD -- consul catalog services

# Step 5: Check health of registered services
echo -e "\n=== 5. Checking service health ==="
REGISTERED_SERVICES=$(kubectl exec -it $CONSUL_POD -- consul catalog services | grep -v consul | tr -d '\r')

for service in $REGISTERED_SERVICES; do
    if [ ! -z "$service" ] && [ "$service" != "consul" ]; then
        echo "Health check for $service:"
        kubectl exec -it $CONSUL_POD -- consul health service $service
        echo ""
    fi
done

# Step 6: Test frontend connectivity
echo -e "\n=== 6. Testing frontend connectivity ==="
FRONTEND_POD=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}')
echo "Recent frontend logs:"
kubectl logs $FRONTEND_POD | tail -10

# Step 7: Check for any remaining DNS issues
echo -e "\n=== 7. DNS Resolution Check ==="
RATE_POD=$(kubectl get pods -l io.kompose.service=rate -o jsonpath='{.items[0].metadata.name}')
if [ ! -z "$RATE_POD" ]; then
    echo "DNS resolution from rate service:"
    kubectl exec $RATE_POD -- getent hosts consul 2>/dev/null || echo "getent failed"
    
    # Test direct connection to Consul
    echo "Testing direct connection to Consul:"
    kubectl exec $RATE_POD -- timeout 5s nc -zv consul 8500 2>/dev/null || echo "Connection test failed"
fi

echo -e "\n=== Fix Summary ==="
FINAL_SERVICES=$(kubectl exec -it $CONSUL_POD -- consul catalog services | grep -v consul | wc -l)
echo "Services registered in Consul: $FINAL_SERVICES"

if [ "$FINAL_SERVICES" -gt 0 ]; then
    echo "✅ SUCCESS: Services are now registered in Consul!"
    echo "The DNS cache refresh resolved the connectivity issue."
else
    echo "❌ ISSUE PERSISTS: Services still not appearing in catalog."
    echo "This suggests the health checks are still failing."
    echo "Next step: Rebuild services with the improved health check configuration."
fi

echo -e "\nTo rebuild with improved health checks:"
echo "1. Build new image: docker build -t your-registry/hotel-reservation:health-fix ."
echo "2. Update deployments to use new image"
echo "3. Restart services again"
