#!/bin/bash

echo "=== Fixing Consul DNS Resolution Issue ==="

# Get current Consul pod IP
CONSUL_POD=$(kubectl get pods -l io.kompose.service=consul -o name | head -1)
CONSUL_IP=$(kubectl get pod ${CONSUL_POD#pod/} -o jsonpath='{.status.podIP}')

echo "Current Consul pod: $CONSUL_POD"
echo "Current Consul IP: $CONSUL_IP"

# Check if services can reach current Consul
echo -e "\n=== Testing Consul connectivity from services ==="
for service in rate search profile recommendation user reservation geo; do
    echo "Testing from $service service:"
    SERVICE_POD=$(kubectl get pods -l io.kompose.service=$service -o name | head -1)
    if [ ! -z "$SERVICE_POD" ]; then
        kubectl exec ${SERVICE_POD#pod/} -- nslookup consul || echo "DNS resolution failed for $service"
        kubectl exec ${SERVICE_POD#pod/} -- nc -zv consul 8500 || echo "Connection test failed for $service"
    fi
done

# Force DNS cache refresh by restarting services
echo -e "\n=== Restarting services to refresh DNS cache ==="

# Restart in dependency order (backend services first)
echo "Restarting backend services..."
for service in geo rate profile recommendation user reservation; do
    echo "Restarting $service..."
    kubectl rollout restart deployment/$service
done

# Wait for backend services
echo "Waiting for backend services..."
for service in geo rate profile recommendation user reservation; do
    kubectl rollout status deployment/$service --timeout=60s
done

# Restart search (depends on geo and rate)
echo "Restarting search..."
kubectl rollout restart deployment/search
kubectl rollout status deployment/search --timeout=60s

# Restart frontend (depends on all others)
echo "Restarting frontend..."
kubectl rollout restart deployment/frontend
kubectl rollout status deployment/frontend --timeout=60s

# Verify registration
echo -e "\n=== Verifying service registration ==="
sleep 15
kubectl exec -it $CONSUL_POD -- consul catalog services

# Check health of registered services
echo -e "\n=== Checking service health ==="
SERVICES=$(kubectl exec -it $CONSUL_POD -- consul catalog services | grep -v consul)
for service in $SERVICES; do
    if [ ! -z "$service" ]; then
        echo "Health check for $service:"
        kubectl exec -it $CONSUL_POD -- consul health service $service
    fi
done

echo -e "\n=== Fix completed ==="
