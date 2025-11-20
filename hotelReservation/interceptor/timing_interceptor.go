package interceptor

import (
	"context"
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
	ArrivalTime    time.Time     `json:"arrival_time"`
	ProcessingTime time.Duration `json:"processing_time_ns"` // Time spent in actual processing (excluding blocking calls)
	TotalTime      time.Duration `json:"total_time_ns"`      // Total time including blocking calls
	BlockingTime   time.Duration `json:"blocking_time_ns"`   // Time spent in blocking calls
	Timestamp      time.Time     `json:"timestamp"`
}

// WindowTimingStats captures timing data for requests in one window interval
type WindowTimingStats struct {
	RequestCount   int                 `json:"request_count"`
	ProcessingTime WindowDurationStats `json:"processing_time"`
	TotalTime      WindowDurationStats `json:"total_time"`
	BlockingTime   WindowDurationStats `json:"blocking_time"`
}

// WindowDurationStats provides stats for durations within one window
type WindowDurationStats struct {
	MinNs  int64 `json:"min_ns"`
	MaxNs  int64 `json:"max_ns"`
	MeanNs int64 `json:"mean_ns"`
	Count  int   `json:"count"`
}

// TimingAggregator is the interface for timing data collection implementations
type TimingAggregator interface {
	AddTimingData(data TimingData)
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
	
	return WindowDurationStats{
		MinNs:  min.Nanoseconds(),
		MaxNs:  max.Nanoseconds(),
		MeanNs: mean.Nanoseconds(),
		Count:  len(durations),
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
}

// TimingServerInterceptorWithAggregator creates interceptor using a provided aggregator
// This allows sharing the aggregator across all requests for proper windowed batching
// Uses object pooling and deferred submission to eliminate request path overhead
func TimingServerInterceptorWithAggregator(aggregator TimingAggregator, serviceName string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		// Get objects from pool (zero allocation in steady state)
		timingData := timingDataPool.Get().(*TimingData)
		timingCtx := timingContextPool.Get().(*timingContext)
		
		// START TIMER: Single time.Now() call at start
		arrivalTime := time.Now()
		
		// Initialize timing data (reuse pooled object)
		timingData.ServiceName = serviceName
		timingData.Method = info.FullMethod
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

		// Submit asynchronously in goroutine to avoid blocking request
		// Make a copy for the goroutine since we're returning timingData to pool
		dataCopy := *timingData
		go func() {
			aggregator.AddTimingData(dataCopy)
		}()
		
		// Return objects to pool immediately (request can complete)
		timingDataPool.Put(timingData)
		timingContextPool.Put(timingCtx)

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


