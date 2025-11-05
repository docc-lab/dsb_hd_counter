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

// GetServerInterceptor returns a combined server interceptor with tracing and timing (with optional perf)
func (opts ServerOptions) GetServerInterceptor() grpc.ServerOption {
	interceptors := []grpc.UnaryServerInterceptor{
		otgrpc.OpenTracingServerInterceptor(opts.Tracer),
	}

	// Add timing interceptor if enabled (includes perf if configured)
	if opts.TimingConfig.EnableTiming {
		interceptors = append(interceptors, TimingServerInterceptor(opts.TimingConfig))
	}

	return grpc.UnaryInterceptor(
		ChainUnaryServerInterceptors(interceptors...),
	)
}

// GetTimingServerInterceptor returns only the timing interceptor (with optional perf)
func (opts ServerOptions) GetTimingServerInterceptor() grpc.ServerOption {
	return grpc.UnaryInterceptor(TimingServerInterceptor(opts.TimingConfig))
}

