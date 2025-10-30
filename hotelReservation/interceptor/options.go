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
func (opts ServerOptions) GetServerInterceptor() grpc.ServerOption {
	return grpc.UnaryInterceptor(
		ChainUnaryServerInterceptors(
			otgrpc.OpenTracingServerInterceptor(opts.Tracer),
			TimingServerInterceptor(opts.TimingConfig),
		),
	)
}

// GetTimingServerInterceptor returns only the timing interceptor
func (opts ServerOptions) GetTimingServerInterceptor() grpc.ServerOption {
	return grpc.UnaryInterceptor(TimingServerInterceptor(opts.TimingConfig))
}

