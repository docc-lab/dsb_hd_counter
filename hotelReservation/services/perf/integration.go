package perf

// This file provides helper functions for services to integrate windowed sampling
// Services can call SetupWindowedSampling() to initialize both perf counters and timing aggregator

import (
	"context"
	"os"
	"strconv"
	"strings"
	"time"
	
	"github.com/rs/zerolog/log"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
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
	
	// Create timing aggregator using lock-free ring buffer
	timingConfig := interceptor.TimingConfig{
		EnableTiming:       true,
		ServiceName:        serviceName,
		EnableWindowed:     true,
		WindowInterval:     config.WindowInterval,
		WindowStatsChannel: timingStatsChannel,
	}
	
	// Create ring buffer aggregator for high-performance timing collection
	timingAgg := interceptor.NewRingBufferTimingAggregator(timingConfig)
	
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

// SetupContinuousSampling initializes continuous windowed sampling (runs indefinitely until pod termination)
// Samples are appended to file continuously, data-collector extracts relevant time windows later
func SetupContinuousSampling(serviceName string, iterationID int) (WindowedSampler, interceptor.TimingAggregator, chan *interceptor.WindowTimingStats, error) {
	// Parse window interval
	windowIntervalMs, _ := strconv.Atoi(os.Getenv("WINDOW_INTERVAL_MS"))
	if windowIntervalMs == 0 {
		windowIntervalMs = 100
	}
	
	// Parse perf events
	perfEventsStr := os.Getenv("PERF_EVENTS")
	if perfEventsStr == "" {
		perfEventsStr = "cycles,instructions,cache-misses"
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
	
	// Create timing stats channel
	timingStatsChannel := make(chan *interceptor.WindowTimingStats, 100)
	
	// Create config for very long run (24 hours - effectively continuous)
	config := &RunConfig{
		ServiceName:        serviceName,
		IterationID:        iterationID,
		RunDuration:        24 * time.Hour, // Continuous until pod stops
		WindowInterval:     time.Duration(windowIntervalMs) * time.Millisecond,
		PerfEvents:         perfEvents,
		OutputDir:          outputDir,
		TimingStatsChannel: timingStatsChannel,
	}
	
	// Create timing aggregator
	timingConfig := interceptor.TimingConfig{
		EnableTiming:       true,
		ServiceName:        serviceName,
		EnableWindowed:     true,
		WindowInterval:     config.WindowInterval,
		WindowStatsChannel: timingStatsChannel,
	}
	timingAgg := interceptor.NewRingBufferTimingAggregator(timingConfig)
	
	// Create and start sampler
	sampler := NewWindowedSampler()
	ctx := context.Background()
	if err := sampler.StartRun(ctx, *config); err != nil {
		return nil, nil, nil, err
	}
	
	log.Info().
		Str("service", serviceName).
		Int("iteration", iterationID).
		Dur("window_interval", config.WindowInterval).
		Strs("perf_events", config.PerfEvents).
		Str("mode", "continuous_24h").
		Msg("Continuous windowed sampling initialized")
	
	return sampler, timingAgg, timingStatsChannel, nil
}

