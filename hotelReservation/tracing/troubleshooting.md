# Troubleshooting Jaeger Tracing in Kubernetes Microservices

## Summary of Our Troubleshooting Journey

We successfully resolved a complete lack of distributed tracing in a hotel reservation microservices system. The issue involved multiple configuration problems that prevented application traces from appearing in Jaeger, despite having reasonable workload latency.

## Root Causes Identified and Fixed

1. **Low Sampling Rate (1% → 100%)**
2. **Missing Search Service**
3. **Configuration Mismatch (UDP Agent vs HTTP Collector)**
4. **Environment Variable Conflicts**

---

## Complete Troubleshooting Guide

### 1. Initial Diagnosis

#### Check if Jaeger is deployed and running
```bash
kubectl get pods -l io.kompose.service=jaeger
kubectl get svc jaeger
kubectl logs -l io.kompose.service=jaeger
```

#### Verify Jaeger UI accessibility
```bash
kubectl port-forward svc/jaeger 16686:16686 &
# Access http://localhost:16686
```

### 2. Service Configuration Issues

#### Check microservice sampling rate
```bash
kubectl logs deployment/frontend | grep "sample ratio"
kubectl logs deployment/user | grep "sample ratio"
```

**Problem**: Services showing `0.010000` (1%) instead of `0.990000` (99%)

**Solution**: Set correct sampling rate
```bash
kubectl set env deployment/frontend JAEGER_SAMPLE_RATIO=1.0
kubectl set env deployment/user JAEGER_SAMPLE_RATIO=1.0
# Repeat for all services
```

### 3. Missing Service Dependencies

#### Check for missing services
```bash
kubectl get deployments
kubectl get svc | grep search
```

**Problem**: Frontend trying to connect to `srv-search` but search service not deployed

**Solution**: Deploy missing services
```bash
kubectl apply -f hotelReservation/kubernetes/search/
kubectl set env deployment/search JAEGER_SAMPLE_RATIO=1.0
```

### 4. Jaeger Configuration Mismatch

#### Check service logs for connection method
```bash
kubectl logs deployment/frontend | grep -E "jaeger|6831|14268"
```

**Problem**: Services configured for UDP agent (port 6831) but Jaeger only has HTTP collector (port 14268)

#### Verify Jaeger listening ports
```bash
kubectl exec -it deployment/jaeger -- netstat -ln | grep -E "6831|14268"
```

**Solution**: Configure services for HTTP collector
```bash
# Set HTTP collector endpoint
kubectl set env deployment/frontend JAEGER_ENDPOINT=http://jaeger:14268/api/traces
kubectl set env deployment/search JAEGER_ENDPOINT=http://jaeger:14268/api/traces
# Repeat for all services

# Remove agent configuration
kubectl set env deployment/frontend JAEGER_AGENT_HOST-
kubectl set env deployment/search JAEGER_AGENT_HOST-
# Repeat for all services
```

### 5. Verification Steps

#### Check if services are registered in Jaeger
```bash
kubectl exec -it deployment/jaeger -- wget -qO- "http://localhost:16686/api/services" 2>/dev/null
```

#### Verify spans are being received
```bash
kubectl exec -it deployment/jaeger -- wget -qO- http://localhost:14269/metrics | grep "spans_received_total" | grep -v "=0"
```

#### Generate test traffic
```bash
kubectl exec -it deployment/frontend -- curl -s "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194"
```

#### Check span counts after traffic
```bash
kubectl exec -it deployment/jaeger -- wget -qO- http://localhost:14269/metrics | grep "spans_saved_by_svc_total" | grep -v "=0"
```

---

## Quick Fix Script

```bash
#!/bin/bash
# Quick Jaeger Tracing Fix Script

echo "=== Fixing Jaeger Tracing Issues ==="

# 1. Set correct sampling rate for all services
echo "Setting sampling rate to 100%..."
for deployment in frontend search geo rate profile recommendation reservation user; do
    kubectl set env deployment/$deployment JAEGER_SAMPLE_RATIO=1.0 2>/dev/null || echo "Warning: $deployment not found"
done

# 2. Configure HTTP collector endpoint
echo "Configuring HTTP collector endpoint..."
for deployment in frontend search geo rate profile recommendation reservation user; do
    kubectl set env deployment/$deployment JAEGER_ENDPOINT=http://jaeger:14268/api/traces 2>/dev/null || echo "Warning: $deployment not found"
done

# 3. Remove agent configuration
echo "Removing UDP agent configuration..."
for deployment in frontend search geo rate profile recommendation reservation user; do
    kubectl set env deployment/$deployment JAEGER_AGENT_HOST- 2>/dev/null || echo "Warning: $deployment not found"
done

# 4. Wait for rollouts
echo "Waiting for deployments to restart..."
sleep 30

# 5. Verify configuration
echo "Verifying configuration..."
kubectl logs deployment/frontend | grep "sample ratio" | tail -1
kubectl exec -it deployment/jaeger -- wget -qO- "http://localhost:16686/api/services" 2>/dev/null | grep -o '"[^"]*"' | grep -v "data\|total\|limit\|offset\|errors"

echo "=== Fix completed. Generate traffic to test tracing ==="
```

---

## Common Issues and Solutions

### Issue: Only seeing `jaeger-all-in-one` traces

**Symptoms**:
- Jaeger UI shows only internal Jaeger traces
- No application service traces
- Services show `0.010000` sampling rate

**Solution**:
```bash
# Fix sampling rate
kubectl set env deployment/frontend JAEGER_SAMPLE_RATIO=1.0
# Configure HTTP collector
kubectl set env deployment/frontend JAEGER_ENDPOINT=http://jaeger:14268/api/traces
```

### Issue: Services can't find each other

**Symptoms**:
- `rpc error: code = Unavailable desc = last resolver error: produced zero addresses`
- Missing services in deployment list

**Solution**:
```bash
# Deploy missing services
kubectl apply -f hotelReservation/kubernetes/search/
# Check Consul service discovery
kubectl exec -it deployment/consul -- consul catalog services
```

### Issue: Configuration not taking effect

**Symptoms**:
- Environment variables set but services still use old config
- Services still trying to connect to port 6831

**Solution**:
```bash
# Force restart deployments
kubectl rollout restart deployment/frontend
kubectl rollout status deployment/frontend --timeout=120s
```

### Issue: Traces not appearing despite configuration

**Symptoms**:
- Services configured correctly
- No spans in Jaeger metrics

**Solution**:
```bash
# Check connectivity
kubectl exec -it deployment/frontend -- curl -v http://jaeger:14268/api/traces -X POST -H "Content-Type: application/x-thrift" --data-binary "test"
# Monitor Jaeger logs while generating traffic
kubectl logs -f deployment/jaeger | grep -i "span" &
```

---

## Environment Variables Reference

### Jaeger Client Configuration

| Variable | Purpose | Correct Value |
|----------|---------|---------------|
| `JAEGER_SAMPLE_RATIO` | Sampling rate | `1.0` (100%) |
| `JAEGER_ENDPOINT` | HTTP collector endpoint | `http://jaeger:14268/api/traces` |
| `JAEGER_AGENT_HOST` | UDP agent host | Remove this variable |

### Service-Specific Configuration

```bash
# Example for frontend service
kubectl set env deployment/frontend \
  JAEGER_SAMPLE_RATIO=1.0 \
  JAEGER_ENDPOINT=http://jaeger:14268/api/traces

kubectl set env deployment/frontend JAEGER_AGENT_HOST-
```

---

## Monitoring and Validation

### Key Metrics to Monitor

```bash
# Services registered
kubectl exec -it deployment/jaeger -- wget -qO- "http://localhost:16686/api/services" 2>/dev/null

# Spans received per service
kubectl exec -it deployment/jaeger -- wget -qO- http://localhost:14269/metrics | grep "spans_received_total.*=.*[1-9]"

# Spans saved per service  
kubectl exec -it deployment/jaeger -- wget -qO- http://localhost:14269/metrics | grep "spans_saved_by_svc_total.*=.*[1-9]"
```

### Traffic Generation for Testing

```bash
# Generate inter-service communication
kubectl exec -it deployment/frontend -- curl -s "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194"

# Multiple requests for varied traces
for i in {1..5}; do
  kubectl exec -it deployment/frontend -- curl -s "http://frontend:5000/hotels?inDate=2015-04-0${i}&outDate=2015-04-10&lat=37.7749&lon=-122.4194" >/dev/null
done
```

---

## Success Indicators

✅ **Multiple services in Jaeger UI dropdown**
✅ **Non-zero span counts in metrics**
✅ **Distributed traces showing multiple services**
✅ **Service logs showing `1.000000` sampling rate**
✅ **HTTP collector endpoint in service configuration**

## Final Validation

After applying fixes, you should see:

1. **Jaeger UI**: Multiple services available in dropdown
2. **Trace View**: Multi-service traces with 10-20 spans per request
3. **Service Metrics**: Non-zero span counts for all services
4. **Service Logs**: Correct sampling rate and HTTP collector usage

---

*This guide was created based on successfully troubleshooting a hotel reservation microservices system where distributed tracing was completely non-functional despite working application endpoints.*
