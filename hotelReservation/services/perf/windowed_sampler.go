package perf

/*
#cgo LDFLAGS: -L${SRCDIR} -lperf_api_windowed -lmsr_reader
#include "perf_api_windowed.h"
#include "msr_reader.h"
#include <stdlib.h>
*/
import "C"
import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
	"github.com/rs/zerolog/log"
)

// WindowedSampler continuously samples perf counters at fixed intervals
type WindowedSampler interface {
	StartRun(ctx context.Context, config RunConfig) error
	StopRun() (*RunData, error)
	Start(ctx context.Context) error // For continuous mode
	Stop() error                      // For continuous mode
	GetCurrentSample() *Sample
}

// RunConfig defines one experiment iteration's sampling configuration
type RunConfig struct {
	ServiceName      string        // Service name (e.g., "frontend")
	IterationID      int           // Matches ITERATIONS from data-collector.sh
	RunDuration      time.Duration // Matches EXPERIMENT_DURATION from data-collector.sh
	WindowInterval   time.Duration // Sampling interval (e.g., 100ms, 500ms, 1s)
	PerfEvents       []string      // Events: ["cycles", "instructions", "cache-misses", ...]
	OutputDir        string        // Where to write run data
	TimingStatsChannel chan *interceptor.WindowTimingStats // Channel to receive timing stats

	// Frequency utilization configuration (see actual-frequency.md). When
	// TscFreqMHz is 0 or the MSR reader fails to init, freq fields on each
	// Sample are emitted with OK=false and the rest of the fields zeroed.
	TscFreqMHz             float64       // CPU TSC frequency (= base frequency); read from env or /proc/cpuinfo
	C0ActiveThreshold      float64       // Fraction in [0,1] above which a core counts as active (default 0.05)
	MsrTurboRefreshInterval time.Duration // How often to re-read MSR 0x1AD (default 10s)

	// Trailing sliding-window arrival-rate horizons. Each WindowTimingStats
	// emitted on the timing channel will carry an ArrivalRpsT1 / ArrivalRpsT2
	// field smoothed over these horizons. Zero -> library default
	// (1 s for T1, 3 s for T2). Operators can override via ARRIVAL_RPS_T1_SEC
	// and ARRIVAL_RPS_T2_SEC env vars (parsed in integration.go).
	ArrivalRpsT1 time.Duration
	ArrivalRpsT2 time.Duration
}

// Sample represents one snapshot at a window boundary
type Sample struct {
	SampleID      int                   `json:"sample_id"`      // Monotonic within run
	Timestamp     time.Time             `json:"timestamp"`
	OffsetMs      int64                 `json:"offset_ms"`      // Milliseconds from run start
	PerfCounters  map[string]uint64     `json:"perf_counters"`  // Cumulative values
	PerfDeltas    map[string]uint64     `json:"perf_deltas"`    // Delta from previous sample
	TimingWindow  *interceptor.WindowTimingStats `json:"timing_window"`  // Timing stats for this window
	Freq          FreqSample            `json:"freq"`           // Frequency utilization for this window
}

// FreqSample carries per-window CPU frequency utilization fields.
//
// actual_freq_mhz is computed in-process from perf-attached cycles/ref-cycles
// (immune to co-scheduling). current_max_mhz is looked up from MSR 0x1AD
// indexed by the count of node-wide cores in C0 over C0ActiveThreshold,
// derived from MSR 0x30A + MSR 0x10. See actual-frequency.md for derivation.
type FreqSample struct {
	OK            bool    `json:"ok"`
	ActualFreqMHz float64 `json:"actual_freq_mhz"`
	CurrentMaxMHz uint32  `json:"current_max_mhz"`
	ActiveN       int     `json:"active_n"`
	FreqUtilPct   float64 `json:"freq_util_pct"`
	TurboOn       bool    `json:"turbo_on"`
	TscFreqMHz    float64 `json:"tsc_freq_mhz"`
}

// Note: WindowTimingStats and WindowDurationStats are defined in interceptor package
// and imported above to avoid duplication

// RunData contains all samples from one iteration/run
type RunData struct {
	ServiceName    string        `json:"service_name"`
	IterationID    int           `json:"iteration_id"`
	RunStart       time.Time     `json:"run_start"`
	RunEnd         time.Time     `json:"run_end"`
	RunDurationMs  int64         `json:"run_duration_ms"`
	WindowInterval int64         `json:"window_interval_ms"`
	SampleCount    int           `json:"sample_count"`
	PerfEvents     []string      `json:"perf_events"`
	Samples        []Sample      `json:"samples"`
	Aggregates     *RunAggregates `json:"aggregates"`
}

// RunAggregates provides statistics across entire run
type RunAggregates struct {
	TotalRequests int                `json:"total_requests"`
	PerfTotals    map[string]uint64  `json:"perf_totals"`  // Total per event
	PerfMean      map[string]float64 `json:"perf_mean"`    // Mean delta per sample
	PerfRate      map[string]float64 `json:"perf_rate"`    // Events per second
	TimingOverall *DurationStats     `json:"timing_overall"` // Overall timing stats
	FreqUtil      *FreqUtilStats     `json:"freq_util"`    // Frequency utilization rollup
	ArrivalRate   *ArrivalRateStats  `json:"arrival_rate"` // Sliding-window arrival rate rollup (T1, T2)
}

// ArrivalRateStats aggregates the per-sample sliding-window arrival rate
// (ArrivalRps1s, ArrivalRps3s on each sample's TimingWindow) across an
// entire run. The horizons are echoed back from the resolved smoother
// configuration so consumers don't have to re-derive them from env vars.
//
// Mean / p50 / p99 are computed across all samples that have a non-nil
// TimingWindow. Bootstrap windows (first ~T seconds of the run) ARE included
// — they're unbiased estimates over a shorter elapsed window, not garbage.
type ArrivalRateStats struct {
	HorizonT1Sec float64 `json:"horizon_t1_sec"`
	HorizonT2Sec float64 `json:"horizon_t2_sec"`
	Rps1sMean    float64 `json:"rps_1s_mean"`
	Rps1sP50     float64 `json:"rps_1s_p50"`
	Rps1sP99     float64 `json:"rps_1s_p99"`
	Rps3sMean    float64 `json:"rps_3s_mean"`
	Rps3sP50     float64 `json:"rps_3s_p50"`
	Rps3sP99     float64 `json:"rps_3s_p99"`
	SampleCount  int     `json:"sample_count"`
}

// FreqUtilStats provides aggregated frequency utilization stats across a run.
// Mean/p50/p99 ignore samples where Freq.OK is false. SamplesWithFreq +
// SamplesWithoutFreq == len(samples).
type FreqUtilStats struct {
	SamplesWithFreq    int     `json:"samples_with_freq"`
	SamplesWithoutFreq int     `json:"samples_without_freq"`
	ActualFreqMHzMean  float64 `json:"actual_freq_mhz_mean"`
	FreqUtilPctMean    float64 `json:"freq_util_pct_mean"`
	FreqUtilPctP50     float64 `json:"freq_util_pct_p50"`
	FreqUtilPctP99     float64 `json:"freq_util_pct_p99"`
	PctSamplesInTurbo  float64 `json:"pct_samples_in_turbo"`
	ActiveNMean        float64 `json:"active_n_mean"`
	ActiveNMax         int     `json:"active_n_max"`
	TscFreqMHz         float64 `json:"tsc_freq_mhz"`
	C0ActiveThreshold  float64 `json:"c0_active_threshold"`
}

// DurationStats for overall timing aggregation
type DurationStats struct {
	MinNs  int64 `json:"min_ns"`
	MaxNs  int64 `json:"max_ns"`
	MeanNs int64 `json:"mean_ns"`
	P50Ns  int64 `json:"p50_ns"`
	P60Ns  int64 `json:"p60_ns"`
	P70Ns  int64 `json:"p70_ns"`
	P75Ns  int64 `json:"p75_ns"`
	P80Ns  int64 `json:"p80_ns"`
	P90Ns  int64 `json:"p90_ns"`
	P99Ns  int64 `json:"p99_ns"`
	Count  int   `json:"count"`
}

// windowedSampler implementation
type windowedSampler struct {
	config         RunConfig
	perfHandle     *C.perf_window_handle_t
	msrReader      *C.msr_reader_t // nil if MSR access unavailable; freq fields then OK=false
	timingChan     chan *interceptor.WindowTimingStats
	samples        []Sample
	sampleCounter  atomic.Int32
	runStartTime   time.Time
	ticker         *time.Ticker
	ctx            context.Context
	cancel         context.CancelFunc
	mu             sync.Mutex
	wg             sync.WaitGroup
	sampleFile     *os.File // For streaming samples to file
	streamMode     bool     // If true, append each sample immediately
}

// NewWindowedSampler creates a new windowed sampler instance
func NewWindowedSampler() WindowedSampler {
	return &windowedSampler{}
}

// StartRun begins windowed sampling for one experiment iteration
func (ws *windowedSampler) StartRun(ctx context.Context, config RunConfig) error {
	ws.config = config
	ws.runStartTime = time.Now()
	ws.samples = make([]Sample, 0, int(config.RunDuration/config.WindowInterval)+10)
	ws.sampleCounter.Store(0)
	ws.timingChan = config.TimingStatsChannel
	
	if ws.timingChan == nil {
		ws.timingChan = make(chan *interceptor.WindowTimingStats, 100)
	}
	
	// Enable stream mode for long-running sampling (>1 hour)
	ws.streamMode = config.RunDuration > time.Hour
	
	// Create context with timeout
	ws.ctx, ws.cancel = context.WithTimeout(ctx, config.RunDuration)
	
	// Convert event names to C string
	eventNamesStr := ""
	for i, event := range config.PerfEvents {
		if i > 0 {
			eventNamesStr += ","
		}
		eventNamesStr += event
	}
	cEventNames := C.CString(eventNamesStr)
	defer C.free(unsafe.Pointer(cEventNames))
	
	// Get CPU set from environment (e.g., "0,1,2")
	cpuSet := os.Getenv("CPU_SET")
	if cpuSet == "" {
		cpuSet = "-1" // Default: all CPUs
	}
	cCpuSet := C.CString(cpuSet)
	defer C.free(unsafe.Pointer(cCpuSet))
	
	// Initialize perf counters with CPU set
	ws.perfHandle = C.perf_window_init(cEventNames, cCpuSet)
	if ws.perfHandle == nil {
		return fmt.Errorf("failed to initialize perf counters for events: %s on CPUs: %s", eventNamesStr, cpuSet)
	}

	// Initialize the MSR reader for per-window frequency utilization. This is
	// best-effort: if /dev/cpu/N/msr is not accessible (e.g. the host has not
	// loaded the 'msr' kernel module, or the pod is missing CAP_SYS_RAWIO /
	// the hostPath mount), each Sample.Freq will simply land with OK=false.
	if ws.config.TscFreqMHz > 0 {
		threshold := ws.config.C0ActiveThreshold
		if threshold <= 0 {
			threshold = 0.05
		}
		refreshEvery := 1
		if ws.config.MsrTurboRefreshInterval > 0 && ws.config.WindowInterval > 0 {
			refreshEvery = int(ws.config.MsrTurboRefreshInterval / ws.config.WindowInterval)
			if refreshEvery < 1 {
				refreshEvery = 1
			}
		}
		ws.msrReader = C.msr_reader_init(C.double(threshold), C.int(refreshEvery))
		if ws.msrReader == nil {
			log.Warn().
				Str("service", config.ServiceName).
				Msg("MSR reader init failed; freq fields will be marked ok=false (need 'modprobe msr' on host + CAP_SYS_RAWIO + /dev/cpu hostPath)")
		} else {
			log.Info().
				Str("service", config.ServiceName).
				Int("n_cores", int(C.msr_reader_n_cores(ws.msrReader))).
				Int("n_turbo_bins", int(C.msr_reader_n_turbo_bins(ws.msrReader))).
				Float64("tsc_freq_mhz", ws.config.TscFreqMHz).
				Float64("c0_active_threshold", threshold).
				Int("turbo_refresh_every_n_calls", refreshEvery).
				Msg("MSR reader initialized for frequency utilization")
		}
	} else {
		log.Warn().
			Str("service", config.ServiceName).
			Msg("TSC_FREQ_MHZ not provided; frequency utilization fields disabled (set TSC_FREQ_MHZ env var)")
	}

	log.Info().
		Str("service", config.ServiceName).
		Int("iteration", config.IterationID).
		Dur("run_duration", config.RunDuration).
		Dur("window_interval", config.WindowInterval).
		Strs("perf_events", config.PerfEvents).
		Int("expected_samples", int(config.RunDuration/config.WindowInterval)).
		Bool("stream_mode", ws.streamMode).
		Bool("msr_freq_enabled", ws.msrReader != nil).
		Msg("Started windowed sampling")
	
	// Start sampling loop
	ws.wg.Add(1)
	go ws.samplingLoop()
	
	// Start periodic file flush for stream mode
	if ws.streamMode {
		ws.wg.Add(1)
		go ws.periodicFlushLoop()
	}
	
	return nil
}

// periodicFlushLoop writes samples to disk periodically in stream mode
func (ws *windowedSampler) periodicFlushLoop() {
	defer ws.wg.Done()
	
	flushTicker := time.NewTicker(30 * time.Second) // Flush every 30s
	defer flushTicker.Stop()
	
	for {
		select {
		case <-flushTicker.C:
			ws.mu.Lock()
			if len(ws.samples) > 0 {
				runData := &RunData{
					ServiceName:    ws.config.ServiceName,
					IterationID:    ws.config.IterationID,
					RunStart:       ws.runStartTime,
					RunEnd:         time.Now(),
					RunDurationMs:  time.Since(ws.runStartTime).Milliseconds(),
					WindowInterval: ws.config.WindowInterval.Milliseconds(),
					SampleCount:    len(ws.samples),
					PerfEvents:     ws.config.PerfEvents,
					Samples:        ws.samples,
					Aggregates:     ws.calculateAggregates(),
				}
				if err := ws.writeRunData(runData); err != nil {
					log.Error().Err(err).Msg("Periodic flush failed")
				} else {
					log.Info().
						Int("samples_written", len(ws.samples)).
						Msg("Periodic flush: wrote samples to file")
				}
			}
			ws.mu.Unlock()
			
		case <-ws.ctx.Done():
			return
		}
	}
}

// samplingLoop runs the periodic sampling
func (ws *windowedSampler) samplingLoop() {
	defer ws.wg.Done()
	
	ws.ticker = time.NewTicker(ws.config.WindowInterval)
	defer ws.ticker.Stop()
	
	for {
		select {
		case <-ws.ticker.C:
			ws.takeSample()
			
		case <-ws.ctx.Done():
			// Take final sample
			ws.takeSample()
			log.Info().
				Str("service", ws.config.ServiceName).
				Int("samples_taken", len(ws.samples)).
				Msg("Windowed sampling loop ended")
			return
		}
	}
}

// takeSample captures one sample at a window boundary
func (ws *windowedSampler) takeSample() {
	sampleID := int(ws.sampleCounter.Add(1))
	now := time.Now()
	
	// Read perf counters via CGO
	perfCounters, perfDeltas := ws.readPerfCounters()
	
	// Get timing stats for this window (non-blocking)
	var timingStats *interceptor.WindowTimingStats
	select {
	case timingStats = <-ws.timingChan:
		// Got timing data
	default:
		// No timing data yet, use empty stats
		timingStats = &interceptor.WindowTimingStats{
			ArrivalCount: 0,
			RequestCount: 0,
		}
	}

	freq := ws.readFreqSample(perfDeltas)

	sample := Sample{
		SampleID:     sampleID,
		Timestamp:    now,
		OffsetMs:     now.Sub(ws.runStartTime).Milliseconds(),
		PerfCounters: perfCounters,
		PerfDeltas:   perfDeltas,
		TimingWindow: timingStats,
		Freq:         freq,
	}
	
	ws.mu.Lock()
	ws.samples = append(ws.samples, sample)
	ws.mu.Unlock()
	
	// Log sample for debugging (can be disabled in production)
	if sampleID%10 == 0 { // Log every 10th sample
		log.Debug().
			Str("service", ws.config.ServiceName).
			Int("sample_id", sampleID).
			Int64("offset_ms", sample.OffsetMs).
			Int("requests", timingStats.RequestCount).
			Msg("Windowed sample taken")
	}
}

// readFreqSample reads MSR-derived per-window frequency utilization, combines
// it with the perf cycles/ref-cycles ratio, and returns a populated FreqSample.
// Returns FreqSample{OK:false} if the MSR reader is unavailable, the MSR reads
// failed this tick, or ref-cycles is missing/zero.
func (ws *windowedSampler) readFreqSample(perfDeltas map[string]uint64) FreqSample {
	if ws.msrReader == nil || ws.config.TscFreqMHz <= 0 {
		return FreqSample{OK: false, TscFreqMHz: ws.config.TscFreqMHz}
	}

	deltaCycles, hasCycles := perfDeltas["cycles"]
	if !hasCycles {
		deltaCycles, hasCycles = perfDeltas["cpu-cycles"]
	}
	deltaRef, hasRef := perfDeltas["ref-cycles"]
	if !hasCycles || !hasRef || deltaRef == 0 {
		return FreqSample{OK: false, TscFreqMHz: ws.config.TscFreqMHz}
	}

	var snap C.freq_snapshot_t
	if rc := C.msr_reader_sample(ws.msrReader, &snap); rc != 0 {
		return FreqSample{OK: false, TscFreqMHz: ws.config.TscFreqMHz}
	}
	if snap.ok == 0 {
		// First call after init primes state, or some pread failed; ok=false
		// is the expected and documented behavior, not a hard error.
		return FreqSample{OK: false, TscFreqMHz: ws.config.TscFreqMHz}
	}

	tsc := ws.config.TscFreqMHz
	actual := float64(deltaCycles) / float64(deltaRef) * tsc

	currentMax := uint32(snap.current_max_mhz)
	var utilPct float64
	if currentMax > 0 {
		utilPct = actual / float64(currentMax) * 100.0
	}

	return FreqSample{
		OK:            true,
		ActualFreqMHz: actual,
		CurrentMaxMHz: currentMax,
		ActiveN:       int(snap.active_n),
		FreqUtilPct:   utilPct,
		TurboOn:       actual > tsc*1.02, // 2% margin over base freq
		TscFreqMHz:    tsc,
	}
}

// readPerfCounters reads current perf counter values via CGO
func (ws *windowedSampler) readPerfCounters() (map[string]uint64, map[string]uint64) {
	counters := make(map[string]uint64)
	deltas := make(map[string]uint64)
	
	eventCount := int(ws.perfHandle.event_count)
	if eventCount == 0 {
		return counters, deltas
	}
	
	// Allocate buffers for C call
	valuesBuf := make([]uint64, eventCount)
	deltasBuf := make([]uint64, eventCount)
	
	// Call C function
	result := C.perf_window_sample(
		ws.perfHandle,
		(*C.uint64_t)(unsafe.Pointer(&valuesBuf[0])),
		(*C.uint64_t)(unsafe.Pointer(&deltasBuf[0])),
	)
	
	if result != 0 {
		log.Error().
			Int("result_code", int(result)).
			Str("service", ws.config.ServiceName).
			Msg("Failed to read perf counters via CGO")
		return counters, deltas
	}
	
	// Map results to event names
	for i := 0; i < eventCount; i++ {
		eventName := C.GoString(C.perf_window_get_event_name(ws.perfHandle, C.int(i)))
		counters[eventName] = valuesBuf[i]
		deltas[eventName] = deltasBuf[i]
	}
	
	return counters, deltas
}

// GetCurrentSample returns the most recent sample
func (ws *windowedSampler) GetCurrentSample() *Sample {
	ws.mu.Lock()
	defer ws.mu.Unlock()
	
	if len(ws.samples) == 0 {
		return nil
	}
	return &ws.samples[len(ws.samples)-1]
}

// Start is an alias for StartRun (for continuous mode compatibility)
func (ws *windowedSampler) Start(ctx context.Context) error {
	// For continuous mode, use a very long duration
	config := RunConfig{
		ServiceName:        "search",
		IterationID:        1,
		RunDuration:        24 * time.Hour,
		WindowInterval:     100 * time.Millisecond,
		PerfEvents:         []string{"cycles", "instructions", "cache-misses"},
		OutputDir:          "/data",
		TimingStatsChannel: ws.timingChan,
	}
	return ws.StartRun(ctx, config)
}

// Stop is an alias for StopRun (for continuous mode compatibility)
func (ws *windowedSampler) Stop() error {
	_, err := ws.StopRun()
	return err
}

// StopRun stops sampling and returns aggregated run data
func (ws *windowedSampler) StopRun() (*RunData, error) {
	// Cancel context and wait for sampling loop to finish
	ws.cancel()
	ws.wg.Wait()
	
	ws.mu.Lock()
	defer ws.mu.Unlock()
	
	// Cleanup perf handle
	if ws.perfHandle != nil {
		C.perf_window_cleanup(ws.perfHandle)
		ws.perfHandle = nil
	}

	// Cleanup MSR reader (no-op if init failed and ws.msrReader stayed nil)
	if ws.msrReader != nil {
		C.msr_reader_free(ws.msrReader)
		ws.msrReader = nil
	}
	
	// Build run data
	runData := &RunData{
		ServiceName:    ws.config.ServiceName,
		IterationID:    ws.config.IterationID,
		RunStart:       ws.runStartTime,
		RunEnd:         time.Now(),
		RunDurationMs:  time.Since(ws.runStartTime).Milliseconds(),
		WindowInterval: ws.config.WindowInterval.Milliseconds(),
		SampleCount:    len(ws.samples),
		PerfEvents:     ws.config.PerfEvents,
		Samples:        ws.samples,
		Aggregates:     ws.calculateAggregates(),
	}
	
	// Write to file
	err := ws.writeRunData(runData)
	if err != nil {
		log.Error().Err(err).Msg("Failed to write run data")
		return runData, err
	}
	
	log.Info().
		Str("service", ws.config.ServiceName).
		Int("iteration", ws.config.IterationID).
		Int("sample_count", runData.SampleCount).
		Int("total_requests", runData.Aggregates.TotalRequests).
		Msg("Windowed sampling completed")
	
	return runData, nil
}

// writeRunData writes run data to JSON file
func (ws *windowedSampler) writeRunData(data *RunData) error {
	filename := fmt.Sprintf("%s/run_data_%s_iter%d.json",
		ws.config.OutputDir,
		ws.config.ServiceName,
		ws.config.IterationID)
	
	// Create output directory if it doesn't exist
	if err := os.MkdirAll(ws.config.OutputDir, 0755); err != nil {
		return fmt.Errorf("failed to create output directory: %w", err)
	}
	
	// Write JSON with indentation for readability
	file, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("failed to create file %s: %w", filename, err)
	}
	defer file.Close()
	
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(data); err != nil {
		return fmt.Errorf("failed to write JSON to %s: %w", filename, err)
	}
	
	log.Info().
		Str("filename", filename).
		Int("sample_count", data.SampleCount).
		Msg("Wrote run data to file")
	
	return nil
}

// calculateAggregates computes statistics from all samples
func (ws *windowedSampler) calculateAggregates() *RunAggregates {
	agg := &RunAggregates{
		PerfTotals: make(map[string]uint64),
		PerfMean:   make(map[string]float64),
		PerfRate:   make(map[string]float64),
	}
	
	if len(ws.samples) == 0 {
		return agg
	}
	
	// Calculate perf aggregates
	for _, sample := range ws.samples {
		agg.TotalRequests += sample.TimingWindow.RequestCount
		
		for event, delta := range sample.PerfDeltas {
			agg.PerfTotals[event] += delta
		}
	}
	
	// Calculate means and rates
	durationSec := ws.config.RunDuration.Seconds()
	sampleCount := float64(len(ws.samples))
	
	for event, total := range agg.PerfTotals {
		agg.PerfMean[event] = float64(total) / sampleCount
		agg.PerfRate[event] = float64(total) / durationSec
	}
	
	// Calculate overall timing stats (aggregate across all samples)
	agg.TimingOverall = ws.aggregateTimingStats()

	// Calculate frequency utilization rollup
	agg.FreqUtil = ws.aggregateFreqStats()

	// Calculate arrival-rate rollup
	agg.ArrivalRate = ws.aggregateArrivalRateStats()

	return agg
}

// aggregateFreqStats computes mean / p50 / p99 of freq_util_pct, mean
// actual_freq, fraction of samples in turbo, and active_n stats. Samples
// where Freq.OK is false are excluded from numerical means but counted in
// SamplesWithoutFreq.
func (ws *windowedSampler) aggregateFreqStats() *FreqUtilStats {
	stats := &FreqUtilStats{
		TscFreqMHz:        ws.config.TscFreqMHz,
		C0ActiveThreshold: ws.config.C0ActiveThreshold,
	}
	if len(ws.samples) == 0 {
		return stats
	}

	utils := make([]float64, 0, len(ws.samples))
	var (
		sumActual    float64
		sumUtil      float64
		sumActiveN   int
		turboCount   int
		activeNMax   int
	)

	for _, s := range ws.samples {
		if !s.Freq.OK {
			stats.SamplesWithoutFreq++
			continue
		}
		stats.SamplesWithFreq++
		sumActual += s.Freq.ActualFreqMHz
		sumUtil += s.Freq.FreqUtilPct
		sumActiveN += s.Freq.ActiveN
		if s.Freq.TurboOn {
			turboCount++
		}
		if s.Freq.ActiveN > activeNMax {
			activeNMax = s.Freq.ActiveN
		}
		utils = append(utils, s.Freq.FreqUtilPct)
	}

	if stats.SamplesWithFreq == 0 {
		return stats
	}

	n := float64(stats.SamplesWithFreq)
	stats.ActualFreqMHzMean = sumActual / n
	stats.FreqUtilPctMean = sumUtil / n
	stats.ActiveNMean = float64(sumActiveN) / n
	stats.ActiveNMax = activeNMax
	stats.PctSamplesInTurbo = float64(turboCount) / n * 100.0

	sort.Float64s(utils)
	stats.FreqUtilPctP50 = percentileFloat64(utils, 0.50)
	stats.FreqUtilPctP99 = percentileFloat64(utils, 0.99)

	return stats
}

// aggregateArrivalRateStats computes mean / p50 / p99 of the trailing
// sliding-window arrival rates across the run. Samples without a
// TimingWindow (which should not happen in practice — takeSample always
// supplies one) are skipped.
//
// The horizons are echoed from the run's RunConfig. They're populated from
// integration.ParseWindowedSamplingConfig (env-var-driven), and propagated
// into the timing aggregator's smoothers, so this is the canonical source.
func (ws *windowedSampler) aggregateArrivalRateStats() *ArrivalRateStats {
	stats := &ArrivalRateStats{
		HorizonT1Sec: ws.config.ArrivalRpsT1.Seconds(),
		HorizonT2Sec: ws.config.ArrivalRpsT2.Seconds(),
	}
	if len(ws.samples) == 0 {
		return stats
	}

	rps1 := make([]float64, 0, len(ws.samples))
	rps3 := make([]float64, 0, len(ws.samples))
	var sum1, sum3 float64

	for _, s := range ws.samples {
		if s.TimingWindow == nil {
			continue
		}
		stats.SampleCount++
		sum1 += s.TimingWindow.ArrivalRps1s
		sum3 += s.TimingWindow.ArrivalRps3s
		rps1 = append(rps1, s.TimingWindow.ArrivalRps1s)
		rps3 = append(rps3, s.TimingWindow.ArrivalRps3s)
	}

	if stats.SampleCount == 0 {
		return stats
	}

	n := float64(stats.SampleCount)
	stats.Rps1sMean = sum1 / n
	stats.Rps3sMean = sum3 / n

	sort.Float64s(rps1)
	sort.Float64s(rps3)
	stats.Rps1sP50 = percentileFloat64(rps1, 0.50)
	stats.Rps1sP99 = percentileFloat64(rps1, 0.99)
	stats.Rps3sP50 = percentileFloat64(rps3, 0.50)
	stats.Rps3sP99 = percentileFloat64(rps3, 0.99)

	return stats
}

// percentileFloat64 returns a linear-interpolated percentile from a sorted slice.
func percentileFloat64(sorted []float64, p float64) float64 {
	if len(sorted) == 0 {
		return 0
	}
	if len(sorted) == 1 {
		return sorted[0]
	}
	rank := p * float64(len(sorted)-1)
	lo := int(rank)
	hi := lo + 1
	if hi >= len(sorted) {
		return sorted[len(sorted)-1]
	}
	frac := rank - float64(lo)
	return sorted[lo] + (sorted[hi]-sorted[lo])*frac
}

// aggregateTimingStats computes overall timing statistics
func (ws *windowedSampler) aggregateTimingStats() *DurationStats {
	var allProcessing, allTotal, allBlocking []int64
	
	for _, sample := range ws.samples {
		if sample.TimingWindow.RequestCount > 0 {
			allProcessing = append(allProcessing, sample.TimingWindow.ProcessingTime.MeanNs)
			allTotal = append(allTotal, sample.TimingWindow.TotalTime.MeanNs)
			allBlocking = append(allBlocking, sample.TimingWindow.BlockingTime.MeanNs)
		}
	}
	
	if len(allProcessing) == 0 {
		return &DurationStats{}
	}
	
	// Calculate min, max, and mean
	var sum int64
	min := allProcessing[0]
	max := allProcessing[0]
	
	for _, val := range allProcessing {
		sum += val
		if val < min {
			min = val
		}
		if val > max {
			max = val
		}
	}
	
	mean := sum / int64(len(allProcessing))
	
	// Sort for percentile calculation
	sortInt64Slice(allProcessing)
	
	return &DurationStats{
		MinNs:  min,
		MaxNs:  max,
		MeanNs: mean,
		P50Ns:  calculatePercentileInt64(allProcessing, 0.50),
		P60Ns:  calculatePercentileInt64(allProcessing, 0.60),
		P70Ns:  calculatePercentileInt64(allProcessing, 0.70),
		P75Ns:  calculatePercentileInt64(allProcessing, 0.75),
		P80Ns:  calculatePercentileInt64(allProcessing, 0.80),
		P90Ns:  calculatePercentileInt64(allProcessing, 0.90),
		P99Ns:  calculatePercentileInt64(allProcessing, 0.99),
		Count:  len(allProcessing),
	}
}

// sortInt64Slice sorts a slice of int64 values in-place
// Uses insertion sort for small slices (<50), standard library sort for larger
func sortInt64Slice(values []int64) {
	n := len(values)
	
	// For small slices, insertion sort is faster due to better cache locality
	if n < 50 {
		for i := 1; i < n; i++ {
			key := values[i]
			j := i - 1
			for j >= 0 && values[j] > key {
				values[j+1] = values[j]
				j--
			}
			values[j+1] = key
		}
		return
	}
	
	// For larger slices, use Go's optimized pdqsort
	sort.Slice(values, func(i, j int) bool {
		return values[i] < values[j]
	})
}

// calculatePercentileInt64 calculates the percentile value from a sorted int64 slice
// Uses linear interpolation between closest ranks
// Assumes values is already sorted
func calculatePercentileInt64(sortedValues []int64, percentile float64) int64 {
	if len(sortedValues) == 0 {
		return 0
	}
	if len(sortedValues) == 1 {
		return sortedValues[0]
	}
	
	// Calculate the rank (position in the sorted array)
	rank := percentile * float64(len(sortedValues)-1)
	lowerIndex := int(rank)
	upperIndex := lowerIndex + 1
	
	// Handle edge case where rank is exactly at the last index
	if upperIndex >= len(sortedValues) {
		return sortedValues[len(sortedValues)-1]
	}
	
	// Linear interpolation between the two closest values
	fraction := rank - float64(lowerIndex)
	lower := sortedValues[lowerIndex]
	upper := sortedValues[upperIndex]
	
	return lower + int64(float64(upper-lower)*fraction)
}

