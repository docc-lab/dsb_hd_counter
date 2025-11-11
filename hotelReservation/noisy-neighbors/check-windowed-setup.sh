#!/bin/bash
# Quick diagnostic script to check windowed sampling setup

SERVICE="${1:-search}"

echo "=== Checking Windowed Sampling Setup for $SERVICE ==="
echo ""

# 1. Check pod exists
echo "1. Pod Status:"
POD_NAME=$(kubectl get pods -l io.kompose.service="$SERVICE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$POD_NAME" ]]; then
    echo "   ❌ No pod found for service $SERVICE"
    exit 1
else
    echo "   ✅ Pod found: $POD_NAME"
fi
echo ""

# 2. Check image being used
echo "2. Container Image:"
IMAGE=$(kubectl get pod "$POD_NAME" -o jsonpath='{.spec.containers[0].image}')
echo "   $IMAGE"
if [[ "$IMAGE" == *"windowed"* ]]; then
    echo "   ✅ Using windowed sampling image"
else
    echo "   ⚠️  NOT using windowed image (using: $IMAGE)"
fi
echo ""

# 3. Check environment variables
echo "3. Environment Variables:"
kubectl exec "$POD_NAME" -- env | grep -E "ENABLE_WINDOWED|ITERATION_ID|EXPERIMENT_DURATION|WINDOW_INTERVAL|PERF_EVENTS|OUTPUT_DIR" || echo "   ❌ No windowed sampling env vars set"
echo ""

# 4. Check /data directory
echo "4. Data Directory Contents:"
kubectl exec "$POD_NAME" -- ls -la /data/ 2>/dev/null || echo "   ❌ /data directory doesn't exist or is inaccessible"
echo ""

# 5. Check service logs for windowed sampling
echo "5. Service Logs (windowed sampling related):"
kubectl logs "$POD_NAME" --tail=100 | grep -i -E "(windowed|sampling|iteration|perf|ring.buffer)" | head -20 || echo "   ⚠️  No windowed sampling logs found"
echo ""

# 6. Check if service is even calling the windowed code
echo "6. Service Startup Logs:"
kubectl logs "$POD_NAME" --tail=50 | grep -E "(Starting|ENABLE_WINDOWED|mode)" || echo "   ⚠️  No startup mode logs found"
echo ""

echo "=== Diagnosis ==="
if kubectl exec "$POD_NAME" -- env | grep -q "ENABLE_WINDOWED_SAMPLING=true"; then
    echo "✅ Environment variables are set"
    
    if [[ "$IMAGE" == *"windowed"* ]]; then
        echo "✅ Using windowed image"
        echo ""
        echo "❓ Check service logs above to see why windowed sampling didn't start"
        echo "   Possible issues:"
        echo "   - Service code doesn't check ENABLE_WINDOWED_SAMPLING"
        echo "   - Service crashed during startup"
        echo "   - perf.SetupWindowedSampling() failed"
    else
        echo "❌ NOT using windowed image!"
        echo ""
        echo "Solution: Build and deploy windowed image:"
        echo "   cd /local/dsb_hd_counter/hotelReservation"
        echo "   ./ims-build-push-rollout.sh --mode-windowed $SERVICE v1-windowed"
    fi
else
    echo "❌ Environment variables NOT set"
    echo ""
    echo "Solution: Set environment variables manually:"
    echo "   kubectl set env deployment/$SERVICE ENABLE_WINDOWED_SAMPLING=true"
    echo "   kubectl set env deployment/$SERVICE ITERATION_ID=1"
    echo "   kubectl set env deployment/$SERVICE EXPERIMENT_DURATION=30"
    echo "   kubectl set env deployment/$SERVICE WINDOW_INTERVAL_MS=100"
    echo "   kubectl rollout restart deployment/$SERVICE"
fi

