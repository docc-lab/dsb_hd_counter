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
	
	// Input channel for timing data (non-blocking writes)
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
	
	// Create large buffered channel to decouple writers from ring buffer
	// Channel size should be > typical requests per window
	timingDataChan := make(chan TimingData, 10000)
	
	agg := &RingBufferTimingAggregator{
		serviceName:        config.ServiceName,
		ringBuffer:         NewLockFreeRingBuffer(bufferSize, 100), // Threshold doesn't matter anymore
		windowInterval:     config.WindowInterval,
		windowStatsChannel: config.WindowStatsChannel,
		timingDataChan:     timingDataChan,
		ctx:                ctx,
		cancel:             cancel,
	}
	
	// Start consumer goroutine to read from channel and push to ring buffer
	agg.wg.Add(1)
	go agg.consumeTimingData()
	
	// Start periodic window flush loop
	agg.wg.Add(1)
	go agg.windowedFlushLoop()
	
	log.Info().
		Str("service", config.ServiceName).
		Dur("window_interval", config.WindowInterval).
		Uint64("buffer_size", bufferSize).
		Int("channel_size", cap(timingDataChan)).
		Msg("Started ring-buffer timing aggregator with channel")
	
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

// AddTimingData adds timing data via buffered channel (NON-BLOCKING!)
// This is called by MANY concurrent gRPC requests
// Uses non-blocking channel send to avoid any delays in request path
func (rba *RingBufferTimingAggregator) AddTimingData(data TimingData) {
	// Non-blocking send to channel
	select {
	case rba.timingDataChan <- data:
		// Sent successfully, request can return immediately
	default:
		// Channel full, drop this measurement
		// This is better than blocking the request
	}
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
func (rba *RingBufferTimingAggregator) flushWindow() {
	// Pop all data accumulated in this window (advances tail pointer)
	// This is the ONLY place we read from the ring buffer
	windowData := rba.ringBuffer.PopAll()
	
	if len(windowData) == 0 {
		// No data in this window, send empty stats
		if rba.windowStatsChannel != nil {
			select {
			case rba.windowStatsChannel <- &WindowTimingStats{RequestCount: 0}:
			default:
			}
		}
		return
	}
	
	// Calculate aggregated window statistics directly from ring buffer data
	stats := rba.calculateWindowStats(windowData)
	
	// Send aggregated stats to windowed sampler (non-blocking)
	if rba.windowStatsChannel != nil {
		select {
		case rba.windowStatsChannel <- stats:
			// Sent successfully
		default:
			log.Warn().
				Str("service", rba.serviceName).
				Int("request_count", stats.RequestCount).
				Msg("Window stats channel full, dropping window stats")
		}
	}
}

// calculateWindowStats calculates statistics for one window
func (rba *RingBufferTimingAggregator) calculateWindowStats(data []TimingData) *WindowTimingStats {
	if len(data) == 0 {
		return &WindowTimingStats{RequestCount: 0}
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

