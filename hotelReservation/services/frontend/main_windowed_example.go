package main

// Example: How to integrate windowed sampling into frontend service
// This is a reference implementation - adapt to your actual main.go

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
	"google.golang.org/grpc/keepalive"
	
	"github.com/harlow/go-micro-services/dialer"
	"github.com/harlow/go-micro-services/registry"
	"github.com/harlow/go-micro-services/services/frontend"
	"github.com/harlow/go-micro-services/tracing"
	
	// Import perf and interceptor packages
	"github.com/harlow/go-micro-services/interceptor"
	"github.com/harlow/go-micro-services/services/perf"
)

func mainWithWindowedSampling() error {
	serviceName := "frontend"
	
	// Check if windowed sampling is enabled
	enableWindowed := os.Getenv("ENABLE_WINDOWED_SAMPLING")
	if enableWindowed != "true" {
		log.Info().Msg("Windowed sampling disabled, running in legacy mode")
		// Fall back to legacy mode
		return mainLegacy()
	}
	
	// Parse iteration ID
	iterationID, _ := strconv.Atoi(os.Getenv("ITERATION_ID"))
	if iterationID == 0 {
		iterationID = 1
	}
	
	// Parse run duration
	runDurationSec, _ := strconv.Atoi(os.Getenv("EXPERIMENT_DURATION"))
	if runDurationSec == 0 {
		runDurationSec = 30 // default
	}
	runDuration := time.Duration(runDurationSec) * time.Second
	
	// Parse window interval
	windowIntervalMs, _ := strconv.Atoi(os.Getenv("WINDOW_INTERVAL_MS"))
	if windowIntervalMs == 0 {
		windowIntervalMs = 100 // default
	}
	windowInterval := time.Duration(windowIntervalMs) * time.Millisecond
	
	// Parse perf events
	perfEventsStr := os.Getenv("PERF_EVENTS")
	if perfEventsStr == "" {
		perfEventsStr = "cycles,instructions,cache-misses,llc-misses"
	}
	perfEvents := strings.Split(perfEventsStr, ",")
	for i := range perfEvents {
		perfEvents[i] = strings.TrimSpace(perfEvents[i])
	}
	
	// Output directory
	outputDir := os.Getenv("OUTPUT_DIR")
	if outputDir == "" {
		outputDir = "/data"
	}
	
	log.Info().
		Str("service", serviceName).
		Int("iteration", iterationID).
		Dur("run_duration", runDuration).
		Dur("window_interval", windowInterval).
		Strs("perf_events", perfEvents).
		Msg("Starting with windowed sampling")
	
	// Create channel for timing stats coordination
	timingStatsChannel := make(chan *interceptor.WindowTimingStats, 100)
	
	// Create windowed sampler
	sampler := perf.NewWindowedSampler()
	samplerConfig := perf.RunConfig{
		ServiceName:        serviceName,
		IterationID:        iterationID,
		RunDuration:        runDuration,
		WindowInterval:     windowInterval,
		PerfEvents:         perfEvents,
		OutputDir:          outputDir,
		TimingStatsChannel: timingStatsChannel,
	}
	
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	
	if err := sampler.StartRun(ctx, samplerConfig); err != nil {
		return fmt.Errorf("failed to start windowed sampler: %w", err)
	}
	
	// Create windowed timing aggregator
	// Uses factory to automatically select ring buffer or mutex-based aggregator
	timingConfig := interceptor.TimingConfig{
		EnableTiming:       true,
		ServiceName:        serviceName,
		EnableWindowed:     true,
		WindowInterval:     windowInterval,
		WindowStatsChannel: timingStatsChannel,
	}
	timingAgg := interceptor.CreateTimingAggregator(timingConfig)
	
	// Initialize registry
	reg := registry.NewRegistry(os.Getenv("CONSUL_ADDRESS"))
	
	// Initialize tracer
	tracer, err := tracing.Init(serviceName, os.Getenv("JAEGER_ENDPOINT"))
	if err != nil {
		log.Error().Err(err).Msg("Failed to initialize tracer")
	}
	if tracer != nil {
		defer tracer.Close()
	}
	
	// Create gRPC server with timing interceptor
	kaep := keepalive.EnforcementPolicy{
		MinTime:             5 * time.Second,
		PermitWithoutStream: true,
	}
	
	kasp := keepalive.ServerParameters{
		Time:    60 * time.Second,
		Timeout: 10 * time.Second,
	}
	
	// Build interceptor chain
	// Use the shared aggregator with proper function from interceptor package
	serverInterceptor := interceptor.TimingServerInterceptorWithAggregator(timingAgg, serviceName)
	clientInterceptor := interceptor.TimingClientInterceptor()
	
	server := grpc.NewServer(
		grpc.KeepaliveEnforcementPolicy(kaep),
		grpc.KeepaliveParams(kasp),
		grpc.UnaryInterceptor(serverInterceptor),
		grpc.UnaryClientInterceptor(clientInterceptor),
	)
	
	// Initialize frontend service
	srv := &frontend.Server{
		Registry: reg,
		Tracer:   tracer,
		Dialer:   dialer.NewDialer(reg),
	}
	
	// Register service
	frontend.RegisterFrontendServer(server, srv)
	
	// Listen on port
	lis, err := net.Listen("tcp", ":8080")
	if err != nil {
		return fmt.Errorf("failed to listen: %w", err)
	}
	
	// Setup signal handling for graceful shutdown
	sigCh := make(signal.Chan, 1)
	signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
	
	// Start server in goroutine
	errCh := make(chan error, 1)
	go func() {
		log.Info().Msg("Starting gRPC server on :8080")
		errCh <- server.Serve(lis)
	}()
	
	// Wait for run duration or signal
	select {
	case <-time.After(runDuration):
		log.Info().Msg("Run duration elapsed, stopping")
	case sig := <-sigCh:
		log.Info().Str("signal", sig.String()).Msg("Received signal, stopping")
	case err := <-errCh:
		return fmt.Errorf("server error: %w", err)
	}
	
	// Stop windowed sampler
	log.Info().Msg("Stopping windowed sampler")
	runData, err := sampler.StopRun()
	if err != nil {
		log.Error().Err(err).Msg("Error stopping sampler")
	} else {
		log.Info().
			Int("sample_count", runData.SampleCount).
			Int("total_requests", runData.Aggregates.TotalRequests).
			Str("output_file", fmt.Sprintf("%s/run_data_%s_iter%d.json", outputDir, serviceName, iterationID)).
			Msg("Windowed sampling completed successfully")
	}
	
	// Stop timing aggregator
	timingAgg.Stop()
	
	// Graceful shutdown of gRPC server
	log.Info().Msg("Shutting down gRPC server")
	server.GracefulStop()
	
	return nil
}

// Note: TimingServerInterceptorWithAggregator is now in interceptor package
// No need to redefine it here - just import and use:
// interceptor.TimingServerInterceptorWithAggregator(aggregator, serviceName)

// mainLegacy is the fallback for when windowed sampling is disabled
func mainLegacy() error {
	// Existing main.go logic
	log.Info().Msg("Running in legacy mode without windowed sampling")
	// ... existing code ...
	return nil
}

