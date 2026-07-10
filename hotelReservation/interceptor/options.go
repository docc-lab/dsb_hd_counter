package interceptor

import (
	"context"

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
//
// When timing is disabled there is no aggregator; the timing interceptor
// MUST NOT be installed then -- TimingServerInterceptorWithAggregator
// dereferences the aggregator on every request, so a nil one crashes the
// service on its first RPC.
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

// GetTimingServerInterceptor returns only the timing interceptor
// Note: For windowed timing, create aggregator separately and pass it to TimingServerInterceptorWithAggregator
func (opts ServerOptions) GetTimingServerInterceptor() grpc.ServerOption {
	if !opts.TimingConfig.EnableTiming {
		// No aggregator without timing; a pass-through keeps the server
		// wiring uniform without the nil-dereference footgun.
		return grpc.UnaryInterceptor(func(ctx context.Context, req interface{},
			info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
			return handler(ctx, req)
		})
	}
	aggregator := NewRingBufferTimingAggregator(opts.TimingConfig)
	return grpc.UnaryInterceptor(TimingServerInterceptorWithAggregator(aggregator, opts.TimingConfig.ServiceName))
}

