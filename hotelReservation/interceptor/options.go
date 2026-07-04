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

// GetServerInterceptor returns a combined server interceptor with tracing and timing.
// When timing is DISABLED the timing interceptor is not chained at all: chaining
// it with a nil aggregator SIGSEGVs on the first request (RecordArrival on a nil
// interface) -- this crash-looped the user service under the mixed workload.
// Note: For windowed timing, create aggregator separately and pass it to TimingServerInterceptorWithAggregator
func (opts ServerOptions) GetServerInterceptor() grpc.ServerOption {
	if !opts.TimingConfig.EnableTiming {
		return grpc.UnaryInterceptor(otgrpc.OpenTracingServerInterceptor(opts.Tracer))
	}
	aggregator := NewRingBufferTimingAggregator(opts.TimingConfig)
	return grpc.UnaryInterceptor(
		ChainUnaryServerInterceptors(
			otgrpc.OpenTracingServerInterceptor(opts.Tracer),
			TimingServerInterceptorWithAggregator(aggregator, opts.TimingConfig.ServiceName),
		),
	)
}

// GetTimingServerInterceptor returns only the timing interceptor (a pass-through
// when timing is disabled -- see GetServerInterceptor for the nil-aggregator trap).
// Note: For windowed timing, create aggregator separately and pass it to TimingServerInterceptorWithAggregator
func (opts ServerOptions) GetTimingServerInterceptor() grpc.ServerOption {
	var aggregator TimingAggregator
	if opts.TimingConfig.EnableTiming {
		aggregator = NewRingBufferTimingAggregator(opts.TimingConfig)
	}
	// TimingServerInterceptorWithAggregator handles a nil aggregator by
	// returning a pass-through interceptor.
	return grpc.UnaryInterceptor(TimingServerInterceptorWithAggregator(aggregator, opts.TimingConfig.ServiceName))
}

