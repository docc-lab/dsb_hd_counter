package perf

/*
#cgo LDFLAGS: -L${SRCDIR} -lperf_api_windowed
#include "perf_api_windowed.h"
#include <stdlib.h>
*/
import "C"
import (
	"context"
	"encoding/json"
	"fmt"
	"os"
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
}

// Sample represents one snapshot at a window boundary
type Sample struct {
	SampleID      int                   `json:"sample_id"`      // Monotonic within run
	Timestamp     time.Time             `json:"timestamp"`
	OffsetMs      int64                 `json:"offset_ms"`      // Milliseconds from run start
	PerfCounters  map[string]uint64     `json:"perf_counters"`  // Cumulative values
	PerfDeltas    map[string]uint64     `json:"perf_deltas"`    // Delta from previous sample
	TimingWindow  *interceptor.WindowTimingStats `json:"timing_window"`  // Timing stats for this window
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
}

// DurationStats for overall timing aggregation
type DurationStats struct {
	MinNs  int64 `json:"min_ns"`
	MaxNs  int64 `json:"max_ns"`
	MeanNs int64 `json:"mean_ns"`
	P50Ns  int64 `json:"p50_ns"`
	P95Ns  int64 `json:"p95_ns"`
	P99Ns  int64 `json:"p99_ns"`
	Count  int   `json:"count"`
}

// windowedSampler implementation
type windowedSampler struct {
	config         RunConfig
	perfHandle     *C.perf_window_handle_t
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
	
	log.Info().
		Str("service", config.ServiceName).
		Int("iteration", config.IterationID).
		Dur("run_duration", config.RunDuration).
		Dur("window_interval", config.WindowInterval).
		Strs("perf_events", config.PerfEvents).
		Int("expected_samples", int(config.RunDuration/config.WindowInterval)).
		Bool("stream_mode", ws.streamMode).
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
		timingStats = &interceptor.WindowTimingStats{RequestCount: 0}
	}
	
	sample := Sample{
		SampleID:     sampleID,
		Timestamp:    now,
		OffsetMs:     now.Sub(ws.runStartTime).Milliseconds(),
		PerfCounters: perfCounters,
		PerfDeltas:   perfDeltas,
		TimingWindow: timingStats,
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
	
	return agg
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
	
	// For simplicity, return stats based on processing time
	// (In a full implementation, you'd compute percentiles properly)
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
	
	return &DurationStats{
		MinNs:  min,
		MaxNs:  max,
		MeanNs: mean,
		P50Ns:  mean, // Simplified
		P95Ns:  max,  // Simplified
		P99Ns:  max,  // Simplified
		Count:  len(allProcessing),
	}
}

