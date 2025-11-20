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
	
	// Intermediate buffer for window accumulation
	windowData         []TimingData
	windowDataMu       sync.Mutex
	
	// Flush control
	windowTicker       *time.Ticker
	ctx                context.Context
	cancel             context.CancelFunc
	wg                 sync.WaitGroup
}

// NewRingBufferTimingAggregator creates a new ring-buffer-based aggregator
func NewRingBufferTimingAggregator(config TimingConfig) *RingBufferTimingAggregator {
	ctx, cancel := context.WithCancel(context.Background())
	
	// Determine buffer size from environment or use default
	bufferSize := parseBufferSize(os.Getenv("TIMING_BUFFER_SIZE"), 2048)
	flushThreshold := parseFlushThreshold(os.Getenv("TIMING_FLUSH_THRESHOLD"), 80)
	
	agg := &RingBufferTimingAggregator{
		serviceName:        config.ServiceName,
		ringBuffer:         NewLockFreeRingBuffer(bufferSize, flushThreshold),
		windowInterval:     config.WindowInterval,
		windowStatsChannel: config.WindowStatsChannel,
		windowData:         make([]TimingData, 0, bufferSize*2), // Unbounded intermediate buffer
		ctx:                ctx,
		cancel:             cancel,
	}
	
	// Start periodic window flush loop (only this, no threshold monitoring loop)
	agg.wg.Add(1)
	go agg.windowedFlushLoop()
	
	log.Info().
		Str("service", config.ServiceName).
		Dur("window_interval", config.WindowInterval).
		Uint64("buffer_size", bufferSize).
		Uint64("flush_threshold", agg.ringBuffer.flushThreshold).
		Msg("Started ring-buffer timing aggregator")
	
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

// AddTimingData adds timing data to ring buffer (LOCK-FREE!)
// This is called by MANY concurrent gRPC requests
// NO LOCKS - uses atomic CAS operations only
func (rba *RingBufferTimingAggregator) AddTimingData(data TimingData) {
	// Try to push to ring buffer (lock-free)
	success := rba.ringBuffer.TryPush(data)
	
	// If buffer is approaching capacity threshold, trigger proactive drain
	if !success || rba.ringBuffer.ShouldFlush() {
		// Drain ring buffer to intermediate buffer immediately (non-blocking)
		go rba.drainToIntermediateBuffer()
	}
}

// drainToIntermediateBuffer drains ring buffer to intermediate buffer
// This is called when ring buffer reaches threshold (triggered by AddTimingData)
// Moves data from fixed-size ring buffer to unbounded intermediate buffer
func (rba *RingBufferTimingAggregator) drainToIntermediateBuffer() {
	// Pop all items from ring buffer
	items := rba.ringBuffer.PopAll()
	
	if len(items) == 0 {
		return
	}
	
	// Add to intermediate buffer (briefly locked)
	rba.windowDataMu.Lock()
	rba.windowData = append(rba.windowData, items...)
	rba.windowDataMu.Unlock()
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
// It drains any remaining ring buffer data, then computes stats from intermediate buffer
func (rba *RingBufferTimingAggregator) flushWindow() {
	// 1. Drain any remaining data from ring buffer to intermediate buffer
	remaining := rba.ringBuffer.PopAll()
	
	// 2. Lock intermediate buffer and get all window data
	rba.windowDataMu.Lock()
	
	// Add remaining items from ring buffer
	if len(remaining) > 0 {
		rba.windowData = append(rba.windowData, remaining...)
	}
	
	// Get snapshot of all data for this window
	windowData := make([]TimingData, len(rba.windowData))
	copy(windowData, rba.windowData)
	
	// Clear intermediate buffer for next window
	rba.windowData = rba.windowData[:0] // Keep capacity, reset length
	
	rba.windowDataMu.Unlock()
	
	// 3. Calculate window stats (outside lock)
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
	
	// Calculate aggregated window statistics
	stats := rba.calculateWindowStats(windowData)
	
	// 4. Send aggregated stats to windowed sampler (non-blocking)
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

