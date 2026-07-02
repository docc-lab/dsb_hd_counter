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
	// Kill switch for the per-window MSR/frequency-utilization path. Each window
	// (100ms) msr_reader_sample() pread()s MSRs across node-wide cores -- a heavy
	// blocking CGO call that contends on the pod's pinned request cores and is the
	// prime suspect for the sampler-induced request stalls ("context canceled").
	// Set WINDOWED_FREQ_ENABLED=false to drop the whole MSR path (freq_util is not
	// needed for the intrinsic latency-vs-arrival-rate curve); everything else
	// (perf counters, timing, arrival rate) is unaffected. Forcing tscFreqMHz=0
	// makes StartRun skip msr_reader_init (see windowed_sampler.go:237).
	if !parseBoolEnv("WINDOWED_FREQ_ENABLED", true) {
		tscFreqMHz = 0
		log.Warn().Msg("WINDOWED_FREQ_ENABLED=false: per-window MSR/frequency sampling disabled (freq fields ok=false)")
	}
	c0Threshold := parseFloatEnv("C0_ACTIVE_THRESHOLD", 0.05)
	msrRefresh := parseDurationSecondsEnv("MSR_TURBO_REFRESH_EVERY_S", 10*time.Second)

	// Trailing sliding-window arrival-rate horizons. Defaults are 1.0 s and
	// 3.0 s; operators can tune via ARRIVAL_RPS_T1_SEC / ARRIVAL_RPS_T2_SEC.
	// See timing_interceptor_ringbuffer.go arrivalRateSmoother for semantics.
	arrivalRpsT1 := parseFloatEnv("ARRIVAL_RPS_T1_SEC", 1.0)
	arrivalRpsT2 := parseFloatEnv("ARRIVAL_RPS_T2_SEC", 3.0)

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
		ArrivalRpsT1:            time.Duration(arrivalRpsT1 * float64(time.Second)),
		ArrivalRpsT2:            time.Duration(arrivalRpsT2 * float64(time.Second)),
	}

	return config, nil
}

// parseTscFreqMHz returns the TSC (= base) frequency in MHz. Sources, in
// preference order:
//   1. TSC_FREQ_MHZ env var (operator override)
//   2. /sys/devices/system/cpu/cpu0/cpufreq/base_frequency (intel_pstate only;
//      missing on acpi-cpufreq hosts)
//   3. /proc/cpuinfo "model name : ... @ X.YYGHz" (works on every Intel/AMD
//      CPU; the @-frequency is the *base* frequency by spec)
//   4. /proc/cpuinfo "cpu MHz" (LIVE frequency, last resort, unreliable)
// Returns 0 when no source produces a usable value, in which case the
// windowed sampler emits Freq.OK=false for every sample.
func parseTscFreqMHz() float64 {
	// 1) Operator override
	if v := os.Getenv("TSC_FREQ_MHZ"); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
			return f
		}
		log.Warn().Str("TSC_FREQ_MHZ", v).Msg("invalid TSC_FREQ_MHZ; trying sysfs/cpuinfo")
	}

	// 2) intel_pstate sysfs (kHz, exact). On acpi-cpufreq this file is absent.
	if data, err := os.ReadFile("/sys/devices/system/cpu/cpu0/cpufreq/base_frequency"); err == nil {
		if khz, perr := strconv.ParseFloat(strings.TrimSpace(string(data)), 64); perr == nil && khz > 0 {
			return khz / 1000.0
		}
	}

	// 3) /proc/cpuinfo "model name : ... @ 2.40GHz" form. Robust suffix parse.
	f, err := os.Open("/proc/cpuinfo")
	if err != nil {
		log.Warn().Err(err).Msg("cannot read /proc/cpuinfo for tsc_freq fallback")
		return 0
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "model name") {
			continue
		}
		at := strings.Index(line, "@")
		if at < 0 {
			continue
		}
		rest := strings.TrimSpace(line[at+1:])
		// Detect unit by suffix (case-insensitive) BEFORE stripping, so we
		// don't accidentally strip "Hz" off "GHz" and break the number parse.
		var multToMHz float64
		var numStr string
		restLower := strings.ToLower(rest)
		switch {
		case strings.HasSuffix(restLower, "ghz"):
			multToMHz = 1000.0
			numStr = rest[:len(rest)-3]
		case strings.HasSuffix(restLower, "mhz"):
			multToMHz = 1.0
			numStr = rest[:len(rest)-3]
		case strings.HasSuffix(restLower, "hz"):
			multToMHz = 1.0 / 1_000_000.0
			numStr = rest[:len(rest)-2]
		default:
			continue
		}
		if v, perr := strconv.ParseFloat(strings.TrimSpace(numStr), 64); perr == nil && v > 0 {
			return v * multToMHz
		}
	}

	// 4) Last resort: "cpu MHz" line (LIVE frequency; varies with P-state).
	// Logged loudly so misleading freq numbers are easy to diagnose.
	if _, err := f.Seek(0, 0); err == nil {
		scanner = bufio.NewScanner(f)
		for scanner.Scan() {
			line := scanner.Text()
			if !strings.HasPrefix(line, "cpu MHz") {
				continue
			}
			colon := strings.Index(line, ":")
			if colon <= 0 {
				continue
			}
			rest := strings.TrimSpace(line[colon+1:])
			if mhz, perr := strconv.ParseFloat(rest, 64); perr == nil && mhz > 0 {
				log.Warn().Float64("cpu_mhz_live", mhz).
					Msg("falling back to /proc/cpuinfo 'cpu MHz' (LIVE freq, not base); set TSC_FREQ_MHZ env to fix")
				return mhz
			}
			break
		}
	}

	log.Warn().Msg("could not derive TSC freq from env, sysfs, or /proc/cpuinfo")
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

// parseBoolEnv reads a boolean-ish env var (1/0, true/false, yes/no, on/off,
// case-insensitive). Empty or unrecognized -> def.
func parseBoolEnv(name string, def bool) bool {
	v := strings.TrimSpace(strings.ToLower(os.Getenv(name)))
	switch v {
	case "":
		return def
	case "1", "true", "yes", "on", "y", "t":
		return true
	case "0", "false", "no", "off", "n", "f":
		return false
	default:
		log.Warn().Str(name, v).Bool("default", def).Msg("invalid bool env value, using default")
		return def
	}
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
		ArrivalRpsT1:       config.ArrivalRpsT1,
		ArrivalRpsT2:       config.ArrivalRpsT2,
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
		ArrivalRpsT1:       config.ArrivalRpsT1,
		ArrivalRpsT2:       config.ArrivalRpsT2,
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

