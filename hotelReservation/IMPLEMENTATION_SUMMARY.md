# Perf Instrumentation Implementation Summary

## What Was Implemented

### 1. Enhanced Performance Counter API (`services/perf/perf_api.{c,h}`)

**Changes:**
- Removed unused event category comments
- Added `struct perf_values` to store counter readings
- Added `perf_pause()` - Stop counting, return current values
- Added `perf_resume()` - Resume counting without reset
- Added `perf_read()` - Read values without stopping
- Added `perf_delta()` - Calculate difference between readings
- Added `perf_values_to_json()` - Format as JSON string
- Updated `perf_stop()` to return `struct perf_values`

**Supported Events:**
- cycles, instructions, cache_references, cache_misses
- branch_instructions, branch_misses, bus_cycles
- l1_loads, l1_misses, llc_loads, llc_load_misses
- context_switches, page_faults, cpu_migrations

**Predefined Event Sets:**
- basic: cycles, instructions, cache_references, cache_misses
- cpu: cycles, instructions, branch_instructions, branch_misses
- memory: cache_references, cache_misses, l1_loads, l1_misses, llc_loads, llc_load_misses
- scheduling: context_switches, cpu_migrations, page_faults
- bandwidth: cycles, instructions, cache_references, cache_misses, bus_cycles
- interference: cycles, instructions, cache_misses, context_switches, page_faults, l1_misses

### 2. Integrated Perf into Timing Interceptor (`interceptor/timing_interceptor.go`)

**Key Features:**
- **Two sets of perf counters per request:**
  - `PerfTotal`: Full request lifetime (including blocking on downstream calls)
  - `PerfExecution`: Service execution only (excluding blocking time)

- **Pause/Resume Mechanism:**
  - Counters pause when first downstream call starts
  - Counters resume when all downstream calls complete
  - Handles nested downstream calls correctly

- **Configuration:**
  ```go
  type TimingConfig struct {
      EnableTiming bool
      EnablePerf   bool     // Enable perf instrumentation
      PerfEvents   string   // Event set: "basic", "cpu", "memory", etc.
      ServiceName  string
      StatsFile    string
  }
  ```

- **Logging Output:**
  ```json
  {
    "method": "/service/Method",
    "service": "srv-service",
    "processing_time_ms": 5.2,
    "total_time_ms": 8.4,
    "blocking_time_ms": 3.2,
    "perf_total": {
      "cycles": 1234567,
      "instructions": 987654,
      "cache_misses": 1234
    },
    "perf_execution": {
      "cycles": 789012,
      "instructions": 654321,
      "cache_misses": 456
    }
  }
  ```

### 3. Updated Interceptor Options (`interceptor/options.go`)

**Changes:**
- Removed separate `PerfConfig` struct
- Perf configuration now part of `TimingConfig`
- Simplified `ServerOptions` structure
- Single unified interceptor instead of chain

### 4. Removed Standalone Perf Interceptor

**Deleted:** `interceptor/perf_interceptor.go`
**Reason:** Functionality merged into `timing_interceptor.go` for lower overhead

### 5. Updated Data Collection (`noisy-neighbors/data-collector.sh`)

**Changes:**
- Commented out external SSH-based perf monitoring
- Using per-request instrumentation from application logs
- Updated `start_monitoring()` to skip external monitoring
- Updated `retrieve_perf_data_from_logs()` to extract per-request data
- Added aggregation of both total and execution perf counters

## Usage

### Service Configuration

Update service (e.g., `services/attractions/server.go`):

```go
// Configure timing + perf interceptor
enableTiming := os.Getenv("ENABLE_TIMING") == "true"
enablePerf := os.Getenv("ENABLE_PERF") == "true"
perfEvents := os.Getenv("PERF_EVENTS")
if perfEvents == "" {
    perfEvents = "basic"
}
statsFile := os.Getenv("STATS_FILE")
if statsFile == "" {
    statsFile = "timing_stats_service.json"
}

timingConfig := interceptor.TimingConfig{
    EnableTiming: enableTiming,
    EnablePerf:   enablePerf,
    PerfEvents:   perfEvents,
    ServiceName:  name,
    StatsFile:    statsFile,
}

serverOpts := interceptor.ServerOptions{
    TimingConfig: timingConfig,
    Tracer:       s.Tracer,
}

opts := []grpc.ServerOption{
    grpc.KeepaliveParams(keepalive.ServerParameters{
        Timeout: 120 * time.Second,
    }),
    grpc.KeepaliveEnforcementPolicy(keepalive.EnforcementPolicy{
        PermitWithoutStream: true,
    }),
    serverOpts.GetServerInterceptor(),
}
```

### Environment Variables

```bash
# Enable timing and perf instrumentation
export ENABLE_TIMING=true
export ENABLE_PERF=true
export PERF_EVENTS="interference"  # or "basic", "cpu", "memory", etc.

# Custom event list
export PERF_EVENTS="cycles,instructions,cache_misses,context_switches"
```

### Data Collection

```bash
# Run experiment (per-request data collected automatically)
./data-collector.sh config.sh

# Extract per-request perf data
cat experiment_dir/raw/perf/logs/service_perf_iter1.json

# View aggregated data
cat experiment_dir/processed/per_request_perf_summary.txt
```

## Design Rationale

### Why Integrate Perf into Timing Interceptor?

1. **Lower Overhead**: Single interceptor instead of chain
2. **Better Correlation**: Timing and perf data together
3. **Pause/Resume**: Shared pause/resume logic for both time and counters
4. **Simpler Configuration**: One config structure

### Why Two Sets of Counters?

1. **Total counters** show overall resource consumption including contention
2. **Execution counters** show service's actual work excluding blocking
3. Difference reveals impact of downstream dependencies and contention

**Example:**
```
Total cycles: 10,000,000 (entire request)
Execution cycles: 4,000,000 (service work only)
Difference: 6,000,000 (blocking on downstream + contention)
```

### Why Pause/Resume Instead of Start/Stop?

1. Continues counting from where it left off
2. Accumulates execution time across multiple pause/resume cycles
3. Handles nested downstream calls correctly
4. Mirrors timing interceptor behavior

## Log Format

### Request Completion Log

```json
{
  "level": "info",
  "method": "/attractions.Attractions/NearbyRest",
  "service": "srv-attractions",
  "downstream_calls": 2,
  "active_calls_at_end": 0,
  "total_time": "8.4ms",
  "processing_time": "5.2ms",
  "blocking_time": "3.2ms",
  "processing_time_ms": 5.2,
  "total_time_ms": 8.4,
  "blocking_time_ms": 3.2,
  "perf_total": {
    "cycles": 10000000,
    "instructions": 8000000,
    "cache_misses": 5000,
    "context_switches": 2,
    "page_faults": 0
  },
  "perf_execution": {
    "cycles": 4000000,
    "instructions": 3200000,
    "cache_misses": 2000,
    "context_switches": 0,
    "page_faults": 0
  },
  "perf_data_type": "request_timing_perf",
  "time": "2025-11-05T10:15:30Z",
  "message": "gRPC call completed"
}
```

### Extracting Perf Data

```bash
# Extract all perf data
kubectl logs service-pod | grep "perf_data_type.*request_timing_perf"

# Extract specific events
kubectl logs service-pod | grep "perf_data_type.*request_timing_perf" | \
  jq '.perf_execution.cache_misses'

# Average execution cycles per method
kubectl logs service-pod | grep "perf_data_type.*request_timing_perf" | \
  jq -r 'select(.method == "/service/Method") | .perf_execution.cycles' | \
  awk '{sum+=$1; count++} END {print sum/count}'
```

## Known Issues & Limitations

1. **Logging Overhead**: ~12-34μs per request (see LOGGING_OVERHEAD_ANALYSIS.md)
2. **Memory**: Storing perf handles in context requires ~200 bytes per request
3. **Thread Safety**: Uses uintptr for atomic operations (careful with GC)
4. **Perf Permissions**: Requires CAP_SYS_ADMIN or perf_event_paranoid=-1

## Next Steps

1. **Test end-to-end** with real workload
2. **Measure logging overhead** (run benchmarks)
3. **Update remaining services** (profile, rate, reservation, etc.)
4. **Optimize if needed** (sampling, async logging)
5. **Document findings** in experiment results

## Files Modified

1. `services/perf/perf_api.h` - Added pause/resume/delta functions
2. `services/perf/perf_api.c` - Implemented new functions, removed categories
3. `interceptor/timing_interceptor.go` - Integrated perf instrumentation
4. `interceptor/options.go` - Simplified configuration
5. `noisy-neighbors/data-collector.sh` - Commented out external monitoring
6. `services/attractions/server.go` - Example service update (NEEDS UPDATE)

## Files Created

1. `PERF_INSTRUMENTATION_UPDATES.md` - Detailed implementation plan
2. `LOGGING_OVERHEAD_ANALYSIS.md` - Logging overhead analysis
3. `IMPLEMENTATION_SUMMARY.md` - This file

## Files Deleted

1. `interceptor/perf_interceptor.go` - Merged into timing_interceptor.go

