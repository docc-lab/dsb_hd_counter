package interceptor

import (
	"context"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
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
func TimingServerInterceptorWithAggregator(aggregator TimingAggregator, serviceName string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		// START TIMER: Record timestamp when new gRPC call arrives
		arrivalTime := time.Now()
		
		// Initialize timing data in context
		timingData := &TimingData{
			ServiceName: serviceName,
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
		}
		
		// Store timing data and mutable context for client interceptor to access
		ctx = context.WithValue(ctx, timingDataKey, timingData)
		ctx = context.WithValue(ctx, pauseTimeKey, timingCtx)

		log.Debug().
			Str("method", info.FullMethod).
			Str("service", serviceName).
			Time("arrival_time", arrivalTime).
			Msg("gRPC request started")

		// Call the actual handler (may call client interceptor which pauses/resumes timer)
		resp, err := handler(ctx, req)
		
		// STOP TIMER: Response is about to be sent back
		processingEnd := time.Now()

		// Calculate timing metrics
		totalTime := processingEnd.Sub(arrivalTime)
		
		// Get the accumulated paused time from the mutable context (lock-free atomic read)
		pausedTimeNs := atomic.LoadInt64(&timingCtx.totalPausedTimeNs)
		pausedTime := time.Duration(pausedTimeNs)
		blockingCount := atomic.LoadInt32(&timingCtx.totalCallCount)
		
		processingTime := totalTime - pausedTime

		// Update timing data with final values
		timingData.TotalTime = totalTime
		timingData.ProcessingTime = processingTime
		timingData.BlockingTime = pausedTime

		// Log detailed timing information for this request
		log.Debug().
			Str("method", info.FullMethod).
			Str("service", serviceName).
			Int32("downstream_calls", blockingCount).
			Dur("total_time", totalTime).
			Dur("processing_time", processingTime).
			Dur("blocking_time", pausedTime).
			Float64("processing_time_ms", float64(processingTime.Nanoseconds())/1000000).
			Float64("total_time_ms", float64(totalTime.Nanoseconds())/1000000).
			Float64("blocking_time_ms", float64(pausedTime.Nanoseconds())/1000000).
			Msg("gRPC request completed")

		// ADD TO WINDOW BUFFER: Add completed timing data to aggregator
		// This goes into the window data buffer and will be aggregated with other concurrent requests
		aggregator.AddTimingData(*timingData)

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
func TimingClientInterceptor() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		// Check if we have timing context (meaning timing is enabled)
		timingData, hasTimingData := ctx.Value(timingDataKey).(*TimingData)
		timingCtx, hasTimingCtx := ctx.Value(pauseTimeKey).(*timingContext)
		
		if !hasTimingData || !hasTimingCtx {
			// No timing data, just make the call normally
			return invoker(ctx, method, req, reply, cc, opts...)
		}

		// PAUSE TIMER: Push onto call stack (LOCK-FREE atomic increment)
		// If this is the first call (0→1), we transition to blocking state
		oldCount := atomic.AddInt32(&timingCtx.activeCallCount, 1) - 1
		currentCount := oldCount + 1
		
		if oldCount == 0 {
			// Stack was empty, now has 1 item - START blocking period (PAUSE TIMER)
			pauseStartNs := time.Now().UnixNano()
			atomic.StoreInt64(&timingCtx.pauseStartTimeNs, pauseStartNs)
			
			log.Debug().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", currentCount).
				Msg("PAUSE TIMER - Starting downstream call (stack 0→1)")
		} else {
			log.Debug().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", currentCount).
				Msg("Nested downstream call - already paused (stack depth increased)")
		}
		
		// Increment total call counter (LOCK-FREE atomic)
		atomic.AddInt32(&timingCtx.totalCallCount, 1)
		
		// Make the actual downstream call (THIS IS THE BLOCKING PART)
		callStart := time.Now()
		err := invoker(ctx, method, req, reply, cc, opts...)
		callDuration := time.Since(callStart)
		
		// RESUME TIMER: Pop from call stack (LOCK-FREE atomic decrement)
		// If this was the last call (1→0), we transition back to processing state
		newCount := atomic.AddInt32(&timingCtx.activeCallCount, -1)
		
		if newCount == 0 {
			// Stack is now empty - END blocking period and accumulate time (RESUME TIMER)
			pauseStartNs := atomic.LoadInt64(&timingCtx.pauseStartTimeNs)
			if pauseStartNs > 0 {
				blockingDurationNs := time.Now().UnixNano() - pauseStartNs
				atomic.AddInt64(&timingCtx.totalPausedTimeNs, blockingDurationNs)
				atomic.StoreInt64(&timingCtx.pauseStartTimeNs, 0)
				
				totalPausedNs := atomic.LoadInt64(&timingCtx.totalPausedTimeNs)
				
				log.Debug().
					Str("outgoing_method", method).
					Str("parent_service", timingData.ServiceName).
					Str("parent_method", timingData.Method).
					Int32("stack_depth", newCount).
					Dur("this_call_duration", callDuration).
					Float64("blocking_period_ms", float64(blockingDurationNs)/1000000).
					Float64("total_paused_ms", float64(totalPausedNs)/1000000).
					Msg("RESUME TIMER - Downstream call completed (stack 1→0)")
			}
		} else {
			log.Debug().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", newCount).
				Dur("this_call_duration", callDuration).
				Msg("Nested downstream call completed - still paused (stack depth decreased)")
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


