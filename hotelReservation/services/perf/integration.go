package perf

// This file provides helper functions for services to integrate windowed sampling
// Services can call SetupWindowedSampling() to initialize both perf counters and timing aggregator

import (
	"bufio"
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
		// Default set using only universally available counters.
		// ref-cycles is required to compute actual_freq (see actual-frequency.md);
		// it is a fixed counter and consumes zero programmable counter budget.
		// Note: Use uppercase variants to match perf list output convention.
		perfEventsStr = "cycles,ref-cycles,instructions,cache-references,cache-misses," +
			"branch-instructions,branch-misses," +
			"dTLB-load-misses,iTLB-load-misses," +
			"page-faults,minor-faults,major-faults," +
			"context-switches,cpu-migrations"
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
	
	tscFreqMHz := parseTscFreqMHz()
	c0Threshold := parseFloatEnv("C0_ACTIVE_THRESHOLD", 0.05)
	msrRefresh := parseDurationSecondsEnv("MSR_TURBO_REFRESH_EVERY_S", 10*time.Second)

	config := &RunConfig{
		ServiceName:             serviceName,
		IterationID:             iterationID,
		RunDuration:             time.Duration(durationSec) * time.Second,
		WindowInterval:          time.Duration(intervalMs) * time.Millisecond,
		PerfEvents:              perfEvents,
		OutputDir:               outputDir,
		TscFreqMHz:              tscFreqMHz,
		C0ActiveThreshold:       c0Threshold,
		MsrTurboRefreshInterval: msrRefresh,
	}

	return config, nil
}

// parseTscFreqMHz returns the TSC (= base) frequency in MHz. Prefers the
// TSC_FREQ_MHZ env var; falls back to /proc/cpuinfo. Returns 0 when neither
// source produces a usable value, in which case the windowed sampler will
// emit Freq.OK=false for every sample.
func parseTscFreqMHz() float64 {
	if v := os.Getenv("TSC_FREQ_MHZ"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			return f
		}
		log.Warn().Str("TSC_FREQ_MHZ", v).Msg("invalid TSC_FREQ_MHZ; falling back to /proc/cpuinfo")
	}

	f, err := os.Open("/proc/cpuinfo")
	if err != nil {
		log.Warn().Err(err).Msg("cannot read /proc/cpuinfo for tsc_freq fallback")
		return 0
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		// Try "model name : ... @ 2.40GHz" form first (more reliable than
		// "cpu MHz" which reports the live frequency, not the base).
		if strings.HasPrefix(line, "model name") {
			at := strings.Index(line, "@")
			if at > 0 {
				rest := strings.TrimSpace(line[at+1:])
				ghzStr := strings.TrimSuffix(strings.TrimSuffix(rest, "Hz"), "GHz")
				ghzStr = strings.TrimSuffix(ghzStr, "GHZ")
				ghzStr = strings.TrimSpace(ghzStr)
				if ghz, err := strconv.ParseFloat(ghzStr, 64); err == nil && ghz > 0 {
					return ghz * 1000.0
				}
			}
		}
	}

	// Re-scan for "cpu MHz" as last resort. This is the live frequency on most
	// kernels; on hosts without governor scaling it equals the base frequency.
	if _, err := f.Seek(0, 0); err == nil {
		scanner = bufio.NewScanner(f)
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "cpu MHz") {
				colon := strings.Index(line, ":")
				if colon > 0 {
					rest := strings.TrimSpace(line[colon+1:])
					if mhz, err := strconv.ParseFloat(rest, 64); err == nil && mhz > 0 {
						return mhz
					}
				}
				break
			}
		}
	}

	log.Warn().Msg("could not derive TSC freq from env or /proc/cpuinfo")
	return 0
}

// parseFloatEnv returns the float value of the named env var or def.
func parseFloatEnv(name string, def float64) float64 {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		log.Warn().Str(name, v).Float64("default", def).Err(err).Msg("invalid env value, using default")
		return def
	}
	return f
}

// parseDurationSecondsEnv reads an integer-seconds env var into a Duration.
func parseDurationSecondsEnv(name string, def time.Duration) time.Duration {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		log.Warn().Str(name, v).Dur("default", def).Msg("invalid env value, using default")
		return def
	}
	return time.Duration(n) * time.Second
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

// SetupContinuousSampling initializes long-running windowed sampling
// Runs for a very long time and writes data periodically
func SetupContinuousSampling(serviceName string, iterationID int) (WindowedSampler, interceptor.TimingAggregator, chan *interceptor.WindowTimingStats, error) {
	// Parse configuration (same as SetupWindowedSampling but with long duration)
	config, err := ParseWindowedSamplingConfig(serviceName, iterationID)
	if err != nil {
		return nil, nil, nil, err
	}
	
	// Override to run for 24 hours instead of EXPERIMENT_DURATION
	config.RunDuration = 24 * time.Hour
	
	// Create timing stats channel
	timingStatsChannel := make(chan *interceptor.WindowTimingStats, 100)
	config.TimingStatsChannel = timingStatsChannel
	
	// Create windowed sampler
	sampler := NewWindowedSampler()
	
	// Create timing aggregator
	timingConfig := interceptor.TimingConfig{
		EnableTiming:       true,
		ServiceName:        serviceName,
		EnableWindowed:     true,
		WindowInterval:     config.WindowInterval,
		WindowStatsChannel: timingStatsChannel,
	}
	timingAgg := interceptor.NewRingBufferTimingAggregator(timingConfig)
	
	// Start sampler
	ctx := context.Background()
	if err := sampler.StartRun(ctx, *config); err != nil {
		return nil, nil, nil, err
	}
	
	log.Info().
		Str("service", serviceName).
		Int("iteration", iterationID).
		Dur("actual_run_duration", config.RunDuration).
		Dur("window_interval", config.WindowInterval).
		Strs("perf_events", config.PerfEvents).
		Msg("Continuous sampling initialized (24h duration)")
	
	return sampler, timingAgg, timingStatsChannel, nil
}

