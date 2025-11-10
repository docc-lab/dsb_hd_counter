package perf

// This file provides example integration code for services to use windowed sampling
// Copy the relevant parts to your service's main.go

import (
	"context"
	"os"
	"strconv"
	"strings"
	"time"
	
	"github.com/rs/zerolog/log"
	"myapp/interceptor"
)

// ParseWindowedSamplingConfig parses configuration from environment variables
func ParseWindowedSamplingConfig(serviceName string, iterationID int) (*RunConfig, error) {
	// Get run duration from environment
	experimentDuration := os.Getenv("EXPERIMENT_DURATION")
	if experimentDuration == "" {
		experimentDuration = "30" // default 30 seconds
	}
	durationSec, err := strconv.Atoi(experimentDuration)
	if err != nil {
		return nil, err
	}
	
	// Get window interval from environment
	windowIntervalMs := os.Getenv("WINDOW_INTERVAL_MS")
	if windowIntervalMs == "" {
		windowIntervalMs = "100" // default 100ms
	}
	intervalMs, err := strconv.Atoi(windowIntervalMs)
	if err != nil {
		return nil, err
	}
	
	// Get perf events from environment
	perfEventsStr := os.Getenv("PERF_EVENTS")
	if perfEventsStr == "" {
		perfEventsStr = "cycles,instructions,cache-misses,llc-misses"
	}
	perfEvents := strings.Split(perfEventsStr, ",")
	// Trim whitespace from each event
	for i := range perfEvents {
		perfEvents[i] = strings.TrimSpace(perfEvents[i])
	}
	
	// Get output directory
	outputDir := os.Getenv("OUTPUT_DIR")
	if outputDir == "" {
		outputDir = "/data"
	}
	
	config := &RunConfig{
		ServiceName:    serviceName,
		IterationID:    iterationID,
		RunDuration:    time.Duration(durationSec) * time.Second,
		WindowInterval: time.Duration(intervalMs) * time.Millisecond,
		PerfEvents:     perfEvents,
		OutputDir:      outputDir,
	}
	
	return config, nil
}

// SetupWindowedSampling initializes windowed sampling and timing interceptor
// Returns sampler, timing aggregator, and channel for coordination
// Uses lock-free ring buffer for optimal performance under high concurrency
func SetupWindowedSampling(serviceName string, iterationID int) (WindowedSampler, interceptor.TimingAggregator, chan *interceptor.WindowTimingStats, error) {
	// Parse configuration
	config, err := ParseWindowedSamplingConfig(serviceName, iterationID)
	if err != nil {
		return nil, nil, nil, err
	}
	
	// Create channel for timing stats
	timingStatsChannel := make(chan *interceptor.WindowTimingStats, 100)
	config.TimingStatsChannel = timingStatsChannel
	
	// Create windowed sampler
	sampler := NewWindowedSampler()
	
	// Create timing aggregator (automatically uses ring buffer if enabled)
	timingConfig := interceptor.TimingConfig{
		EnableTiming:       true,
		ServiceName:        serviceName,
		EnableWindowed:     true,
		WindowInterval:     config.WindowInterval,
		WindowStatsChannel: timingStatsChannel,
	}
	
	// Use factory to create aggregator (ring buffer or mutex-based)
	timingAgg := interceptor.CreateTimingAggregator(timingConfig)
	
	// Start sampler
	ctx := context.Background()
	if err := sampler.StartRun(ctx, *config); err != nil {
		return nil, nil, nil, err
	}
	
	log.Info().
		Str("service", serviceName).
		Int("iteration", iterationID).
		Dur("run_duration", config.RunDuration).
		Dur("window_interval", config.WindowInterval).
		Strs("perf_events", config.PerfEvents).
		Str("aggregator_type", "ring_buffer").
		Msg("Windowed sampling initialized")
	
	return sampler, timingAgg, timingStatsChannel, nil
}

// Example usage in service main.go:
/*
func main() {
	serviceName := "frontend"
	
	// Check if windowed sampling is enabled
	enableWindowed := os.Getenv("ENABLE_WINDOWED_SAMPLING")
	if enableWindowed != "true" {
		// Run service in legacy mode
		startLegacyService()
		return
	}
	
	// Get iteration ID
	iterationID, _ := strconv.Atoi(os.Getenv("ITERATION_ID"))
	if iterationID == 0 {
		iterationID = 1
	}
	
	// Setup windowed sampling
	sampler, timingAgg, _, err := perf.SetupWindowedSampling(serviceName, iterationID)
	if err != nil {
		log.Fatal().Err(err).Msg("Failed to setup windowed sampling")
	}
	
	// Create gRPC server with timing interceptor
	server := grpc.NewServer(
		grpc.UnaryInterceptor(
			interceptor.ChainUnaryServerInterceptors(
				interceptor.TimingServerInterceptorWithAggregator(timingAgg),
				// ... other interceptors ...
			),
		),
		grpc.UnaryClientInterceptor(
			interceptor.TimingClientInterceptor(),
		),
	)
	
	// Register services
	// ...
	
	// Handle graceful shutdown
	go func() {
		// Wait for run duration or signal
		runDuration, _ := strconv.Atoi(os.Getenv("EXPERIMENT_DURATION"))
		if runDuration == 0 {
			runDuration = 30
		}
		time.Sleep(time.Duration(runDuration) * time.Second)
		
		// Stop sampling
		runData, err := sampler.StopRun()
		if err != nil {
			log.Error().Err(err).Msg("Error stopping sampler")
		} else {
			log.Info().
				Int("sample_count", runData.SampleCount).
				Int("total_requests", runData.Aggregates.TotalRequests).
				Msg("Windowed sampling completed")
		}
		
		// Stop timing aggregator
		timingAgg.Stop()
		
		// Shutdown server
		server.GracefulStop()
	}()
	
	// Start serving
	listener, _ := net.Listen("tcp", ":8080")
	server.Serve(listener)
}
*/

