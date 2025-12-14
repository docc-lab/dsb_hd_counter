package interceptor

import (
	"context"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/rs/zerolog/log"
)

// RingBufferTimingAggregator uses lock-free ring buffer for high-throughput timing collection
type RingBufferTimingAggregator struct {
	serviceName        string
	ringBuffer         *LockFreeRingBuffer
	windowInterval     time.Duration
	windowStatsChannel chan *WindowTimingStats
	
	// Input channel for timing data (both arrivals and completions)
	// Arrival events: IsArrival=true, minimal data
	// Completion events: IsArrival=false, full timing data
	timingDataChan     chan TimingData
	
	// Flush control
	windowTicker       *time.Ticker
	ctx                context.Context
	cancel             context.CancelFunc
	wg                 sync.WaitGroup
}

// NewRingBufferTimingAggregator creates a new ring-buffer-based aggregator
func NewRingBufferTimingAggregator(config TimingConfig) *RingBufferTimingAggregator {
	ctx, cancel := context.WithCancel(context.Background())
	
	// Determine buffer size from environment or use larger default
	// Large buffer to hold multiple windows of data without overflow
	bufferSize := parseBufferSize(os.Getenv("TIMING_BUFFER_SIZE"), 16384)
	
	// Create VERY large buffered channel - large enough that it never fills
	// At 1000 req/s, 100k capacity = 100 seconds of buffering
	// Consumer should keep up, so this provides massive headroom
	timingDataChan := make(chan TimingData, 100000)
	
	agg := &RingBufferTimingAggregator{
		serviceName:        config.ServiceName,
		ringBuffer:         NewLockFreeRingBuffer(bufferSize, 100), // Threshold doesn't matter anymore
		windowInterval:     config.WindowInterval,
		windowStatsChannel: config.WindowStatsChannel,
		timingDataChan:     timingDataChan,
		ctx:                ctx,
		cancel:             cancel,
	}
	
	// Start multiple consumer goroutines for parallel processing
	// Multiple consumers to ensure channel is drained quickly
	numConsumers := 4
	for i := 0; i < numConsumers; i++ {
		agg.wg.Add(1)
		go agg.consumeTimingData()
	}
	
	// Start periodic window flush loop
	agg.wg.Add(1)
	go agg.windowedFlushLoop()
	
	log.Info().
		Str("service", config.ServiceName).
		Dur("window_interval", config.WindowInterval).
		Uint64("buffer_size", bufferSize).
		Int("channel_size", cap(timingDataChan)).
		Int("num_consumers", numConsumers).
		Msg("Started ring-buffer timing aggregator with parallel consumers")
	
	return agg
}

// parseBufferSize parses buffer size from string, ensures power of 2
func parseBufferSize(sizeStr string, defaultSize uint64) uint64 {
	if sizeStr == "" {
		return defaultSize
	}
	
	size, err := strconv.ParseUint(sizeStr, 10, 64)
	if err != nil {
		log.Warn().
			Str("value", sizeStr).
			Uint64("default", defaultSize).
			Msg("Invalid buffer size, using default")
		return defaultSize
	}
	
	// Ensure power of 2
	if size&(size-1) != 0 {
		// Round up to next power of 2
		size--
		size |= size >> 1
		size |= size >> 2
		size |= size >> 4
		size |= size >> 8
		size |= size >> 16
		size |= size >> 32
		size++
		
		log.Info().
			Uint64("rounded_size", size).
			Msg("Rounded buffer size to next power of 2")
	}
	
	return size
}

func parseFlushThreshold(thresholdStr string, defaultPct int) int {
	if thresholdStr == "" {
		return defaultPct
	}
	
	threshold, err := strconv.Atoi(thresholdStr)
	if err != nil || threshold < 0 || threshold > 100 {
		return defaultPct
	}
	
	return threshold
}

// RecordArrival records an arrival event to the ring buffer
// Called by server interceptor at request start (arrival)
// Pushes a minimal event (IsArrival=true) through the same channel as completions
func (rba *RingBufferTimingAggregator) RecordArrival() {
	// Create minimal arrival event
	arrivalEvent := TimingData{
		IsArrival: true,
		Timestamp: time.Now(),
	}
	
	// Push through the same channel as completions
	// Non-blocking send with same huge buffer (100k capacity)
	rba.timingDataChan <- arrivalEvent
}

// AddTimingData adds timing data via buffered channel (BLOCKING but fast!)
// This is called by MANY concurrent gRPC requests
// Uses blocking send to huge channel - faster than select/default
// Channel is large enough (100k) that blocking is extremely rare
func (rba *RingBufferTimingAggregator) AddTimingData(data TimingData) {
	// Blocking send to channel
	// With 100k buffer and multiple fast consumers, this never blocks in practice
	// This is FASTER than select because it avoids the select overhead
	rba.timingDataChan <- data
}

// consumeTimingData runs in a dedicated goroutine to consume from channel
// and push to ring buffer, decoupling request path from ring buffer operations
func (rba *RingBufferTimingAggregator) consumeTimingData() {
	defer rba.wg.Done()
	
	for {
		select {
		case data := <-rba.timingDataChan:
			// Push to ring buffer (may retry with CAS, but doesn't block requests)
			rba.ringBuffer.TryPush(data)
			
		case <-rba.ctx.Done():
			// Drain remaining items from channel
			for {
				select {
				case data := <-rba.timingDataChan:
					rba.ringBuffer.TryPush(data)
				default:
					return
				}
			}
		}
	}
}

// windowedFlushLoop periodically computes and outputs window stats at fixed interval
func (rba *RingBufferTimingAggregator) windowedFlushLoop() {
	defer rba.wg.Done()
	
	rba.windowTicker = time.NewTicker(rba.windowInterval)
	defer rba.windowTicker.Stop()
	
	for {
		select {
		case <-rba.windowTicker.C:
			// END OF WINDOW: compute and output stats
			rba.flushWindow()
			
		case <-rba.ctx.Done():
			// Final flush on shutdown
			rba.flushWindow()
			return
		}
	}
}

// flushWindow is called at END OF WINDOW INTERVAL
// It reads all data accumulated since last window and advances tail pointer
// Separates arrival events from completion events by checking IsArrival flag
func (rba *RingBufferTimingAggregator) flushWindow() {
	// Pop all events (both arrivals and completions) from ring buffer
	windowData := rba.ringBuffer.PopAll()
	
	if len(windowData) == 0 {
		// No activity in this window, send empty stats
		if rba.windowStatsChannel != nil {
			select {
			case rba.windowStatsChannel <- &WindowTimingStats{
				ArrivalCount: 0,
				RequestCount: 0,
			}:
			default:
			}
		}
		return
	}
	
	// Separate arrivals from completions
	arrivalCount := 0
	completions := make([]TimingData, 0, len(windowData))
	
	for _, event := range windowData {
		if event.IsArrival {
			arrivalCount++
		} else {
			completions = append(completions, event)
		}
	}
	
	// Calculate aggregated window statistics from completion data
	stats := rba.calculateWindowStats(completions, arrivalCount)
	
	// Send aggregated stats to windowed sampler (non-blocking)
	if rba.windowStatsChannel != nil {
		select {
		case rba.windowStatsChannel <- stats:
			// Sent successfully
		default:
			log.Warn().
				Str("service", rba.serviceName).
				Int("arrival_count", stats.ArrivalCount).
				Int("completion_count", stats.RequestCount).
				Msg("Window stats channel full, dropping window stats")
		}
	}
}

// calculateWindowStats calculates statistics for one window
// arrivalCount: number of requests that arrived (started) in this window
// data: timing data for requests that completed in this window
func (rba *RingBufferTimingAggregator) calculateWindowStats(data []TimingData, arrivalCount int) *WindowTimingStats {
	if len(data) == 0 {
		// No completions, but may have arrivals (requests still in flight)
		return &WindowTimingStats{
			ArrivalCount: arrivalCount,
			RequestCount: 0,
		}
	}
	
	processingTimes := make([]time.Duration, len(data))
	totalTimes := make([]time.Duration, len(data))
	blockingTimes := make([]time.Duration, len(data))
	
	for i, td := range data {
		processingTimes[i] = td.ProcessingTime
		totalTimes[i] = td.TotalTime
		blockingTimes[i] = td.BlockingTime
	}
	
	return &WindowTimingStats{
		ArrivalCount:   arrivalCount,
		RequestCount:   len(data),
		ProcessingTime: calculateWindowDurationStats(processingTimes),
		TotalTime:      calculateWindowDurationStats(totalTimes),
		BlockingTime:   calculateWindowDurationStats(blockingTimes),
	}
}

// Stop stops the aggregator and flushes remaining data
func (rba *RingBufferTimingAggregator) Stop() {
	rba.cancel()
	rba.wg.Wait()
	
	// Log final statistics
	stats := rba.ringBuffer.GetStats()
	log.Info().
		Str("service", rba.serviceName).
		Uint64("total_pushed", stats.TotalPushed).
		Uint64("total_dropped", stats.Dropped).
		Float64("drop_rate", float64(stats.Dropped)*100/float64(stats.TotalPushed+stats.Dropped)).
		Msg("Stopped ring-buffer timing aggregator")
}

// GetBufferStats returns current buffer statistics
func (rba *RingBufferTimingAggregator) GetBufferStats() RingBufferStats {
	return rba.ringBuffer.GetStats()
}

