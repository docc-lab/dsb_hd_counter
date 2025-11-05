# Complete Changelog: Per-Request Performance Counter Instrumentation

## Session Overview

This document chronicles the complete implementation of per-request performance counter instrumentation for the HotelReservation microservices application, including initial design, feedback, and final implementation.

---

## Part 1: Understanding the Existing System

### Initial Analysis

**Existing Performance Instrumentation (Before Changes):**

1. **Manual per-method instrumentation** in service files:
   ```go
   var cHandles C.struct_perf_handles
   if span := opentracing.SpanFromContext(ctx); span != nil {
       cHandles = C.perf_start()
   }
   // ... method logic ...
   if span := opentracing.SpanFromContext(ctx); span != nil {
       counterResults := C.GoString(C.perf_stop(...))
       span.SetTag("Machine Counter Readings", counterResults)
   }
   ```

2. **Hardcoded 3 events** in `perf_api.c`:
   - cycles
   - instructions
   - l1_misses

3. **String-based output format**:
   ```c
   "cycles=1234567, instructions=987654, l1_misses=1234"
   ```

4. **OpenTracing span tags** for output

5. **External SSH-based monitoring** via `service-monitor.sh`:
   - SSH into nodes
   - Attach `perf stat` to container PIDs
   - Collect aggregated metrics per service

**Existing Timing Instrumentation:**

1. **gRPC interceptors** for timing:
   - Server interceptor: tracks arrival time, total time
   - Client interceptor: tracks blocking time on downstream calls
   - **Pause/resume mechanism**: pauses timer during downstream calls

2. **Three time metrics per request**:
   - Total time (entire request)
   - Processing time (excluding blocking)
   - Blocking time (waiting for downstream)

3. **Structured logging** via zerolog

---

## Part 2: Initial Implementation

### Goals

1. Add more perf events (configurable)
2. Make perf event selection configurable via environment variables
3. Implement per-request perf instrumentation via interceptor
4. Move from OpenTracing span tags to structured logging
5. Integrate with data-collector.sh

### Initial Changes Made

#### 1. Enhanced `perf_api.c` and `perf_api.h`

**Added support for 16+ events:**
- Hardware: cycles, instructions, cache_references, cache_misses, branch_instructions, branch_misses, bus_cycles
- Cache: l1_loads, l1_misses, llc_loads, llc_load_misses
- Software: context_switches, page_faults, cpu_migrations

**Added predefined event sets:**
- basic: cycles, instructions, cache_references, cache_misses
- cpu: cycles, instructions, branch_instructions, branch_misses
- memory: cache_references, cache_misses, l1_loads, l1_misses, llc_loads, llc_load_misses
- scheduling: context_switches, cpu_migrations, page_faults
- bandwidth: cycles, instructions, cache_references, cache_misses, bus_cycles
- interference: cycles, instructions, cache_misses, context_switches, page_faults, l1_misses

**Key functions:**
```c
int perf_init(const char* config);  // Configure events
struct perf_handles perf_start();  // Start counting
const char* perf_stop(...);         // Stop and return JSON
```

#### 2. Created `interceptor/perf_interceptor.go`

**Automatic per-request instrumentation:**
```go
type PerfConfig struct {
    EnablePerf  bool
    ServiceName string
    PerfEvents  string
}

func PerfServerInterceptor(config PerfConfig) grpc.UnaryServerInterceptor {
    // Initialize perf events once
    C.perf_init(cConfig)
    
    return func(...) {
        cHandles := C.perf_start()
        resp, err := handler(ctx, req)
        cResult := C.perf_stop(&cHandles)
        log.Info().Interface("perf_events", perfValues).Msg("Perf counters")
        return resp, err
    }
}
```

#### 3. Updated `interceptor/options.go`

Added `PerfConfig` to `ServerOptions`:
```go
type ServerOptions struct {
    TimingConfig TimingConfig
    PerfConfig   PerfConfig  // NEW
    Tracer       opentracing.Tracer
}
```

#### 4. Updated Service Example (`attractions`)

```go
perfConfig := interceptor.PerfConfig{
    EnablePerf:  enablePerf,
    ServiceName: name,
    PerfEvents:  perfEvents,
}

serverOpts := interceptor.ServerOptions{
    PerfConfig: perfConfig,
    Tracer:     s.Tracer,
}
```

Removed all manual `perf_start()/perf_stop()` calls from methods.

#### 5. Updated `data-collector.sh`

Added `retrieve_perf_data_from_logs()` function to extract perf data from application logs.

---

## Part 3: Critical Feedback and Required Changes

### User Feedback

1. **❌ Event categories not needed** - Remove comments like "// Hardware events"

2. **❌ Missing pause/resume for perf counters** - Need to exclude blocking time like timing interceptor does

3. **❌ Need TWO sets of perf counters:**
   - Total: All perf events during entire request (including blocking)
   - Execution: Perf events only during service execution (excluding blocking)
   - Rationale: Understand contention impact and service vs. blocking resource usage

4. **❌ Separate interceptor has overhead** - Should integrate into existing timing interceptor

5. **❌ External monitoring should be commented out** - Using per-request data now

6. **⚠️ Logging overhead concerns** - Need to investigate and document

### Why These Changes Matter

**Problem with initial design:**
```
Request arrives → Start perf → Call downstream → Wait (blocking) → Return → Stop perf

Perf counters include:
- Service execution time ✓
- Blocking time waiting for downstream ✓  (UNWANTED!)
- Contention from other services ✓  (MIXED IN, CAN'T SEPARATE!)
```

**With pause/resume:**
```
Request arrives → Start perf → [Service work] → 
Pause perf → Call downstream → Wait → 
Resume perf → [More service work] → Stop perf

Now we have TWO measurements:
- perf_total: Service + Blocking + Contention (understand overall pressure)
- perf_execution: Service only (understand actual work without blocking)
- Delta: Blocking + Contention impact
```

---

## Part 4: Final Implementation

### Major Changes

#### 1. Enhanced `perf_api.c` - Added Pause/Resume Support

**Removed:**
- Event category comments (unnecessary)

**Added new structures and functions:**
```c
struct perf_values {
    int num_events;
    long long values[MAX_PERF_EVENTS];
    char event_names[MAX_PERF_EVENTS][64];
};

struct perf_values perf_pause(struct perf_handles* handles);
struct perf_handles perf_resume(struct perf_handles* handles);
struct perf_values perf_read(struct perf_handles* handles);
struct perf_values perf_stop(struct perf_handles* handles);
const char* perf_values_to_json(struct perf_values* values);
struct perf_values perf_delta(struct perf_values* start, struct perf_values* end);
```

**Key behaviors:**
- `perf_pause()`: Stops counting, returns current values
- `perf_resume()`: Continues counting from where it left off (NO RESET)
- `perf_delta()`: Calculates difference between two readings
- Thread-safe with thread-local storage

#### 2. Merged Perf into Timing Interceptor

**Deleted:** `interceptor/perf_interceptor.go`

**Updated:** `interceptor/timing_interceptor.go`

**Added to `TimingConfig`:**
```go
type TimingConfig struct {
    EnableTiming bool
    EnablePerf   bool     // NEW
    PerfEvents   string   // NEW
    ServiceName  string
    StatsFile    string
}
```

**Added to `TimingData`:**
```go
type TimingData struct {
    // ... existing fields ...
    PerfTotal     map[string]int64  // NEW: Total counters (with blocking)
    PerfExecution map[string]int64  // NEW: Execution counters (no blocking)
}
```

**Added to `timingContext`:**
```go
type timingContext struct {
    // ... existing timing fields ...
    perfHandles        uintptr  // *C.struct_perf_handles
    perfStartValues    uintptr  // *C.struct_perf_values
    perfAccumExecution uintptr  // *C.struct_perf_values (accumulated)
    perfEnabled        int32    // atomic flag
}
```

**Server Interceptor Logic:**
```go
func TimingServerInterceptor(config TimingConfig) grpc.UnaryServerInterceptor {
    // Initialize perf events once
    if config.EnablePerf {
        C.perf_init(cConfig)
    }
    
    return func(...) {
        // Start timing
        arrivalTime := time.Now()
        
        // Start perf counters
        if config.EnablePerf {
            cHandles := C.perf_start()
            timingCtx.perfHandles = uintptr(unsafe.Pointer(&cHandles))
            cStartValues := C.perf_read(&cHandles)
            timingCtx.perfStartValues = uintptr(unsafe.Pointer(&cStartValues))
            timingCtx.perfAccumExecution = uintptr(unsafe.Pointer(&cStartValues))
        }
        
        // Call handler
        resp, err := handler(ctx, req)
        
        // Stop perf counters
        if config.EnablePerf {
            cEndValues := C.perf_stop(cHandles)
            
            // Total delta: end - start
            cTotalDelta := C.perf_delta(cStartValues, &cEndValues)
            timingData.PerfTotal = cPerfValuesToMap(&cTotalDelta)
            
            // Execution delta: accumulated execution time (no blocking)
            cExecutionDelta := C.perf_delta(cAccumExec, &cEndValues)
            timingData.PerfExecution = cPerfValuesToMap(&cExecutionDelta)
        }
        
        // Log with perf data
        log.Info().
            Interface("perf_total", timingData.PerfTotal).
            Interface("perf_execution", timingData.PerfExecution).
            Msg("gRPC call completed")
    }
}
```

**Client Interceptor Logic (Pause/Resume):**
```go
func TimingClientInterceptor() grpc.UnaryClientInterceptor {
    return func(...) {
        oldCount := atomic.AddInt32(&timingCtx.activeCallCount, 1) - 1
        
        if oldCount == 0 {
            // First downstream call - START BLOCKING
            
            // Pause timing
            pauseStartNs := time.Now().UnixNano()
            atomic.StoreInt64(&timingCtx.pauseStartTimeNs, pauseStartNs)
            
            // Pause perf counters and accumulate execution time
            if perfEnabled {
                cPausedValues := C.perf_pause(cHandles)
                cLastAccum := timingCtx.perfAccumExecution
                cDelta := C.perf_delta(cLastAccum, &cPausedValues)
                timingCtx.perfAccumExecution = uintptr(unsafe.Pointer(&cDelta))
            }
        }
        
        // Make blocking call
        err := invoker(ctx, method, req, reply, cc, opts...)
        
        newCount := atomic.AddInt32(&timingCtx.activeCallCount, -1)
        
        if newCount == 0 {
            // All downstream calls complete - END BLOCKING
            
            // Resume timing
            blockingDurationNs := time.Now().UnixNano() - pauseStartNs
            atomic.AddInt64(&timingCtx.totalPausedTimeNs, blockingDurationNs)
            
            // Resume perf counters
            if perfEnabled {
                C.perf_resume(cHandles)
            }
        }
        
        return err
    }
}
```

#### 3. Updated `interceptor/options.go`

**Removed `PerfConfig` struct** - now part of `TimingConfig`

```go
type ServerOptions struct {
    TimingConfig TimingConfig  // Includes perf config now
    Tracer       opentracing.Tracer
}

func (opts ServerOptions) GetServerInterceptor() grpc.ServerOption {
    return grpc.UnaryInterceptor(
        ChainUnaryServerInterceptors(
            otgrpc.OpenTracingServerInterceptor(opts.Tracer),
            TimingServerInterceptor(opts.TimingConfig),  // Includes perf
        ),
    )
}
```

#### 4. Updated `data-collector.sh`

**Commented out external SSH-based monitoring:**
```bash
start_monitoring() {
    log "$exp_dir" "Per-request perf instrumentation enabled"
    log "$exp_dir" "External SSH-based perf monitoring is disabled"
    
    # OLD CODE (commented out):
    # for service in $services; do
    #     "$MONITOR_SCRIPT" "$service" default "$duration" "$counter_set" ...
    # done
    
    echo ""  # Return empty array
}
```

**Updated iteration logic:**
```bash
run_iteration() {
    # OLD: local monitor_pids=($(start_monitoring ...))
    # NEW:
    log "$exp_dir" "Per-request perf instrumentation active"
    local monitor_pids=()
}
```

#### 5. Service Update Example

**Updated `services/attractions/server.go`:**

```go
// Before:
perfConfig := interceptor.PerfConfig{
    EnablePerf:  enablePerf,
    ServiceName: name,
    PerfEvents:  perfEvents,
}
serverOpts := interceptor.ServerOptions{
    PerfConfig: perfConfig,
    Tracer:     s.Tracer,
}

// After:
timingConfig := interceptor.TimingConfig{
    EnableTiming: enableTiming,
    EnablePerf:   enablePerf,      // Integrated
    PerfEvents:   perfEvents,      // Integrated
    ServiceName:  name,
    StatsFile:    statsFile,
}
serverOpts := interceptor.ServerOptions{
    TimingConfig: timingConfig,    // Single config
    Tracer:       s.Tracer,
}
```

Removed all manual perf instrumentation from methods.

---

## Part 5: Documentation Created

### 1. `PERF_INSTRUMENTATION_UPDATES.md`

Detailed implementation plan with pseudocode showing:
- Pause/resume mechanism
- Two sets of counters
- Integration into timing interceptor
- Data collection updates

### 2. `LOGGING_OVERHEAD_ANALYSIS.md`

Comprehensive analysis including:

**Overhead Estimates:**
- Request with no downstream calls: ~6-9μs
- Request with 2 downstream calls: ~12-19μs
- Request with 5 downstream calls: ~21-34μs

**Risk Assessment:**
| Request Processing Time | Overhead % |
|------------------------|------------|
| 100μs                  | 12-19%     |
| 500μs                  | 2.4-3.8%   |
| 1ms                    | 1.2-1.9%   |
| 5ms                    | 0.24-0.38% |
| 10ms                   | 0.12-0.19% |

**Mitigation Strategies:**
1. Conditional logging (implemented)
2. Sampling (if needed)
3. Batch buffered logging (if needed)
4. Async logging (if needed)
5. Reduce log verbosity (if needed)

**Recommended Approach:**
- Phase 1: Full logging (current)
- Phase 2: Measure actual overhead
- Phase 3: Optimize if needed (>2% overhead)
- Phase 4: Production configuration by service type

### 3. `IMPLEMENTATION_SUMMARY.md`

Complete summary including:
- All changes made
- Design rationale
- Usage instructions
- Log format examples
- Known issues and limitations
- Next steps

### 4. Updated `services/perf/README.md`

Comprehensive documentation (459 lines) covering:
- Overview of the system
- Detailed changes summary
- Architecture diagram
- Design decisions
- Complete usage guide
- Configuration options
- Data collection integration
- Analysis examples
- Troubleshooting
- References

---

## Key Design Decisions

### 1. Why Integrate Perf into Timing Interceptor?

**Advantages:**
- ✅ Single interceptor = lower overhead
- ✅ Timing and perf data correlated
- ✅ Shared pause/resume logic
- ✅ Simpler configuration
- ✅ One log entry with all data

**Alternative Considered:**
- Separate perf interceptor chained with timing interceptor
- Rejected: Higher overhead, harder to correlate data

### 2. Why Two Sets of Perf Counters?

**Use Case:**
```
Service processes request in 5ms total:
- 2ms: Own processing (execution)
- 3ms: Waiting for downstream calls (blocking)

perf_total shows:
- cycles: 10,000,000 (entire 5ms)
- cache_misses: 5,000

perf_execution shows:
- cycles: 4,000,000 (just 2ms execution)
- cache_misses: 2,000

Analysis:
- Own work: 4M cycles, 2K cache misses
- Blocking impact: 6M cycles, 3K cache misses
- Contention visible in blocking delta
```

**Insight:** Separate service's actual work from blocking/contention effects

### 3. Why Pause/Resume Instead of Separate Measurements?

**Pause/Resume (Chosen):**
```
Start → Work(1ms) → Pause → Block(3ms) → Resume → Work(1ms) → Stop
Total: 10M cycles
Execution: 4M cycles (1ms + 1ms work)
```

**Separate Measurements (Rejected):**
```
Start → Work(1ms) → Stop [2M cycles]
  Block(3ms) [not measured]
Start → Work(1ms) → Stop [2M cycles]

Problem: Can't accumulate, miss overall context
```

### 4. Why Structured Logging Instead of OpenTracing Spans?

**Structured Logs (Chosen):**
```json
{
  "level": "info",
  "perf_execution": {"cycles": 4000000},
  "message": "request completed"
}
```
- ✅ Easy to grep/jq/parse
- ✅ Better for high-frequency data
- ✅ Log collectors can aggregate
- ✅ No trace sampling issues

**OpenTracing Spans (Original):**
```go
span.SetTag("Machine Counter Readings", "cycles=1234567...")
```
- ❌ String parsing required
- ❌ Lost if span not sampled
- ❌ Harder to aggregate
- ❌ Not designed for high-cardinality data

---

## Files Modified/Created/Deleted

### Modified Files

1. **`services/perf/perf_api.h`**
   - Added `struct perf_values`
   - Added pause/resume/read/delta function declarations

2. **`services/perf/perf_api.c`**
   - Removed event category comments
   - Implemented pause/resume/read/delta functions
   - Changed return types from string to struct

3. **`interceptor/timing_interceptor.go`**
   - Added CGO imports
   - Added perf fields to `TimingConfig`, `TimingData`, `timingContext`
   - Integrated perf start/stop in server interceptor
   - Added pause/resume in client interceptor
   - Added `cPerfValuesToMap()` helper function

4. **`interceptor/options.go`**
   - Removed `PerfConfig` struct
   - Simplified `ServerOptions`
   - Updated documentation

5. **`services/attractions/server.go`**
   - Updated to use integrated `TimingConfig`
   - Removed manual perf instrumentation from methods
   - Removed CGO imports and `PerfHandles` struct

6. **`noisy-neighbors/data-collector.sh`**
   - Commented out external SSH monitoring in `start_monitoring()`
   - Updated `run_iteration()` to skip external monitoring
   - Enhanced `retrieve_perf_data_from_logs()`
   - Updated aggregation to handle per-request perf data

### Created Files

1. **`PERF_INSTRUMENTATION_UPDATES.md`**
   - Detailed implementation plan
   - Complete pseudocode examples
   - Testing checklist
   - Open questions

2. **`LOGGING_OVERHEAD_ANALYSIS.md`**
   - Overhead estimates and calculations
   - Risk assessment framework
   - Mitigation strategies
   - Measurement plan
   - Configuration recommendations

3. **`IMPLEMENTATION_SUMMARY.md`**
   - Complete implementation summary
   - Design rationale
   - Usage guide
   - Known issues
   - Next steps

4. **`services/perf/README.md`**
   - Comprehensive 459-line documentation
   - Architecture diagrams
   - Usage examples
   - Troubleshooting guide

### Deleted Files

1. **`interceptor/perf_interceptor.go`**
   - Reason: Functionality merged into `timing_interceptor.go`
   - Benefit: Lower overhead, better integration

---

## Configuration and Usage

### Environment Variables

```bash
# Enable timing and perf instrumentation
export ENABLE_TIMING=true
export ENABLE_PERF=true

# Choose event set
export PERF_EVENTS="interference"  # or "basic", "cpu", "memory", "scheduling", "bandwidth"

# Or custom events
export PERF_EVENTS="cycles,instructions,cache_misses,context_switches"

# Stats file location
export STATS_FILE="timing_stats_service.json"
```

### Service Code Pattern

```go
func (s *Server) Run() error {
    // Read configuration
    enableTiming := os.Getenv("ENABLE_TIMING") == "true"
    enablePerf := os.Getenv("ENABLE_PERF") == "true"
    perfEvents := os.Getenv("PERF_EVENTS")
    if perfEvents == "" {
        perfEvents = "basic"
    }
    
    // Configure interceptor
    timingConfig := interceptor.TimingConfig{
        EnableTiming: enableTiming,
        EnablePerf:   enablePerf,
        PerfEvents:   perfEvents,
        ServiceName:  name,
        StatsFile:    "timing_stats_" + name + ".json",
    }
    
    serverOpts := interceptor.ServerOptions{
        TimingConfig: timingConfig,
        Tracer:       s.Tracer,
    }
    
    // Create server with interceptor
    opts := []grpc.ServerOption{
        grpc.KeepaliveParams(...),
        grpc.KeepaliveEnforcementPolicy(...),
        serverOpts.GetServerInterceptor(),
    }
    
    srv := grpc.NewServer(opts...)
    // ... rest of setup
}
```

### Log Output Format

```json
{
  "level": "info",
  "method": "/service.Service/Method",
  "service": "srv-service",
  "downstream_calls": 2,
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
    "context_switches": 2
  },
  "perf_execution": {
    "cycles": 4000000,
    "instructions": 3200000,
    "cache_misses": 2000,
    "context_switches": 0
  },
  "perf_data_type": "request_timing_perf",
  "time": "2025-11-05T10:15:30Z",
  "message": "gRPC call completed"
}
```

### Data Analysis

```bash
# Extract all perf data
kubectl logs service-pod | grep "perf_data_type.*request_timing_perf"

# Get average execution cycles
kubectl logs service-pod | \
  grep "perf_data_type.*request_timing_perf" | \
  jq -r '.perf_execution.cycles' | \
  awk '{sum+=$1; count++} END {print sum/count}'

# Find requests with high cache misses
kubectl logs service-pod | \
  grep "perf_data_type.*request_timing_perf" | \
  jq 'select(.perf_execution.cache_misses > 10000)'

# Compare total vs execution for contention analysis
kubectl logs service-pod | \
  grep "perf_data_type.*request_timing_perf" | \
  jq '{method, total_cycles: .perf_total.cycles, exec_cycles: .perf_execution.cycles, contention: (.perf_total.cycles - .perf_execution.cycles)}'
```

---

## Validation and Testing

### What to Verify

1. **Two counter sets are different:**
   ```bash
   # perf_total should be > perf_execution
   kubectl logs pod | grep perf_data_type | jq '{total: .perf_total.cycles, exec: .perf_execution.cycles, diff: (.perf_total.cycles - .perf_execution.cycles)}'
   ```

2. **Delta correlates with blocking time:**
   ```bash
   # cycles_delta should roughly correlate with blocking_time_ms
   kubectl logs pod | grep perf_data_type | jq '{blocking_ms: .blocking_time_ms, cycles_delta: (.perf_total.cycles - .perf_execution.cycles)}'
   ```

3. **Nested calls handled correctly:**
   - Test service with multiple downstream calls
   - Verify pause/resume happens only at stack boundaries (0→1 and 1→0)

4. **Logging overhead acceptable:**
   ```bash
   # Compare p95 latency with and without perf
   ENABLE_PERF=false ./benchmark.sh > baseline.txt
   ENABLE_PERF=true ./benchmark.sh > with_perf.txt
   # Analyze difference
   ```

### Known Limitations

1. **Perf permissions**: Requires `CAP_SYS_ADMIN` or `perf_event_paranoid=-1`
2. **Thread-local storage**: Each goroutine gets separate counters (intended)
3. **Logging overhead**: ~12-34μs per request (acceptable for >1ms requests)
4. **Memory**: ~200 bytes per request for perf handles
5. **CGO overhead**: ~100ns per CGO call (6-8 calls per request)

---

## Next Steps

### Immediate (Required)

1. ✅ **DONE**: Implement pause/resume in perf_api.c
2. ✅ **DONE**: Integrate perf into timing interceptor
3. ✅ **DONE**: Update data-collector.sh
4. ✅ **DONE**: Document logging overhead
5. ⏳ **TODO**: Update remaining services (profile, rate, reservation, geo, review, recommendation, search, user, frontend)

### Short-term (Testing)

1. ⏳ **TODO**: Build and test with CGO
2. ⏳ **TODO**: Run end-to-end experiment
3. ⏳ **TODO**: Measure actual logging overhead
4. ⏳ **TODO**: Validate perf counter accuracy
5. ⏳ **TODO**: Verify pause/resume with nested calls

### Medium-term (Optimization)

1. ⏳ **TODO**: Implement sampling if overhead > 2%
2. ⏳ **TODO**: Add configuration for log verbosity
3. ⏳ **TODO**: Create analysis scripts for per-request data
4. ⏳ **TODO**: Add perf data to timing stats aggregation

### Long-term (Enhancement)

1. ⏳ **TODO**: Add more perf events (TLB, stalls, etc.)
2. ⏳ **TODO**: Per-method aggregation statistics
3. ⏳ **TODO**: Real-time anomaly detection
4. ⏳ **TODO**: Visualization tools integration
5. ⏳ **TODO**: Automatic event set selection based on workload

---

## Summary

This session implemented a comprehensive per-request performance counter instrumentation system that:

✅ **Tracks TWO sets of perf counters** (total vs execution-only)  
✅ **Pauses/resumes during blocking** (excludes downstream wait time)  
✅ **Integrates with timing interceptor** (lower overhead)  
✅ **Logs structured data** (easy to analyze)  
✅ **Configurable via environment** (runtime flexibility)  
✅ **Supports 16+ perf events** (comprehensive coverage)  
✅ **Documents logging overhead** (informed decisions)  
✅ **Maintains backward compatibility** (can disable)  

**Key Innovation:** Separating service execution from blocking/contention effects by maintaining two counter sets with pause/resume mechanism, enabling precise analysis of resource consumption patterns.

**Impact:** Enables researchers to understand not just that a service is slow, but WHY - distinguishing between:
- Service's own inefficiencies (execution counters)
- Impact of waiting for dependencies (blocking time)
- System-wide contention effects (total - execution delta)

---

## Appendix: Complete File Listing

### Source Code Files
- `services/perf/perf_api.h` (49 lines)
- `services/perf/perf_api.c` (353 lines)
- `interceptor/timing_interceptor.go` (643 lines)
- `interceptor/options.go` (35 lines)
- `services/attractions/server.go` (updated)

### Documentation Files
- `PERF_INSTRUMENTATION_UPDATES.md` (488 lines)
- `LOGGING_OVERHEAD_ANALYSIS.md` (400+ lines)
- `IMPLEMENTATION_SUMMARY.md` (380+ lines)
- `services/perf/README.md` (459 lines)
- `PERF_INSTRUMENTATION_COMPLETE_CHANGELOG.md` (this file)

### Scripts
- `noisy-neighbors/data-collector.sh` (2110 lines, updated)

### Deleted
- `interceptor/perf_interceptor.go` (merged into timing_interceptor.go)

**Total Lines of Code/Documentation Added/Modified: ~5000+ lines**

