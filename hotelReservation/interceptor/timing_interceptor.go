package interceptor

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
)

/*
#cgo CFLAGS: -I../services/perf
#cgo LDFLAGS: -L../services/perf -lperf_api
#include <stdlib.h>
#include "../services/perf/perf_api.h"
*/
import "C"

// TimingConfig holds configuration for timing interceptor
type TimingConfig struct {
	EnableTiming bool
	EnablePerf   bool     // Enable perf counter instrumentation
	PerfEvents   string   // Perf events to monitor (e.g., "basic", "interference", or custom list)
	ServiceName  string
	StatsFile    string // File to write aggregated statistics (optional)
}

// TimingData represents a single timing measurement
type TimingData struct {
	ServiceName        string                   `json:"service_name"`
	Method             string                   `json:"method"`
	ArrivalTime        time.Time                `json:"arrival_time"`
	ProcessingTime     time.Duration            `json:"processing_time_ns"` // Time spent in actual processing (excluding blocking calls)
	TotalTime          time.Duration            `json:"total_time_ns"`      // Total time including blocking calls
	BlockingTime       time.Duration            `json:"blocking_time_ns"`   // Time spent in blocking calls
	Timestamp          time.Time                `json:"timestamp"`
	PerfTotal          map[string]int64         `json:"perf_total,omitempty"`          // Perf counters for total execution (including blocking)
	PerfExecution      map[string]int64         `json:"perf_execution,omitempty"`      // Perf counters for service execution only (excluding blocking)
}

// TimingStats holds statistics for a service
type TimingStats struct {
	ServiceName      string                    `json:"service_name"`
	TotalRequests    int                       `json:"total_requests"`
	ProcessingStats  DurationStats             `json:"processing_stats"`
	TotalTimeStats   DurationStats             `json:"total_time_stats"`
	BlockingStats    DurationStats             `json:"blocking_stats"`
	MethodBreakdown  map[string]DurationStats  `json:"method_breakdown"`
	Histogram        map[string]int            `json:"histogram_ms"` // Histogram in milliseconds
	LastUpdated      time.Time                 `json:"last_updated"`
}

// DurationStats holds statistical data for durations
type DurationStats struct {
	Min    time.Duration `json:"min_ns"`
	Max    time.Duration `json:"max_ns"`
	Mean   time.Duration `json:"mean_ns"`
	P50    time.Duration `json:"p50_ns"`
	P95    time.Duration `json:"p95_ns"`
	P99    time.Duration `json:"p99_ns"`
	Count  int           `json:"count"`
}

// LocalTimingAggregator handles in-memory timing data aggregation with periodic stats output
type LocalTimingAggregator struct {
	serviceName   string
	statsFile     string
	data          []TimingData
	mu            sync.RWMutex
	lastStatsTime time.Time
	statsInterval time.Duration
}

// NewLocalTimingAggregator creates a new local aggregator instance
func NewLocalTimingAggregator(serviceName, statsFile string) *LocalTimingAggregator {
	return &LocalTimingAggregator{
		serviceName:   serviceName,
		statsFile:     statsFile,
		data:          make([]TimingData, 0),
		lastStatsTime: time.Now(),
		statsInterval: 30 * time.Second, // Write stats every 30 seconds
	}
}

// contextKey is used for storing timing data in context
type contextKey string

const (
	timingDataKey contextKey = "timing_data"
	pauseTimeKey  contextKey = "pause_time"
)

// timingContext holds mutable timing state that can be updated by client interceptors
// Uses lock-free atomic operations for thread-safe updates
type timingContext struct {
	// Stack-based approach: activeCallCount represents the depth of the call stack
	// When 0: service is processing (not blocked)
	// When >0: service is blocked waiting for downstream calls
	activeCallCount   int32  // atomic counter - acts as stack depth
	pauseStartTimeNs  int64  // atomic - nanoseconds when blocking started (0 if not blocking)
	totalPausedTimeNs int64  // atomic - accumulated paused time in nanoseconds
	totalCallCount    int32  // atomic - total number of downstream calls made
	
	// Perf counter tracking (stored as uintptr for atomic operations)
	perfHandles           uintptr // *C.struct_perf_handles
	perfStartValues       uintptr // *C.struct_perf_values (at request start)
	perfAccumExecution    uintptr // *C.struct_perf_values (accumulated execution time counters)
	perfEnabled           int32   // atomic - 1 if perf is enabled, 0 otherwise
}

// Helper function to convert C perf_values to Go map
func cPerfValuesToMap(cValues *C.struct_perf_values) map[string]int64 {
	result := make(map[string]int64)
	if cValues == nil {
		return result
	}
	
	numEvents := int(cValues.num_events)
	for i := 0; i < numEvents && i < C.MAX_PERF_EVENTS; i++ {
		eventName := C.GoString(&cValues.event_names[i][0])
		if eventName == "" {
			continue
		}
		value := int64(cValues.values[i])
		result[eventName] = value
	}
	
	return result
}

// TimingServerInterceptor creates a server-side unary interceptor with local timing functionality
func TimingServerInterceptor(config TimingConfig) grpc.UnaryServerInterceptor {
	if !config.EnableTiming {
		// Return a no-op interceptor if timing is disabled
		return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
			return handler(ctx, req)
		}
	}

	// Initialize perf events if enabled
	if config.EnablePerf {
		perfEvents := config.PerfEvents
		if perfEvents == "" {
			perfEvents = os.Getenv("PERF_EVENTS")
			if perfEvents == "" {
				perfEvents = "basic" // Default
			}
		}
		
		cConfig := C.CString(perfEvents)
		defer C.free(unsafe.Pointer(cConfig))
		
		result := C.perf_init(cConfig)
		if result != 0 {
			log.Error().Str("perf_events", perfEvents).Msg("Failed to initialize perf events, perf disabled")
			config.EnablePerf = false
		} else {
			log.Info().
				Str("service", config.ServiceName).
				Str("perf_events", perfEvents).
				Msg("Perf instrumentation ENABLED")
		}
	}

	// Initialize local aggregator
	aggregator := NewLocalTimingAggregator(config.ServiceName, config.StatsFile)

	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		// Record timestamp when new gRPC call arrives
		arrivalTime := time.Now()
		
		// Initialize timing data in context
		timingData := &TimingData{
			ServiceName: config.ServiceName,
			Method:      info.FullMethod,
			ArrivalTime: arrivalTime,
			Timestamp:   arrivalTime,
		}
		
		// Create mutable timing context that can be updated by client interceptors (lock-free)
		timingCtx := &timingContext{
			activeCallCount:   0,
			pauseStartTimeNs:  0,
			totalPausedTimeNs: 0,
			totalCallCount:    0,
			perfEnabled:       0,
		}
		
		// Start perf counters if enabled
		if config.EnablePerf {
			cHandles := C.perf_start()
			if cHandles.leader_fd >= 0 {
				// Store handles and initial values
				handlesCopy := cHandles
				timingCtx.perfHandles = uintptr(unsafe.Pointer(&handlesCopy))
				
				// Read initial values
				cStartValues := C.perf_read(&handlesCopy)
				startValuesCopy := cStartValues
				timingCtx.perfStartValues = uintptr(unsafe.Pointer(&startValuesCopy))
				
				// Initialize accumulated execution counters to start values
				accumCopy := cStartValues
				timingCtx.perfAccumExecution = uintptr(unsafe.Pointer(&accumCopy))
				
				atomic.StoreInt32(&timingCtx.perfEnabled, 1)
			}
		}
		
		// Store timing data and mutable context for client interceptor to access
		ctx = context.WithValue(ctx, timingDataKey, timingData)
		ctx = context.WithValue(ctx, pauseTimeKey, timingCtx)

		log.Info().
			Str("method", info.FullMethod).
			Str("service", config.ServiceName).
			Time("arrival_time", arrivalTime).
			Float64("blocking_time_ms", 0.0). // Add field for log collection filter
			Msg("gRPC call arrived")

		// Call the actual handler
		resp, err := handler(ctx, req)
		processingEnd := time.Now()

		// Calculate timing metrics
		totalTime := processingEnd.Sub(arrivalTime)
		
		// Get the accumulated paused time from the mutable context (lock-free atomic read)
		pausedTimeNs := atomic.LoadInt64(&timingCtx.totalPausedTimeNs)
		pausedTime := time.Duration(pausedTimeNs)
		blockingCount := atomic.LoadInt32(&timingCtx.totalCallCount)
		activeCount := atomic.LoadInt32(&timingCtx.activeCallCount)
		
		processingTime := totalTime - pausedTime

		// Calculate perf metrics if enabled
		if config.EnablePerf && atomic.LoadInt32(&timingCtx.perfEnabled) == 1 {
			cHandles := (*C.struct_perf_handles)(unsafe.Pointer(timingCtx.perfHandles))
			if cHandles != nil && cHandles.leader_fd >= 0 {
				// Stop counters and get final values
				cEndValues := C.perf_stop(cHandles)
				
				cStartValues := (*C.struct_perf_values)(unsafe.Pointer(timingCtx.perfStartValues))
				cAccumExec := (*C.struct_perf_values)(unsafe.Pointer(timingCtx.perfAccumExecution))
				
				// Calculate total delta: end - start
				cTotalDelta := C.perf_delta(cStartValues, &cEndValues)
				timingData.PerfTotal = cPerfValuesToMap(&cTotalDelta)
				
				// Calculate execution delta: accumulated + (end - lastPause)
				// This gives us total execution time excluding all blocking periods
				cExecutionDelta := C.perf_delta(cAccumExec, &cEndValues)
				timingData.PerfExecution = cPerfValuesToMap(&cExecutionDelta)
			}
		}

		// Update timing data
		timingData.TotalTime = totalTime
		timingData.ProcessingTime = processingTime
		timingData.BlockingTime = pausedTime

		// Log detailed timing information for this request
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
			Float64("blocking_time_ms", float64(pausedTime.Nanoseconds())/1000000)
		
		// Add perf data if perf is enabled (even if values are -1 or empty)
		if config.EnablePerf {
			logEvent = logEvent.
				Interface("perf_total", timingData.PerfTotal).
				Interface("perf_execution", timingData.PerfExecution).
				Str("perf_data_type", "request_timing_perf")
		}
		
		logEvent.Msg("gRPC call completed")

		// Add timing data to in-memory aggregator
		aggregator.AddTimingData(*timingData)

		// Periodically write stats to file (non-blocking)
		if config.StatsFile != "" {
			go aggregator.MaybeWriteStats()
		}

		return resp, err
	}
}

// TimingClientInterceptor creates a client-side unary interceptor that pauses timing during blocking calls
// Uses lock-free atomic operations with a stack-based approach:
// - Push (increment counter) when making a call
// - Pop (decrement counter) when receiving response
// - Empty stack (counter=0) means service is processing (not blocked)
// - Non-empty stack (counter>0) means service is blocked
func TimingClientInterceptor() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		// Check if we have timing context (meaning timing is enabled)
		timingData, hasTimingData := ctx.Value(timingDataKey).(*TimingData)
		timingCtx, hasTimingCtx := ctx.Value(pauseTimeKey).(*timingContext)
		
		if !hasTimingData || !hasTimingCtx {
			// No timing data, just make the call normally
			return invoker(ctx, method, req, reply, cc, opts...)
		}

		// PUSH onto call stack (lock-free atomic increment)
		// If this is the first call (0→1), we transition to blocking state
		oldCount := atomic.AddInt32(&timingCtx.activeCallCount, 1) - 1
		currentCount := oldCount + 1
		
		if oldCount == 0 {
			// Stack was empty, now has 1 item - START blocking period
			pauseStartNs := time.Now().UnixNano()
			atomic.StoreInt64(&timingCtx.pauseStartTimeNs, pauseStartNs)
			
			// Pause perf counters and accumulate execution time
			if atomic.LoadInt32(&timingCtx.perfEnabled) == 1 {
				cHandles := (*C.struct_perf_handles)(unsafe.Pointer(timingCtx.perfHandles))
				if cHandles != nil && cHandles.leader_fd >= 0 {
					// Pause and get current values
					cPausedValues := C.perf_pause(cHandles)
					
					// Calculate delta from last accumulation point
					cLastAccum := (*C.struct_perf_values)(unsafe.Pointer(timingCtx.perfAccumExecution))
					if cLastAccum != nil {
						// Add delta to accumulated execution counters
						cDelta := C.perf_delta(cLastAccum, &cPausedValues)
						
						// Update accumulated execution values
						accumCopy := cDelta
						timingCtx.perfAccumExecution = uintptr(unsafe.Pointer(&accumCopy))
					}
				}
			}
			
			log.Info().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", currentCount).
				Float64("blocking_time_ms", 0.0). // Add field for log collection filter
				Msg("Starting downstream call - PAUSING parent timer (stack 0→1)")
		} else {
			log.Info().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", currentCount).
				Float64("blocking_time_ms", 0.0). // Add field for log collection filter
				Msg("Starting downstream call - already blocked (stack depth increased)")
		}
		
		// Increment total call counter
		atomic.AddInt32(&timingCtx.totalCallCount, 1)
		
		// Make the actual call (this is the blocking part)
		callStart := time.Now()
		err := invoker(ctx, method, req, reply, cc, opts...)
		callDuration := time.Since(callStart)
		
		// POP from call stack (lock-free atomic decrement)
		// If this was the last call (1→0), we transition to processing state
		newCount := atomic.AddInt32(&timingCtx.activeCallCount, -1)
		
		if newCount == 0 {
			// Stack is now empty - END blocking period and accumulate time
			pauseStartNs := atomic.LoadInt64(&timingCtx.pauseStartTimeNs)
			if pauseStartNs > 0 {
				blockingDurationNs := time.Now().UnixNano() - pauseStartNs
				atomic.AddInt64(&timingCtx.totalPausedTimeNs, blockingDurationNs)
				atomic.StoreInt64(&timingCtx.pauseStartTimeNs, 0)
				
				totalPausedNs := atomic.LoadInt64(&timingCtx.totalPausedTimeNs)
				
				// Resume perf counters - continue counting execution time
				if atomic.LoadInt32(&timingCtx.perfEnabled) == 1 {
					cHandles := (*C.struct_perf_handles)(unsafe.Pointer(timingCtx.perfHandles))
					if cHandles != nil && cHandles.leader_fd >= 0 {
						// Resume counting (doesn't reset, just continues)
						C.perf_resume(cHandles)
					}
				}
				
				log.Info().
					Str("outgoing_method", method).
					Str("parent_service", timingData.ServiceName).
					Str("parent_method", timingData.Method).
					Int32("stack_depth", newCount).
					Dur("this_call_duration", callDuration).
					Float64("this_call_duration_ms", float64(callDuration.Nanoseconds())/1000000).
					Float64("blocking_period_ms", float64(blockingDurationNs)/1000000).
					Float64("total_paused_ms", float64(totalPausedNs)/1000000).
					Float64("blocking_time_ms", float64(totalPausedNs)/1000000). // Add field for log collection filter
					Msg("Downstream call completed - RESUMING parent timer (stack 1→0)")
			}
		} else {
			log.Info().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", newCount).
				Dur("this_call_duration", callDuration).
				Float64("this_call_duration_ms", float64(callDuration.Nanoseconds())/1000000).
				Float64("blocking_time_ms", 0.0). // Add field for log collection filter
				Msg("Downstream call completed - still blocked (stack depth decreased)")
		}
		
		return err
	}
}

// ChainUnaryServerInterceptors chains multiple server interceptors
func ChainUnaryServerInterceptors(interceptors ...grpc.UnaryServerInterceptor) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		chain := handler
		for i := len(interceptors) - 1; i >= 0; i-- {
			interceptor := interceptors[i]
			next := chain
			chain = func(currentCtx context.Context, currentReq interface{}) (interface{}, error) {
				return interceptor(currentCtx, currentReq, info, next)
			}
		}
		return chain(ctx, req)
	}
}

// ChainUnaryClientInterceptors chains multiple client interceptors
func ChainUnaryClientInterceptors(interceptors ...grpc.UnaryClientInterceptor) grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		chain := invoker
		for i := len(interceptors) - 1; i >= 0; i-- {
			interceptor := interceptors[i]
			next := chain
			chain = func(currentCtx context.Context, currentMethod string, currentReq, currentReply interface{}, currentCC *grpc.ClientConn, currentOpts ...grpc.CallOption) error {
				return interceptor(currentCtx, currentMethod, currentReq, currentReply, currentCC, next, currentOpts...)
			}
		}
		return chain(ctx, method, req, reply, cc, opts...)
	}
}

// AddTimingData adds timing data to the in-memory aggregator
func (lta *LocalTimingAggregator) AddTimingData(data TimingData) {
	lta.mu.Lock()
	defer lta.mu.Unlock()
	
	lta.data = append(lta.data, data)
	
	// Keep only last 10000 entries to prevent memory issues
	if len(lta.data) > 10000 {
		lta.data = lta.data[len(lta.data)-10000:]
	}
}

// MaybeWriteStats writes statistics to file if enough time has passed
func (lta *LocalTimingAggregator) MaybeWriteStats() {
	lta.mu.RLock()
	shouldWrite := time.Since(lta.lastStatsTime) >= lta.statsInterval && len(lta.data) > 0
	lta.mu.RUnlock()
	
	if !shouldWrite {
		return
	}
	
	lta.mu.Lock()
	defer lta.mu.Unlock()
	
	// Double-check after acquiring write lock
	if time.Since(lta.lastStatsTime) < lta.statsInterval {
		return
	}
	
	if len(lta.data) == 0 {
		return
	}
	
	// Calculate statistics
	stats := lta.calculateStats(lta.data)
	
	// Write stats to file
	if lta.statsFile != "" {
		if err := lta.writeStatsToFile(stats); err != nil {
			log.Error().Err(err).Msg("Failed to write stats to file")
		}
	}
	
	// Update last stats time
	lta.lastStatsTime = time.Now()
	
	// Log summary statistics
	log.Info().
		Str("service", lta.serviceName).
		Int("total_requests", stats.TotalRequests).
		Dur("avg_processing_time", stats.ProcessingStats.Mean).
		Dur("p95_processing_time", stats.ProcessingStats.P95).
		Dur("avg_total_time", stats.TotalTimeStats.Mean).
		Dur("p95_total_time", stats.TotalTimeStats.P95).
		Msg("Timing statistics summary")
}

// writeStatsToFile writes statistics to the configured file
func (lta *LocalTimingAggregator) writeStatsToFile(stats TimingStats) error {
	file, err := os.Create(lta.statsFile)
	if err != nil {
		return fmt.Errorf("failed to create stats file %s: %v", lta.statsFile, err)
	}
	defer file.Close()
	
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(stats); err != nil {
		return fmt.Errorf("failed to write stats to file %s: %v", lta.statsFile, err)
	}
	
	log.Info().
		Str("service", lta.serviceName).
		Str("filename", lta.statsFile).
		Int("total_requests", stats.TotalRequests).
		Msg("Timing statistics written to file")
	
	return nil
}

// calculateStats calculates statistics from timing data
func (lta *LocalTimingAggregator) calculateStats(data []TimingData) TimingStats {
	if len(data) == 0 {
		return TimingStats{ServiceName: lta.serviceName}
	}
	
	// Separate data by type
	var processingTimes, totalTimes, blockingTimes []time.Duration
	methodData := make(map[string][]time.Duration)
	
	for _, d := range data {
		processingTimes = append(processingTimes, d.ProcessingTime)
		totalTimes = append(totalTimes, d.TotalTime)
		blockingTimes = append(blockingTimes, d.BlockingTime)
		
		if methodData[d.Method] == nil {
			methodData[d.Method] = make([]time.Duration, 0)
		}
		methodData[d.Method] = append(methodData[d.Method], d.ProcessingTime)
	}
	
	// Calculate statistics
	stats := TimingStats{
		ServiceName:     lta.serviceName,
		TotalRequests:   len(data),
		ProcessingStats: calculateDurationStats(processingTimes),
		TotalTimeStats:  calculateDurationStats(totalTimes),
		BlockingStats:   calculateDurationStats(blockingTimes),
		MethodBreakdown: make(map[string]DurationStats),
		Histogram:       createHistogram(processingTimes),
		LastUpdated:     time.Now(),
	}
	
	// Calculate per-method statistics
	for method, times := range methodData {
		stats.MethodBreakdown[method] = calculateDurationStats(times)
	}
	
	return stats
}

// calculateDurationStats calculates statistical measures for a slice of durations
func calculateDurationStats(durations []time.Duration) DurationStats {
	if len(durations) == 0 {
		return DurationStats{}
	}
	
	// Sort for percentile calculations
	sorted := make([]time.Duration, len(durations))
	copy(sorted, durations)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i] < sorted[j]
	})
	
	// Calculate mean
	var sum time.Duration
	for _, d := range durations {
		sum += d
	}
	mean := sum / time.Duration(len(durations))
	
	// Calculate percentiles
	p50Index := len(sorted) * 50 / 100
	p95Index := len(sorted) * 95 / 100
	p99Index := len(sorted) * 99 / 100
	
	// Ensure indices are within bounds
	if p50Index >= len(sorted) {
		p50Index = len(sorted) - 1
	}
	if p95Index >= len(sorted) {
		p95Index = len(sorted) - 1
	}
	if p99Index >= len(sorted) {
		p99Index = len(sorted) - 1
	}
	
	return DurationStats{
		Min:   sorted[0],
		Max:   sorted[len(sorted)-1],
		Mean:  mean,
		P50:   sorted[p50Index],
		P95:   sorted[p95Index],
		P99:   sorted[p99Index],
		Count: len(durations),
	}
}

// createHistogram creates a histogram of durations in milliseconds
func createHistogram(durations []time.Duration) map[string]int {
	histogram := make(map[string]int)
	
	// Define histogram buckets in milliseconds
	buckets := []int{1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000}
	
	for _, d := range durations {
		ms := int(d.Nanoseconds() / 1000000) // Convert to milliseconds
		
		bucketFound := false
		for _, bucket := range buckets {
			if ms <= bucket {
				key := fmt.Sprintf("≤%dms", bucket)
				histogram[key]++
				bucketFound = true
				break
			}
		}
		
		if !bucketFound {
			histogram[">10000ms"]++
		}
	}
	
	return histogram
}

// GetTimingStats returns current timing statistics for a service from stats file
func GetTimingStats(statsFile string) (TimingStats, error) {
	var stats TimingStats
	
	file, err := os.Open(statsFile)
	if err != nil {
		return stats, fmt.Errorf("failed to open stats file %s: %v", statsFile, err)
	}
	defer file.Close()
	
	decoder := json.NewDecoder(file)
	if err := decoder.Decode(&stats); err != nil {
		return stats, fmt.Errorf("failed to decode stats from %s: %v", statsFile, err)
	}
	
	return stats, nil
}

