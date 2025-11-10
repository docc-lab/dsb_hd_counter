package interceptor

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog/log"
	"google.golang.org/grpc"
)

// TimingConfig holds configuration for timing interceptor
type TimingConfig struct {
	EnableTiming       bool
	ServiceName        string
	StatsFile          string        // File to write aggregated statistics (optional - legacy mode)
	EnableWindowed     bool          // Enable windowed batching mode
	WindowInterval     time.Duration // Window interval for batching (e.g., 100ms)
	WindowStatsChannel chan *WindowTimingStats // Channel to send window stats
}

// TimingData represents a single timing measurement
type TimingData struct {
	ServiceName    string        `json:"service_name"`
	Method         string        `json:"method"`
	ArrivalTime    time.Time     `json:"arrival_time"`
	ProcessingTime time.Duration `json:"processing_time_ns"` // Time spent in actual processing (excluding blocking calls)
	TotalTime      time.Duration `json:"total_time_ns"`      // Total time including blocking calls
	BlockingTime   time.Duration `json:"blocking_time_ns"`   // Time spent in blocking calls
	Timestamp      time.Time     `json:"timestamp"`
}

// TimingStats holds statistics for a service
type TimingStats struct {
	ServiceName      string                    `json:"service_name"`
	TotalRequests    int                       `json:"total_requests"`
	ProcessingStats  DurationStats             `json:"processing_stats"`
	TotalTimeStats   DurationStats             `json:"total_time_stats"`
	BlockingStats    DurationStats             `json:"blocking_stats"`
	MethodBreakdown  map[string]DurationStats  `json:"method_breakdown"`
	Histogram        map[string]int            `json:"histogram_ms"` // Histogram in milliseconds
	LastUpdated      time.Time                 `json:"last_updated"`
}

// DurationStats holds statistical data for durations
type DurationStats struct {
	Min    time.Duration `json:"min_ns"`
	Max    time.Duration `json:"max_ns"`
	Mean   time.Duration `json:"mean_ns"`
	P50    time.Duration `json:"p50_ns"`
	P95    time.Duration `json:"p95_ns"`
	P99    time.Duration `json:"p99_ns"`
	Count  int           `json:"count"`
}

// WindowTimingStats captures timing data for requests in one window interval
type WindowTimingStats struct {
	RequestCount   int                 `json:"request_count"`
	ProcessingTime WindowDurationStats `json:"processing_time"`
	TotalTime      WindowDurationStats `json:"total_time"`
	BlockingTime   WindowDurationStats `json:"blocking_time"`
}

// WindowDurationStats provides stats for durations within one window
type WindowDurationStats struct {
	MinNs  int64 `json:"min_ns"`
	MaxNs  int64 `json:"max_ns"`
	MeanNs int64 `json:"mean_ns"`
	Count  int   `json:"count"`
}

// LocalTimingAggregator handles in-memory timing data aggregation with periodic stats output
type LocalTimingAggregator struct {
	serviceName   string
	statsFile     string
	data          []TimingData
	mu            sync.RWMutex
	lastStatsTime time.Time
	statsInterval time.Duration
	
	// Windowed mode fields
	enableWindowed    bool
	windowInterval    time.Duration
	windowStatsChannel chan *WindowTimingStats
	windowData        []TimingData
	windowTicker      *time.Ticker
	ctx               context.Context
	cancel            context.CancelFunc
	wg                sync.WaitGroup
}

// NewLocalTimingAggregator creates a new local aggregator instance (legacy mode)
func NewLocalTimingAggregator(serviceName, statsFile string) *LocalTimingAggregator {
	return &LocalTimingAggregator{
		serviceName:    serviceName,
		statsFile:      statsFile,
		data:           make([]TimingData, 0),
		lastStatsTime:  time.Now(),
		statsInterval:  30 * time.Second, // Write stats every 30 seconds
		enableWindowed: false,
	}
}

// NewWindowedTimingAggregator creates a new aggregator for windowed sampling mode
func NewWindowedTimingAggregator(config TimingConfig) *LocalTimingAggregator {
	ctx, cancel := context.WithCancel(context.Background())
	
	agg := &LocalTimingAggregator{
		serviceName:        config.ServiceName,
		statsFile:          config.StatsFile,
		data:               make([]TimingData, 0),
		lastStatsTime:      time.Now(),
		statsInterval:      config.WindowInterval,
		enableWindowed:     config.EnableWindowed,
		windowInterval:     config.WindowInterval,
		windowStatsChannel: config.WindowStatsChannel,
		windowData:         make([]TimingData, 0),
		ctx:                ctx,
		cancel:             cancel,
	}
	
	// Start windowed flushing loop
	if agg.enableWindowed && agg.windowStatsChannel != nil {
		agg.wg.Add(1)
		go agg.windowedFlushLoop()
		
		log.Info().
			Str("service", config.ServiceName).
			Dur("window_interval", config.WindowInterval).
			Msg("Started windowed timing aggregator")
	}
	
	return agg
}

// Stop stops the windowed aggregator
func (lta *LocalTimingAggregator) Stop() {
	if lta.enableWindowed && lta.cancel != nil {
		lta.cancel()
		lta.wg.Wait()
		log.Info().Str("service", lta.serviceName).Msg("Stopped windowed timing aggregator")
	}
}

// windowedFlushLoop periodically flushes window stats
func (lta *LocalTimingAggregator) windowedFlushLoop() {
	defer lta.wg.Done()
	
	lta.windowTicker = time.NewTicker(lta.windowInterval)
	defer lta.windowTicker.Stop()
	
	for {
		select {
		case <-lta.windowTicker.C:
			lta.flushWindow()
			
		case <-lta.ctx.Done():
			lta.flushWindow() // Final flush
			return
		}
	}
}

// flushWindow flushes current window data and sends aggregated stats
// This is called periodically by windowedFlushLoop goroutine (single writer)
// LOCK: Briefly locks to atomically copy and clear buffer
func (lta *LocalTimingAggregator) flushWindow() {
	lta.mu.Lock()   // ACQUIRE LOCK - need exclusive access to buffer
	
	// Get snapshot of ALL requests completed during this window
	// This includes timing data from potentially hundreds of concurrent requests
	windowData := make([]TimingData, len(lta.windowData))
	copy(windowData, lta.windowData)
	
	// Clear window data buffer for next window
	lta.windowData = make([]TimingData, 0)
	
	lta.mu.Unlock()  // RELEASE LOCK - minimize lock hold time
	
	// AGGREGATE: Calculate window statistics OUTSIDE the lock
	// This processes all requests completed in the last WINDOW_INTERVAL
	stats := lta.calculateWindowStats(windowData)
	
	// Send aggregated stats to windowed sampler (non-blocking)
	if lta.windowStatsChannel != nil {
		select {
		case lta.windowStatsChannel <- stats:
			// Sent successfully - sampler will combine with perf counters
			log.Debug().
				Str("service", lta.serviceName).
				Int("request_count", stats.RequestCount).
				Int64("mean_processing_ns", stats.ProcessingTime.MeanNs).
				Msg("Flushed window stats")
		default:
			// Channel full - drop this window's stats to avoid blocking
			log.Warn().
				Str("service", lta.serviceName).
				Int("request_count", stats.RequestCount).
				Msg("Window stats channel full, dropping window stats")
		}
	}
}

// calculateWindowStats calculates statistics for one window
func (lta *LocalTimingAggregator) calculateWindowStats(data []TimingData) *WindowTimingStats {
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

// calculateWindowDurationStats calculates statistics for a slice of durations
func calculateWindowDurationStats(durations []time.Duration) WindowDurationStats {
	if len(durations) == 0 {
		return WindowDurationStats{}
	}
	
	var sum time.Duration
	min := durations[0]
	max := durations[0]
	
	for _, d := range durations {
		sum += d
		if d < min {
			min = d
		}
		if d > max {
			max = d
		}
	}
	
	mean := sum / time.Duration(len(durations))
	
	return WindowDurationStats{
		MinNs:  min.Nanoseconds(),
		MaxNs:  max.Nanoseconds(),
		MeanNs: mean.Nanoseconds(),
		Count:  len(durations),
	}
}

// contextKey is used for storing timing data in context
type contextKey string

const (
	timingDataKey contextKey = "timing_data"
	pauseTimeKey  contextKey = "pause_time"
)

// timingContext holds mutable timing state that can be updated by client interceptors
// Uses lock-free atomic operations for thread-safe updates
type timingContext struct {
	// Stack-based approach: activeCallCount represents the depth of the call stack
	// When 0: service is processing (not blocked)
	// When >0: service is blocked waiting for downstream calls
	activeCallCount   int32  // atomic counter - acts as stack depth
	pauseStartTimeNs  int64  // atomic - nanoseconds when blocking started (0 if not blocking)
	totalPausedTimeNs int64  // atomic - accumulated paused time in nanoseconds
	totalCallCount    int32  // atomic - total number of downstream calls made
}

// TimingServerInterceptor creates a server-side unary interceptor with local timing functionality (legacy mode)
func TimingServerInterceptor(config TimingConfig) grpc.UnaryServerInterceptor {
	if !config.EnableTiming {
		// Return a no-op interceptor if timing is disabled
		return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
			return handler(ctx, req)
		}
	}

	// Initialize local aggregator (legacy mode)
	var aggregator *LocalTimingAggregator
	if config.EnableWindowed {
		// Windowed mode - use provided channel
		aggregator = NewWindowedTimingAggregator(config)
	} else {
		// Legacy mode - create simple aggregator
		aggregator = NewLocalTimingAggregator(config.ServiceName, config.StatsFile)
	}

	return TimingServerInterceptorWithAggregator(aggregator, config.ServiceName)
}

// TimingServerInterceptorWithAggregator creates interceptor using a provided aggregator
// This allows sharing the aggregator across all requests for proper windowed batching
func TimingServerInterceptorWithAggregator(aggregator *LocalTimingAggregator, serviceName string) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		// START TIMER: Record timestamp when new gRPC call arrives
		arrivalTime := time.Now()
		
		// Initialize timing data in context
		timingData := &TimingData{
			ServiceName: serviceName,
			Method:      info.FullMethod,
			ArrivalTime: arrivalTime,
			Timestamp:   arrivalTime,
		}
		
		// Create mutable timing context that can be updated by client interceptors (lock-free)
		timingCtx := &timingContext{
			activeCallCount:   0,
			pauseStartTimeNs:  0,
			totalPausedTimeNs: 0,
			totalCallCount:    0,
		}
		
		// Store timing data and mutable context for client interceptor to access
		ctx = context.WithValue(ctx, timingDataKey, timingData)
		ctx = context.WithValue(ctx, pauseTimeKey, timingCtx)

		log.Debug().
			Str("method", info.FullMethod).
			Str("service", serviceName).
			Time("arrival_time", arrivalTime).
			Msg("gRPC request started")

		// Call the actual handler (may call client interceptor which pauses/resumes timer)
		resp, err := handler(ctx, req)
		
		// STOP TIMER: Response is about to be sent back
		processingEnd := time.Now()

		// Calculate timing metrics
		totalTime := processingEnd.Sub(arrivalTime)
		
		// Get the accumulated paused time from the mutable context (lock-free atomic read)
		pausedTimeNs := atomic.LoadInt64(&timingCtx.totalPausedTimeNs)
		pausedTime := time.Duration(pausedTimeNs)
		blockingCount := atomic.LoadInt32(&timingCtx.totalCallCount)
		
		processingTime := totalTime - pausedTime

		// Update timing data with final values
		timingData.TotalTime = totalTime
		timingData.ProcessingTime = processingTime
		timingData.BlockingTime = pausedTime

		// Log detailed timing information for this request
		log.Debug().
			Str("method", info.FullMethod).
			Str("service", serviceName).
			Int32("downstream_calls", blockingCount).
			Dur("total_time", totalTime).
			Dur("processing_time", processingTime).
			Dur("blocking_time", pausedTime).
			Float64("processing_time_ms", float64(processingTime.Nanoseconds())/1000000).
			Float64("total_time_ms", float64(totalTime.Nanoseconds())/1000000).
			Float64("blocking_time_ms", float64(pausedTime.Nanoseconds())/1000000).
			Msg("gRPC request completed")

		// ADD TO WINDOW BUFFER: Add completed timing data to aggregator
		// This goes into the window data buffer and will be aggregated with other concurrent requests
		aggregator.AddTimingData(*timingData)

		// Legacy mode: periodically write stats to file (non-blocking)
		if !aggregator.enableWindowed && aggregator.statsFile != "" {
			go aggregator.MaybeWriteStats()
		}

		return resp, err
	}
}

// TimingClientInterceptor creates a client-side unary interceptor that pauses timing during blocking calls
// Uses LOCK-FREE atomic operations with a stack-based approach:
// - Push (increment counter) when making a call
// - Pop (decrement counter) when receiving response
// - Empty stack (counter=0) means service is processing (not blocked)
// - Non-empty stack (counter>0) means service is blocked
// NO LOCKS: All operations use atomic instructions for thread-safety
func TimingClientInterceptor() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		// Check if we have timing context (meaning timing is enabled)
		timingData, hasTimingData := ctx.Value(timingDataKey).(*TimingData)
		timingCtx, hasTimingCtx := ctx.Value(pauseTimeKey).(*timingContext)
		
		if !hasTimingData || !hasTimingCtx {
			// No timing data, just make the call normally
			return invoker(ctx, method, req, reply, cc, opts...)
		}

		// PAUSE TIMER: Push onto call stack (LOCK-FREE atomic increment)
		// If this is the first call (0→1), we transition to blocking state
		oldCount := atomic.AddInt32(&timingCtx.activeCallCount, 1) - 1
		currentCount := oldCount + 1
		
		if oldCount == 0 {
			// Stack was empty, now has 1 item - START blocking period (PAUSE TIMER)
			pauseStartNs := time.Now().UnixNano()
			atomic.StoreInt64(&timingCtx.pauseStartTimeNs, pauseStartNs)
			
			log.Debug().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", currentCount).
				Msg("PAUSE TIMER - Starting downstream call (stack 0→1)")
		} else {
			log.Debug().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", currentCount).
				Msg("Nested downstream call - already paused (stack depth increased)")
		}
		
		// Increment total call counter (LOCK-FREE atomic)
		atomic.AddInt32(&timingCtx.totalCallCount, 1)
		
		// Make the actual downstream call (THIS IS THE BLOCKING PART)
		callStart := time.Now()
		err := invoker(ctx, method, req, reply, cc, opts...)
		callDuration := time.Since(callStart)
		
		// RESUME TIMER: Pop from call stack (LOCK-FREE atomic decrement)
		// If this was the last call (1→0), we transition back to processing state
		newCount := atomic.AddInt32(&timingCtx.activeCallCount, -1)
		
		if newCount == 0 {
			// Stack is now empty - END blocking period and accumulate time (RESUME TIMER)
			pauseStartNs := atomic.LoadInt64(&timingCtx.pauseStartTimeNs)
			if pauseStartNs > 0 {
				blockingDurationNs := time.Now().UnixNano() - pauseStartNs
				atomic.AddInt64(&timingCtx.totalPausedTimeNs, blockingDurationNs)
				atomic.StoreInt64(&timingCtx.pauseStartTimeNs, 0)
				
				totalPausedNs := atomic.LoadInt64(&timingCtx.totalPausedTimeNs)
				
				log.Debug().
					Str("outgoing_method", method).
					Str("parent_service", timingData.ServiceName).
					Str("parent_method", timingData.Method).
					Int32("stack_depth", newCount).
					Dur("this_call_duration", callDuration).
					Float64("blocking_period_ms", float64(blockingDurationNs)/1000000).
					Float64("total_paused_ms", float64(totalPausedNs)/1000000).
					Msg("RESUME TIMER - Downstream call completed (stack 1→0)")
			}
		} else {
			log.Debug().
				Str("outgoing_method", method).
				Str("parent_service", timingData.ServiceName).
				Str("parent_method", timingData.Method).
				Int32("stack_depth", newCount).
				Dur("this_call_duration", callDuration).
				Msg("Nested downstream call completed - still paused (stack depth decreased)")
		}
		
		// Return back to service handler
		// Server interceptor will STOP TIMER when response is sent
		return err
	}
}

// ChainUnaryServerInterceptors chains multiple server interceptors
func ChainUnaryServerInterceptors(interceptors ...grpc.UnaryServerInterceptor) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
		chain := handler
		for i := len(interceptors) - 1; i >= 0; i-- {
			interceptor := interceptors[i]
			next := chain
			chain = func(currentCtx context.Context, currentReq interface{}) (interface{}, error) {
				return interceptor(currentCtx, currentReq, info, next)
			}
		}
		return chain(ctx, req)
	}
}

// ChainUnaryClientInterceptors chains multiple client interceptors
func ChainUnaryClientInterceptors(interceptors ...grpc.UnaryClientInterceptor) grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		chain := invoker
		for i := len(interceptors) - 1; i >= 0; i-- {
			interceptor := interceptors[i]
			next := chain
			chain = func(currentCtx context.Context, currentMethod string, currentReq, currentReply interface{}, currentCC *grpc.ClientConn, currentOpts ...grpc.CallOption) error {
				return interceptor(currentCtx, currentMethod, currentReq, currentReply, currentCC, next, currentOpts...)
			}
		}
		return chain(ctx, method, req, reply, cc, opts...)
	}
}

// AddTimingData adds timing data to the in-memory aggregator
// This is called by MANY concurrent gRPC requests, so it needs to be thread-safe
// LOCK: Uses sync.RWMutex to protect concurrent writes to the buffer
func (lta *LocalTimingAggregator) AddTimingData(data TimingData) {
	lta.mu.Lock()   // ACQUIRE LOCK - protects buffer from concurrent writes
	defer lta.mu.Unlock()
	
	// Add to overall data for legacy stats
	lta.data = append(lta.data, data)
	
	// Keep only last 10000 entries to prevent memory issues
	if len(lta.data) > 10000 {
		lta.data = lta.data[len(lta.data)-10000:]
	}
	
	// WINDOW BUFFER: Add to window data if windowed mode is enabled
	// This buffer accumulates all requests completed during the current window
	// Will be flushed and aggregated every WINDOW_INTERVAL (e.g., 100ms)
	if lta.enableWindowed {
		lta.windowData = append(lta.windowData, data)
	}
	// RELEASE LOCK - lock held for minimal time (just array append)
}

// MaybeWriteStats writes statistics to file if enough time has passed
func (lta *LocalTimingAggregator) MaybeWriteStats() {
	lta.mu.RLock()
	shouldWrite := time.Since(lta.lastStatsTime) >= lta.statsInterval && len(lta.data) > 0
	lta.mu.RUnlock()
	
	if !shouldWrite {
		return
	}
	
	lta.mu.Lock()
	defer lta.mu.Unlock()
	
	// Double-check after acquiring write lock
	if time.Since(lta.lastStatsTime) < lta.statsInterval {
		return
	}
	
	if len(lta.data) == 0 {
		return
	}
	
	// Calculate statistics
	stats := lta.calculateStats(lta.data)
	
	// Write stats to file
	if lta.statsFile != "" {
		if err := lta.writeStatsToFile(stats); err != nil {
			log.Error().Err(err).Msg("Failed to write stats to file")
		}
	}
	
	// Update last stats time
	lta.lastStatsTime = time.Now()
	
	// Log summary statistics
	log.Info().
		Str("service", lta.serviceName).
		Int("total_requests", stats.TotalRequests).
		Dur("avg_processing_time", stats.ProcessingStats.Mean).
		Dur("p95_processing_time", stats.ProcessingStats.P95).
		Dur("avg_total_time", stats.TotalTimeStats.Mean).
		Dur("p95_total_time", stats.TotalTimeStats.P95).
		Msg("Timing statistics summary")
}

// writeStatsToFile writes statistics to the configured file
func (lta *LocalTimingAggregator) writeStatsToFile(stats TimingStats) error {
	file, err := os.Create(lta.statsFile)
	if err != nil {
		return fmt.Errorf("failed to create stats file %s: %v", lta.statsFile, err)
	}
	defer file.Close()
	
	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(stats); err != nil {
		return fmt.Errorf("failed to write stats to file %s: %v", lta.statsFile, err)
	}
	
	log.Info().
		Str("service", lta.serviceName).
		Str("filename", lta.statsFile).
		Int("total_requests", stats.TotalRequests).
		Msg("Timing statistics written to file")
	
	return nil
}

// calculateStats calculates statistics from timing data
func (lta *LocalTimingAggregator) calculateStats(data []TimingData) TimingStats {
	if len(data) == 0 {
		return TimingStats{ServiceName: lta.serviceName}
	}
	
	// Separate data by type
	var processingTimes, totalTimes, blockingTimes []time.Duration
	methodData := make(map[string][]time.Duration)
	
	for _, d := range data {
		processingTimes = append(processingTimes, d.ProcessingTime)
		totalTimes = append(totalTimes, d.TotalTime)
		blockingTimes = append(blockingTimes, d.BlockingTime)
		
		if methodData[d.Method] == nil {
			methodData[d.Method] = make([]time.Duration, 0)
		}
		methodData[d.Method] = append(methodData[d.Method], d.ProcessingTime)
	}
	
	// Calculate statistics
	stats := TimingStats{
		ServiceName:     lta.serviceName,
		TotalRequests:   len(data),
		ProcessingStats: calculateDurationStats(processingTimes),
		TotalTimeStats:  calculateDurationStats(totalTimes),
		BlockingStats:   calculateDurationStats(blockingTimes),
		MethodBreakdown: make(map[string]DurationStats),
		Histogram:       createHistogram(processingTimes),
		LastUpdated:     time.Now(),
	}
	
	// Calculate per-method statistics
	for method, times := range methodData {
		stats.MethodBreakdown[method] = calculateDurationStats(times)
	}
	
	return stats
}

// calculateDurationStats calculates statistical measures for a slice of durations
func calculateDurationStats(durations []time.Duration) DurationStats {
	if len(durations) == 0 {
		return DurationStats{}
	}
	
	// Sort for percentile calculations
	sorted := make([]time.Duration, len(durations))
	copy(sorted, durations)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i] < sorted[j]
	})
	
	// Calculate mean
	var sum time.Duration
	for _, d := range durations {
		sum += d
	}
	mean := sum / time.Duration(len(durations))
	
	// Calculate percentiles
	p50Index := len(sorted) * 50 / 100
	p95Index := len(sorted) * 95 / 100
	p99Index := len(sorted) * 99 / 100
	
	// Ensure indices are within bounds
	if p50Index >= len(sorted) {
		p50Index = len(sorted) - 1
	}
	if p95Index >= len(sorted) {
		p95Index = len(sorted) - 1
	}
	if p99Index >= len(sorted) {
		p99Index = len(sorted) - 1
	}
	
	return DurationStats{
		Min:   sorted[0],
		Max:   sorted[len(sorted)-1],
		Mean:  mean,
		P50:   sorted[p50Index],
		P95:   sorted[p95Index],
		P99:   sorted[p99Index],
		Count: len(durations),
	}
}

// createHistogram creates a histogram of durations in milliseconds
func createHistogram(durations []time.Duration) map[string]int {
	histogram := make(map[string]int)
	
	// Define histogram buckets in milliseconds
	buckets := []int{1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000}
	
	for _, d := range durations {
		ms := int(d.Nanoseconds() / 1000000) // Convert to milliseconds
		
		bucketFound := false
		for _, bucket := range buckets {
			if ms <= bucket {
				key := fmt.Sprintf("≤%dms", bucket)
				histogram[key]++
				bucketFound = true
				break
			}
		}
		
		if !bucketFound {
			histogram[">10000ms"]++
		}
	}
	
	return histogram
}

// GetTimingStats returns current timing statistics for a service from stats file
func GetTimingStats(statsFile string) (TimingStats, error) {
	var stats TimingStats
	
	file, err := os.Open(statsFile)
	if err != nil {
		return stats, fmt.Errorf("failed to open stats file %s: %v", statsFile, err)
	}
	defer file.Close()
	
	decoder := json.NewDecoder(file)
	if err := decoder.Decode(&stats); err != nil {
		return stats, fmt.Errorf("failed to decode stats from %s: %v", statsFile, err)
	}
	
	return stats, nil
}

