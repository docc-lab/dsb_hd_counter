package interceptor

import (
	"context"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
)

// Object pools for zero-allocation timing
var (
	timingDataPool = sync.Pool{
		New: func() interface{} {
			return &TimingData{}
		},
	}
	
	timingContextPool = sync.Pool{
		New: func() interface{} {
			return &timingContext{}
		},
	}
)

// TimingConfig holds configuration for timing interceptor
type TimingConfig struct {
	EnableTiming       bool
	ServiceName        string
	EnableWindowed     bool          // Enable windowed batching mode
	WindowInterval     time.Duration // Window interval for batching (e.g., 100ms)
	WindowStatsChannel chan *WindowTimingStats // Channel to send window stats
}

// TimingData represents a single timing measurement
type TimingData struct {
	ServiceName    string        `json:"service_name"`
	Method         string        `json:"method"`
	IsArrival      bool          `json:"is_arrival"`         // true = arrival event, false = completion event
	ArrivalTime    time.Time     `json:"arrival_time"`
	ProcessingTime time.Duration `json:"processing_time_ns"` // Time spent in actual processing (excluding blocking calls)
	TotalTime      time.Duration `json:"total_time_ns"`      // Total time including blocking calls
	BlockingTime   time.Duration `json:"blocking_time_ns"`   // Time spent in blocking calls
	Timestamp      time.Time     `json:"timestamp"`
}

// WindowTimingStats captures timing data for requests in one window interval
type WindowTimingStats struct {
	ArrivalCount   int                 `json:"arrival_count"`   // Requests that arrived in this window (sampled at window boundary)
	RequestCount   int                 `json:"request_count"`   // Requests that completed in this window
	ProcessingTime WindowDurationStats `json:"processing_time"`
	TotalTime      WindowDurationStats `json:"total_time"`
	BlockingTime   WindowDurationStats `json:"blocking_time"`
}

// WindowDurationStats provides stats for durations within one window
type WindowDurationStats struct {
	MinNs  int64 `json:"min_ns"`
	MaxNs  int64 `json:"max_ns"`
	MeanNs int64 `json:"mean_ns"`
	P50Ns  int64 `json:"p50_ns"`
	P60Ns  int64 `json:"p60_ns"`
	P70Ns  int64 `json:"p70_ns"`
	P75Ns  int64 `json:"p75_ns"`
	P80Ns  int64 `json:"p80_ns"`
	P90Ns  int64 `json:"p90_ns"`
	P99Ns  int64 `json:"p99_ns"`
	Count  int   `json:"count"`
}

// TimingAggregator is the interface for timing data collection implementations
type TimingAggregator interface {
	RecordArrival()            // Increments arrival counter (sampled per window)
	AddTimingData(data TimingData) // Records completed request timing
	Stop()
}

// calculateWindowDurationStats calculates statistics for a slice of durations
func calculateWindowDurationStats(durations []time.Duration) WindowDurationStats {
	if len(durations) == 0 {
		return WindowDurationStats{}
	}
	
	var sum time.Duration
	min := durations[0]
	max := durations[0]
	
	for _, d := range durations {
		sum += d
		if d < min {
			min = d
		}
		if d > max {
			max = d
		}
	}
	
	mean := sum / time.Duration(len(durations))
	
	// Calculate percentiles - need to sort the durations
	// Make a copy to avoid modifying the original slice
	sortedDurations := make([]time.Duration, len(durations))
	copy(sortedDurations, durations)
	sortDurations(sortedDurations)
	
	return WindowDurationStats{
		MinNs:  min.Nanoseconds(),
		MaxNs:  max.Nanoseconds(),
		MeanNs: mean.Nanoseconds(),
		P50Ns:  calculatePercentile(sortedDurations, 0.50).Nanoseconds(),
		P60Ns:  calculatePercentile(sortedDurations, 0.60).Nanoseconds(),
		P70Ns:  calculatePercentile(sortedDurations, 0.70).Nanoseconds(),
		P75Ns:  calculatePercentile(sortedDurations, 0.75).Nanoseconds(),
		P80Ns:  calculatePercentile(sortedDurations, 0.80).Nanoseconds(),
		P90Ns:  calculatePercentile(sortedDurations, 0.90).Nanoseconds(),
		P99Ns:  calculatePercentile(sortedDurations, 0.99).Nanoseconds(),
		Count:  len(durations),
	}
}

// sortDurations sorts a slice of durations in-place
// Uses insertion sort for small slices (<50), standard library sort for larger
func sortDurations(durations []time.Duration) {
	n := len(durations)
	
	// For small slices, insertion sort is faster due to better cache locality
	// and avoids the overhead of sort.Slice
	if n < 50 {
		for i := 1; i < n; i++ {
			key := durations[i]
			j := i - 1
			for j >= 0 && durations[j] > key {
				durations[j+1] = durations[j]
				j--
			}
			durations[j+1] = key
		}
		return
	}
	
	// For larger slices, use Go's optimized pdqsort (pattern-defeating quicksort)
	sort.Slice(durations, func(i, j int) bool {
		return durations[i] < durations[j]
	})
}

// calculatePercentile calculates the percentile value from a sorted slice
// Uses linear interpolation between closest ranks (standard method)
// Assumes durations is already sorted
func calculatePercentile(sortedDurations []time.Duration, percentile float64) time.Duration {
	if len(sortedDurations) == 0 {
		return 0
	}
	if len(sortedDurations) == 1 {
		return sortedDurations[0]
	}
	
	// Calculate the rank (position in the sorted array)
	// rank = percentile * (n - 1) where n is the number of elements
	rank := percentile * float64(len(sortedDurations)-1)
	lowerIndex := int(rank)
	upperIndex := lowerIndex + 1
	
	// Handle edge case where rank is exactly at the last index
	if upperIndex >= len(sortedDurations) {
		return sortedDurations[len(sortedDurations)-1]
	}
	
	// Linear interpolation between the two closest values
	fraction := rank - float64(lowerIndex)
	lower := sortedDurations[lowerIndex]
	upper := sortedDurations[upperIndex]
	
	return lower + time.Duration(float64(upper-lower)*fraction)
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
}

// TimingServerInterceptorWithAggregator creates interceptor using a provided aggregator
// This allows sharing the aggregator across all requests for proper windowed batching
// Uses object pooling and deferred submission to eliminate request path overhead
func TimingServerInterceptorWithAggregator(aggregator TimingAggregator, serviceName string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		// RECORD ARRIVAL: Increment arrival counter for this window
		// This happens at request arrival, synchronized with window boundary sampling
		aggregator.RecordArrival()
		
		// Get objects from pool (zero allocation in steady state)
		timingData := timingDataPool.Get().(*TimingData)
		timingCtx := timingContextPool.Get().(*timingContext)
		
		// START TIMER: Single time.Now() call at start
		arrivalTime := time.Now()
		
		// Initialize timing data (reuse pooled object)
		timingData.ServiceName = serviceName
		timingData.Method = info.FullMethod
		timingData.IsArrival = false // This is a completion event
		timingData.ArrivalTime = arrivalTime
		timingData.Timestamp = arrivalTime
		
		// Reset timing context counters (reuse pooled object)
		atomic.StoreInt32(&timingCtx.activeCallCount, 0)
		atomic.StoreInt64(&timingCtx.pauseStartTimeNs, 0)
		atomic.StoreInt64(&timingCtx.totalPausedTimeNs, 0)
		atomic.StoreInt32(&timingCtx.totalCallCount, 0)
		
		// Store timing data and mutable context for client interceptor to access
		ctx = context.WithValue(ctx, timingDataKey, timingData)
		ctx = context.WithValue(ctx, pauseTimeKey, timingCtx)

		// Call the actual handler (may call client interceptor which pauses/resumes timer)
		resp, err := handler(ctx, req)
		
		// STOP TIMER: Single time.Now() call at end
		totalTime := time.Since(arrivalTime)

		// Get the accumulated paused time from the mutable context (lock-free atomic read)
		pausedTime := time.Duration(atomic.LoadInt64(&timingCtx.totalPausedTimeNs))
		
		processingTime := totalTime - pausedTime

	// Update timing data with final values
	timingData.TotalTime = totalTime
	timingData.ProcessingTime = processingTime
	timingData.BlockingTime = pausedTime

	// Make a copy of timing data before returning to pool
	// The aggregator's channel consumer will handle this asynchronously
	dataCopy := *timingData
	
	// Return objects to pool immediately (before channel send)
	timingDataPool.Put(timingData)
	timingContextPool.Put(timingCtx)

	// Non-blocking send to aggregator's channel
	// The pre-existing consumer goroutine will process this
	// Request doesn't wait - returns immediately
	aggregator.AddTimingData(dataCopy)

	return resp, err
	}
}

// TimingClientInterceptor creates a client-side unary interceptor that pauses timing during blocking calls
// Uses LOCK-FREE atomic operations with a stack-based approach:
// - Push (increment counter) when making a call
// - Pop (decrement counter) when receiving response
// - Empty stack (counter=0) means service is processing (not blocked)
// - Non-empty stack (counter>0) means service is blocked
// NO LOCKS: All operations use atomic instructions for thread-safety
// Optimized: minimal time.Now() calls, only when transitioning states
func TimingClientInterceptor() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		// Check if we have timing context (meaning timing is enabled)
		_, hasTimingData := ctx.Value(timingDataKey).(*TimingData)
		timingCtx, hasTimingCtx := ctx.Value(pauseTimeKey).(*timingContext)
		
		if !hasTimingData || !hasTimingCtx {
			// No timing data, just make the call normally
			return invoker(ctx, method, req, reply, cc, opts...)
		}

		// PAUSE TIMER: Push onto call stack (LOCK-FREE atomic increment)
		// If this is the first call (0→1), we transition to blocking state
		oldCount := atomic.AddInt32(&timingCtx.activeCallCount, 1) - 1
		
		if oldCount == 0 {
			// Stack was empty, now has 1 item - START blocking period (PAUSE TIMER)
			// OPTIMIZATION: Only call time.Now() when transitioning to blocked state
			pauseStartNs := time.Now().UnixNano()
			atomic.StoreInt64(&timingCtx.pauseStartTimeNs, pauseStartNs)
		}
		
		// Increment total call counter (LOCK-FREE atomic)
		atomic.AddInt32(&timingCtx.totalCallCount, 1)
		
		// Make the actual downstream call (THIS IS THE BLOCKING PART)
		err := invoker(ctx, method, req, reply, cc, opts...)
		
		// RESUME TIMER: Pop from call stack (LOCK-FREE atomic decrement)
		// If this was the last call (1→0), we transition back to processing state
		newCount := atomic.AddInt32(&timingCtx.activeCallCount, -1)
		
		if newCount == 0 {
			// Stack is now empty - END blocking period and accumulate time (RESUME TIMER)
			// OPTIMIZATION: Only call time.Now() when transitioning to processing state
			pauseStartNs := atomic.LoadInt64(&timingCtx.pauseStartTimeNs)
			if pauseStartNs > 0 {
				blockingDurationNs := time.Now().UnixNano() - pauseStartNs
				atomic.AddInt64(&timingCtx.totalPausedTimeNs, blockingDurationNs)
				atomic.StoreInt64(&timingCtx.pauseStartTimeNs, 0)
			}
		}
		
		// Return back to service handler
		// Server interceptor will STOP TIMER when response is sent
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


