package interceptor

import (
	"github.com/grpc-ecosystem/grpc-opentracing/go/otgrpc"
	opentracing "github.com/opentracing/opentracing-go"
	"google.golang.org/grpc"
)

// ServerOptions provides helper functions for server interceptor setup
type ServerOptions struct {
	TimingConfig TimingConfig
	Tracer       opentracing.Tracer
}

// GetServerInterceptor returns a combined server interceptor with tracing and timing
// Note: For windowed timing, create aggregator separately and pass it to TimingServerInterceptorWithAggregator
func (opts ServerOptions) GetServerInterceptor() grpc.ServerOption {
	// Create ring buffer aggregator if timing is enabled
	var aggregator TimingAggregator
	if opts.TimingConfig.EnableTiming {
		aggregator = NewRingBufferTimingAggregator(opts.TimingConfig)
	}
	
	return grpc.UnaryInterceptor(
		ChainUnaryServerInterceptors(
			otgrpc.OpenTracingServerInterceptor(opts.Tracer),
			TimingServerInterceptorWithAggregator(aggregator, opts.TimingConfig.ServiceName),
		),
	)
}

// GetTimingServerInterceptor returns only the timing interceptor
// Note: For windowed timing, create aggregator separately and pass it to TimingServerInterceptorWithAggregator
func (opts ServerOptions) GetTimingServerInterceptor() grpc.ServerOption {
	// Create ring buffer aggregator if timing is enabled
	var aggregator TimingAggregator
	if opts.TimingConfig.EnableTiming {
		aggregator = NewRingBufferTimingAggregator(opts.TimingConfig)
	}
	
	return grpc.UnaryInterceptor(TimingServerInterceptorWithAggregator(aggregator, opts.TimingConfig.ServiceName))
}

