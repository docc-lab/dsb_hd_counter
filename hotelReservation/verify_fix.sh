#!/bin/bash

echo "=== Verifying Service Discovery Fix ==="

CONSUL_POD=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}')
FRONTEND_POD=$(kubectl get pods -l io.kompose.service=frontend -o jsonpath='{.items[0].metadata.name}')

echo "Consul pod: $CONSUL_POD"
echo "Frontend pod: $FRONTEND_POD"

# Test 1: Check if services stay registered
echo -e "\n=== 1. Service Registration Status ==="
kubectl exec -it $CONSUL_POD -- consul catalog services

# Test 2: Check service health properly
echo -e "\n=== 2. Service Health Status ==="
for service in srv-geo srv-profile srv-rate srv-recommendation srv-reservation srv-search srv-user; do
    echo "Checking $service health:"
    kubectl exec -it $CONSUL_POD -- consul health checks $service 2>/dev/null || echo "Health check command failed, trying alternative..."
    kubectl exec -it $CONSUL_POD -- consul catalog service $service 2>/dev/null || echo "Service query failed"
    echo ""
done

# Test 3: Check frontend logs for errors
echo -e "\n=== 3. Frontend Error Check ==="
echo "Checking for recent errors in frontend logs:"
kubectl logs $FRONTEND_POD --since=5m | grep -i "error\|fail\|refused" || echo "No errors found in recent logs!"

# Test 4: Test actual service calls
echo -e "\n=== 4. Service Connectivity Test ==="
echo "Testing if frontend can actually reach services..."

# Get frontend pod IP for testing
FRONTEND_IP=$(kubectl get pod $FRONTEND_POD -o jsonpath='{.status.podIP}')
echo "Frontend IP: $FRONTEND_IP"

# Test if we can make a simple request to frontend
echo "Testing frontend endpoint..."
kubectl run test-client --rm -i --tty --image=curlimages/curl -- curl -s -m 10 http://$FRONTEND_IP:5000/ | head -5 || echo "Frontend test failed"

# Test 5: Monitor for any new errors
echo -e "\n=== 5. Real-time Error Monitoring ==="
echo "Monitoring logs for 30 seconds to catch any new errors..."
timeout 30s kubectl logs -f $FRONTEND_POD | grep -i "error\|fail\|refused" || echo "No errors detected during monitoring period!"

echo -e "\n=== Verification Summary ==="
REGISTERED_COUNT=$(kubectl exec -it $CONSUL_POD -- consul catalog services | grep -v consul | wc -l)
echo "Services registered: $REGISTERED_COUNT/7"

if [ "$REGISTERED_COUNT" -eq 7 ]; then
    echo "✅ ALL SERVICES REGISTERED"
else
    echo "⚠️  Some services missing from registration"
fi

echo -e "\n=== Testing Service Discovery Resolution ==="
# Test if the consul resolver is actually working
kubectl logs $FRONTEND_POD --since=2m | grep -i "consul.*resolver" || echo "No consul resolver messages in recent logs"

echo -e "\nFix verification complete!"
echo "If no errors are shown above, the service discovery issue is resolved!"
