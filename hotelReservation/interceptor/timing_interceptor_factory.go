package interceptor

import (
	"context"
	"os"
	"sync/atomic"
	"time"
	
	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
)

// TimingAggregator is the interface for both implementations
type TimingAggregator interface {
	AddTimingData(data TimingData)
	Stop()
}

// CreateTimingAggregator creates the appropriate aggregator based on configuration
// Automatically chooses ring buffer for windowed mode for better performance
func CreateTimingAggregator(config TimingConfig) TimingAggregator {
	if !config.EnableTiming {
		return &NoOpAggregator{}
	}
	
	if config.EnableWindowed {
		// Use ring buffer for windowed mode (lock-free, high performance)
		useRingBuffer := os.Getenv("USE_RING_BUFFER")
		if useRingBuffer == "" || useRingBuffer == "true" {
			log.Info().
				Str("service", config.ServiceName).
				Msg("Using lock-free ring buffer for timing aggregation")
			return NewRingBufferTimingAggregator(config)
		}
		
		// Fallback to mutex-based aggregator
		log.Info().
			Str("service", config.ServiceName).
			Msg("Using mutex-based aggregator for timing")
		return NewWindowedTimingAggregator(config)
	}
	
	// Legacy mode
	return NewLocalTimingAggregator(config.ServiceName, config.StatsFile)
}

// NoOpAggregator does nothing (when timing is disabled)
type NoOpAggregator struct{}

func (n *NoOpAggregator) AddTimingData(data TimingData) {}
func (n *NoOpAggregator) Stop()                         {}

// Helper to create server interceptor with automatic aggregator selection
func CreateTimingServerInterceptor(config TimingConfig) grpc.UnaryServerInterceptor {
	if !config.EnableTiming {
		return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
			return handler(ctx, req)
		}
	}
	
	aggregator := CreateTimingAggregator(config)
	return TimingServerInterceptorWithAggregator(aggregator, config.ServiceName)
}

// TimingServerInterceptorWithInterface creates server interceptor using TimingAggregator interface
// This version works with both ring buffer and mutex-based aggregators
func TimingServerInterceptorWithInterface(aggregator TimingAggregator, serviceName string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		// START TIMER: Record when request arrives
		arrivalTime := time.Now()
		
		// Initialize timing data in context
		timingData := &TimingData{
			ServiceName: serviceName,
			Method:      info.FullMethod,
			ArrivalTime: arrivalTime,
			Timestamp:   arrivalTime,
		}
		
		// Create mutable timing context for pause/resume (lock-free atomic ops)
		timingCtx := &timingContext{
			activeCallCount:   0,
			pauseStartTimeNs:  0,
			totalPausedTimeNs: 0,
			totalCallCount:    0,
		}
		
		// Store in context for client interceptor
		ctx = context.WithValue(ctx, timingDataKey, timingData)
		ctx = context.WithValue(ctx, pauseTimeKey, timingCtx)
		
		log.Debug().
			Str("method", info.FullMethod).
			Str("service", serviceName).
			Msg("START TIMER - gRPC request arrived")
		
		// Call handler (may pause/resume timer via client interceptor)
		resp, err := handler(ctx, req)
		
		// STOP TIMER: Calculate final timing before sending response
		processingEnd := time.Now()
		totalTime := processingEnd.Sub(arrivalTime)
		
		// Get accumulated pause time (lock-free atomic read)
		pausedTime := time.Duration(atomic.LoadInt64(&timingCtx.totalPausedTimeNs))
		processingTime := totalTime - pausedTime
		blockingCount := atomic.LoadInt32(&timingCtx.totalCallCount)
		
		// Update timing data with final values
		timingData.TotalTime = totalTime
		timingData.ProcessingTime = processingTime
		timingData.BlockingTime = pausedTime
		
		log.Debug().
			Str("method", info.FullMethod).
			Str("service", serviceName).
			Int32("downstream_calls", blockingCount).
			Dur("total_time", totalTime).
			Dur("processing_time", processingTime).
			Dur("blocking_time", pausedTime).
			Msg("STOP TIMER - gRPC request completed, sending response")
		
		// ADD TO WINDOW BUFFER
		// For ring buffer: lock-free atomic CAS operations
		// For mutex: brief lock to append
		aggregator.AddTimingData(*timingData)
		
		return resp, err
	}
}

