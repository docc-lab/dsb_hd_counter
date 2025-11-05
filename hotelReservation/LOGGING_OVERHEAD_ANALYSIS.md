# Logging Overhead Analysis for Per-Request Perf Instrumentation

## Overview

This document analyzes the potential logging overhead introduced by per-request timing and perf counter instrumentation.

## Current Logging Per Request

Each gRPC request generates **multiple log entries**:

### 1. Request Arrival (Server Interceptor Start)
```go
log.Info().
    Str("method", info.FullMethod).
    Str("service", config.ServiceName).
    Time("arrival_time", arrivalTime).
    Float64("blocking_time_ms", 0.0).
    Msg("gRPC call arrived")
```
**Estimated overhead**: ~1μs

### 2. Request Completion (Server Interceptor End)
```go
logEvent := log.Info().
    Str("method", info.FullMethod).
    Str("service", config.ServiceName).
    Int32("downstream_calls", blockingCount).
    Int32("active_calls_at_end", activeCount).
    Dur("total_time", totalTime).
    Dur("processing_time", processingTime).
    Dur("blocking_time", pausedTime).
    Float64("processing_time_ms", float64(processingTime.Nanoseconds())/1000000).
    Float64("total_time_ms", float64(totalTime.Nanoseconds())/1000000).
    Float64("blocking_time_ms", float64(pausedTime.Nanoseconds())/1000000).
    Interface("perf_total", map[string]int64{...}).      // 5-10 perf events
    Interface("perf_execution", map[string]int64{...}).  // 5-10 perf events
    Str("perf_data_type", "request_timing_perf").
    Msg("gRPC call completed")
```
**Estimated overhead**: ~5-8μs (including JSON serialization of perf maps)

### 3. Downstream Call Start (Client Interceptor - per downstream call)
```go
log.Info().
    Str("outgoing_method", method).
    Str("parent_service", timingData.ServiceName).
    Str("parent_method", timingData.Method).
    Int32("stack_depth", currentCount).
    Float64("blocking_time_ms", 0.0).
    Msg("Starting downstream call - PAUSING parent timer (stack 0→1)")
```
**Estimated overhead**: ~1-2μs per downstream call

### 4. Downstream Call Completion (Client Interceptor - per downstream call)
```go
log.Info().
    Str("outgoing_method", method).
    Str("parent_service", timingData.ServiceName).
    Str("parent_method", timingData.Method).
    Int32("stack_depth", newCount).
    Dur("this_call_duration", callDuration).
    Float64("this_call_duration_ms", float64(callDuration.Nanoseconds())/1000000).
    Float64("blocking_period_ms", float64(blockingDurationNs)/1000000).
    Float64("total_paused_ms", float64(totalPausedNs)/1000000).
    Float64("blocking_time_ms", float64(totalPausedNs)/1000000).
    Msg("Downstream call completed - RESUMING parent timer (stack 1→0)")
```
**Estimated overhead**: ~2-3μs per downstream call

## Total Overhead Estimation

### Scenario 1: Request with NO Downstream Calls
- Arrival log: ~1μs
- Completion log (with perf): ~5-8μs
- **Total**: ~6-9μs per request

### Scenario 2: Request with 2 Downstream Calls
- Arrival log: ~1μs
- 2x Downstream start: ~2-4μs
- 2x Downstream end: ~4-6μs
- Completion log (with perf): ~5-8μs
- **Total**: ~12-19μs per request

### Scenario 3: Request with 5 Downstream Calls
- Arrival log: ~1μs
- 5x Downstream start: ~5-10μs
- 5x Downstream end: ~10-15μs
- Completion log (with perf): ~5-8μs
- **Total**: ~21-34μs per request

## Overhead as Percentage of Request Time

| Request Processing Time | Overhead (2 calls) | Overhead % |
|------------------------|-------------------|------------|
| 100μs                  | 12-19μs           | 12-19%     |
| 500μs                  | 12-19μs           | 2.4-3.8%   |
| 1ms                    | 12-19μs           | 1.2-1.9%   |
| 5ms                    | 12-19μs           | 0.24-0.38% |
| 10ms                   | 12-19μs           | 0.12-0.19% |

## Zerolog Performance Characteristics

Zerolog is designed for **zero-allocation, high-performance logging**:

- Uses pre-allocated buffers
- Lazy evaluation of expensive operations
- Direct JSON encoding without reflection
- Benchmarked at **~1μs per log entry** for simple fields
- Interface{} fields (perf maps) add ~1-3μs for JSON marshaling

## Risk Assessment

### ✅ LOW RISK Scenarios (Overhead < 1%)
- Request processing time > 1ms
- Typical microservice requests (1-10ms range)
- Backend services with DB/network operations

### ⚠️ MODERATE RISK Scenarios (Overhead 1-5%)
- Request processing time 100-1000μs
- Fast in-memory operations
- Cache-only services

### 🚨 HIGH RISK Scenarios (Overhead > 5%)
- Request processing time < 100μs
- Ultra-low-latency services
- Hot path operations

## Mitigation Strategies

### 1. Conditional Logging (Implemented)
```go
if config.EnablePerf && (len(timingData.PerfTotal) > 0 || len(timingData.PerfExecution) > 0) {
    logEvent = logEvent.
        Interface("perf_total", timingData.PerfTotal).
        Interface("perf_execution", timingData.PerfExecution)
}
```
**Benefit**: No perf logging overhead when `EnablePerf=false`

### 2. Sampling (Not Yet Implemented)
```go
// Log only every Nth request
var requestCounter atomic.Uint64
if requestCounter.Add(1) % 10 == 0 {
    // Log this request
}
```
**Benefit**: Reduces overhead by 90% while maintaining statistical insights
**Trade-off**: Miss individual request data

### 3. Batch Buffered Logging (Not Yet Implemented)
```go
// Buffer log entries and flush periodically
type LogBuffer struct {
    entries []TimingData
    mu      sync.Mutex
}

func (lb *LogBuffer) Add(data TimingData) {
    lb.mu.Lock()
    defer lb.mu.Unlock()
    
    lb.entries = append(lb.entries, data)
    
    if len(lb.entries) >= 100 {  // Flush threshold
        lb.flush()
    }
}
```
**Benefit**: Reduces per-request overhead to ~0.5μs (just buffering)
**Trade-off**: Delayed visibility, memory usage, complexity

### 4. Async Logging (Not Yet Implemented)
```go
// Log in background goroutine
logChan := make(chan TimingData, 1000)

go func() {
    for data := range logChan {
        log.Info().Interface("data", data).Msg("request completed")
    }
}()

// In interceptor:
logChan <- *timingData  // Non-blocking if channel has capacity
```
**Benefit**: Near-zero overhead on request path
**Trade-off**: Memory for channel buffer, log ordering not guaranteed

### 5. Reduce Log Verbosity
```go
// Only log completion, skip start/downstream logs
if os.Getenv("LOG_VERBOSE") != "true" {
    // Skip arrival and downstream logs
}
```
**Benefit**: Reduces overhead by ~40-60%
**Trade-off**: Less visibility into request flow

## Recommended Approach

### Phase 1: Baseline (Current Implementation)
- **What**: Full logging with all details
- **When**: Initial experiments and debugging
- **Reason**: Maximum visibility for validation

### Phase 2: Measure
- **What**: Benchmark actual overhead in realistic workload
- **How**: Compare request latencies with `ENABLE_PERF=true` vs `false`
- **Metrics**: p50, p95, p99 latency impact
- **Decision**: Proceed to Phase 3 only if overhead > 2%

### Phase 3: Optimize (If Needed)
Based on measurements, implement in order:

1. **First**: Reduce log verbosity (remove start/downstream logs)
   - Easy to implement
   - ~40-60% overhead reduction
   
2. **Second**: Sampling (log 1 in N requests)
   - Simple implementation
   - Configurable trade-off
   
3. **Third**: Async logging
   - More complex but effective
   - Near-zero request path overhead

### Phase 4: Production Configuration
```bash
# High-throughput services (>1000 req/s)
export ENABLE_TIMING=true
export ENABLE_PERF=true
export LOG_VERBOSE=false        # Skip intermediate logs
export LOG_SAMPLE_RATE=10       # Log every 10th request

# Low-latency services (<100μs processing)
export ENABLE_TIMING=true
export ENABLE_PERF=false        # Disable perf to reduce overhead
export LOG_SAMPLE_RATE=100      # Aggressive sampling

# Debugging/Development
export ENABLE_TIMING=true
export ENABLE_PERF=true
export LOG_VERBOSE=true         # All logs
export LOG_SAMPLE_RATE=1        # No sampling
```

## Measurement Plan

### Benchmark Setup
1. Deploy hotelReservation with ENABLE_PERF=false (baseline)
2. Run workload for 5 minutes, measure latencies
3. Deploy with ENABLE_PERF=true
4. Run same workload, measure latencies
5. Compare p50, p95, p99, max latencies

### Expected Results
- **If overhead < 1%**: Accept current implementation
- **If overhead 1-3%**: Implement Phase 3 optimizations (reduce verbosity)
- **If overhead > 3%**: Implement Phase 3 optimizations (sampling or async)

### Benchmark Command
```bash
# Baseline (no perf)
ENABLE_TIMING=true ENABLE_PERF=false ./run_experiment.sh

# With perf
ENABLE_TIMING=true ENABLE_PERF=true PERF_EVENTS="basic" ./run_experiment.sh

# Compare results
python3 analyze_latency.py --baseline baseline.json --test perf_enabled.json
```

## Alternative: File-Based Logging

Instead of stdout logging, write to dedicated files:

```go
// Open per-request perf file
perfFile, _ := os.OpenFile("perf_data.ndjson", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
defer perfFile.Close()

// Write JSON line
json.NewEncoder(perfFile).Encode(timingData)
```

**Benefits**:
- Potentially faster than stdout (no terminal overhead)
- Easier to parse (one JSON object per line)
- Can use buffered I/O

**Drawbacks**:
- File I/O can still be expensive
- File descriptor management
- Log rotation complexity

## Monitoring Logging Overhead

Add metrics to track logging overhead:

```go
// In interceptor
loggingStart := time.Now()
log.Info()...Msg(...)
loggingDuration := time.Since(loggingStart)

// Periodically report
if loggingDuration > time.Microsecond * 10 {
    log.Warn().Dur("logging_overhead", loggingDuration).Msg("High logging overhead detected")
}
```

## Conclusion

1. **Current estimate**: ~12-34μs overhead per request
2. **Acceptable for**: Services with >1ms processing time (< 3% overhead)
3. **Measure first**: Run benchmarks to validate actual overhead
4. **Optimize if needed**: Implement sampling or async logging
5. **Configuration**: Make logging verbosity configurable via env vars

## Next Steps

1. ✅ Implement full perf+timing integration
2. ⏳ Run overhead benchmarks
3. ⏳ Implement sampling if needed
4. ⏳ Document findings in experiment results
5. ⏳ Adjust default configuration based on measurements

