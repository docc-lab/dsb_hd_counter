#!/bin/bash

echo "=== Hotel Reservation Service Discovery Diagnosis and Fix ==="

# Get Consul pod info
CONSUL_POD=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].metadata.name}')
CONSUL_IP=$(kubectl get pods -l io.kompose.service=consul -o jsonpath='{.items[0].status.podIP}')

echo "Consul pod: $CONSUL_POD"
echo "Consul IP: $CONSUL_IP"

# Step 1: Check current Consul state
echo -e "\n=== 1. Current Consul State ==="
kubectl exec -it $CONSUL_POD -- consul catalog services

# Step 2: Check what services think they registered
echo -e "\n=== 2. Checking Service Registration Logs ==="
for service in rate search profile recommendation user reservation geo; do
    echo "--- $service service logs ---"
    SERVICE_POD=$(kubectl get pods -l io.kompose.service=$service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$SERVICE_POD" ]; then
        kubectl logs $SERVICE_POD | grep -i "register\|consul" | tail -3
    else
        echo "No pod found for $service"
    fi
done

# Step 3: Check DNS resolution from services
echo -e "\n=== 3. DNS Resolution Test ==="
SERVICE_POD=$(kubectl get pods -l io.kompose.service=rate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$SERVICE_POD" ]; then
    echo "Testing DNS resolution from $SERVICE_POD:"
    kubectl exec $SERVICE_POD -- nslookup consul 2>/dev/null || echo "DNS lookup failed"
    kubectl exec $SERVICE_POD -- getent hosts consul 2>/dev/null || echo "getent lookup failed"
fi

# Step 4: Check Consul agent logs for registration attempts
echo -e "\n=== 4. Consul Agent Logs (Recent Registration Activity) ==="
kubectl logs $CONSUL_POD | grep -i "register\|service" | tail -10

# Step 5: Check if services are actually trying to register
echo -e "\n=== 5. Real-time Registration Monitoring ==="
echo "Monitoring Consul logs for 10 seconds..."
timeout 10s kubectl logs -f $CONSUL_POD | grep -i "register\|service" &
MONITOR_PID=$!

# Restart one service to see registration attempt
echo "Restarting rate service to trigger registration..."
kubectl rollout restart deployment/rate >/dev/null 2>&1

wait $MONITOR_PID 2>/dev/null

# Step 6: Check if the issue is health checks
echo -e "\n=== 6. Health Check Analysis ==="
kubectl exec -it $CONSUL_POD -- consul catalog services -detailed 2>/dev/null || echo "Detailed catalog failed"

# Step 7: Manual service registration test
echo -e "\n=== 7. Manual Registration Test ==="
RATE_POD=$(kubectl get pods -l io.kompose.service=rate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
RATE_IP=$(kubectl get pods -l io.kompose.service=rate -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ ! -z "$RATE_POD" ] && [ ! -z "$RATE_IP" ]; then
    echo "Attempting manual registration of rate service..."
    kubectl exec -it $CONSUL_POD -- consul services register -name=srv-rate -port=8084 -address=$RATE_IP -id=manual-test 2>/dev/null || echo "Manual registration failed"
    
    echo "Checking if manual registration worked:"
    kubectl exec -it $CONSUL_POD -- consul catalog services
fi

echo -e "\n=== Diagnosis Complete ==="
echo ""
echo "ANALYSIS:"
echo "1. If services show 'Successfully registered' but don't appear in catalog:"
echo "   -> Health checks are failing and deregistering services"
echo "2. If DNS resolution fails:"
echo "   -> Services can't reach Consul due to network/DNS issues"
echo "3. If manual registration works:"
echo "   -> Issue is in the service registration code"
echo ""
echo "RECOMMENDED ACTIONS:"
echo "1. If health checks are the issue: Rebuild with improved health checks"
echo "2. If DNS is the issue: Restart all pods to refresh DNS cache"
echo "3. If registration code is the issue: Check service startup logs"
