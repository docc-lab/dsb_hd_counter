package interceptor

import (
	"sync/atomic"
	
	"github.com/rs/zerolog/log"
)

// LockFreeRingBuffer is a lock-free MPSC (Multi-Producer Single-Consumer) ring buffer
// Optimized for many concurrent gRPC requests writing timing data
type LockFreeRingBuffer struct {
	buffer []TimingData
	size   uint64
	mask   uint64 // size - 1, for fast modulo via bitwise AND
	
	// Atomically updated indices
	head atomic.Uint64 // Next write position (updated by producers)
	tail atomic.Uint64 // Next read position (updated by consumer)
	
	// Statistics
	droppedCount atomic.Uint64
	totalPushed  atomic.Uint64
	
	// Configuration
	flushThreshold uint64 // Trigger early flush when buffer is N% full
	
	// Prevent false sharing between head and tail
	// CPU cache lines are typically 64 bytes
	_padding [56]byte
}

// NewLockFreeRingBuffer creates a new ring buffer
// size: Must be power of 2 (e.g., 256, 512, 1024, 2048, 4096)
// flushThresholdPct: Percentage (0-100) to trigger proactive flush (e.g., 80)
func NewLockFreeRingBuffer(size uint64, flushThresholdPct int) *LockFreeRingBuffer {
	// Validate size is power of 2
	if size == 0 || (size&(size-1)) != 0 {
		panic("ring buffer size must be power of 2")
	}
	
	if flushThresholdPct < 0 || flushThresholdPct > 100 {
		flushThresholdPct = 80 // Default
	}
	
	rb := &LockFreeRingBuffer{
		buffer:         make([]TimingData, size),
		size:           size,
		mask:           size - 1,
		flushThreshold: size * uint64(flushThresholdPct) / 100,
	}
	
	log.Info().
		Uint64("size", size).
		Uint64("flush_threshold", rb.flushThreshold).
		Int("threshold_pct", flushThresholdPct).
		Msg("Created lock-free ring buffer")
	
	return rb
}

// TryPush attempts to push data into ring buffer (LOCK-FREE)
// Returns true if successful, false if buffer is full
// This is called by MANY concurrent gRPC request goroutines
func (rb *LockFreeRingBuffer) TryPush(data TimingData) bool {
	maxRetries := 100 // Prevent infinite retry loops
	
	for retry := 0; retry < maxRetries; retry++ {
		// 1. Load current head position atomically
		currentHead := rb.head.Load()
		nextHead := currentHead + 1
		
		// 2. Check if buffer is full
		// Keep one slot empty to distinguish full from empty
		currentTail := rb.tail.Load()
		available := rb.size - (currentHead - currentTail)
		
		if available <= 1 {
			// Buffer is full, drop this data
			rb.droppedCount.Add(1)
			
			// Log warning periodically
			dropped := rb.droppedCount.Load()
			if dropped%1000 == 0 {
				log.Warn().
					Uint64("dropped_total", dropped).
					Uint64("buffer_size", rb.size).
					Msg("Ring buffer full, dropping timing data")
			}
			return false
		}
		
		// 3. Try to atomically claim this slot
		if rb.head.CompareAndSwap(currentHead, nextHead) {
			// SUCCESS! We own the slot at currentHead
			idx := currentHead & rb.mask // Fast modulo: currentHead % size
			rb.buffer[idx] = data
			
			rb.totalPushed.Add(1)
			return true
		}
		
		// RETRY: Another goroutine won the race for this slot
		// This is expected under high concurrency
	}
	
	// Failed after max retries (very rare, indicates extreme contention)
	rb.droppedCount.Add(1)
	log.Warn().Msg("Ring buffer push failed after max retries")
	return false
}

// Available returns number of items currently in buffer
func (rb *LockFreeRingBuffer) Available() uint64 {
	head := rb.head.Load()
	tail := rb.tail.Load()
	return head - tail
}

// IsFull returns true if buffer is at or above capacity
func (rb *LockFreeRingBuffer) IsFull() bool {
	return rb.Available() >= rb.size-1
}

// ShouldFlush returns true if buffer is above flush threshold
func (rb *LockFreeRingBuffer) ShouldFlush() bool {
	return rb.Available() >= rb.flushThreshold
}

// UsagePercent returns current buffer usage percentage
func (rb *LockFreeRingBuffer) UsagePercent() float64 {
	return float64(rb.Available()) * 100.0 / float64(rb.size)
}

// PopAll extracts all available items (called by single consumer)
// This should only be called by ONE goroutine (the flush loop)
func (rb *LockFreeRingBuffer) PopAll() []TimingData {
	currentTail := rb.tail.Load()
	currentHead := rb.head.Load()
	
	// Calculate available items
	available := currentHead - currentTail
	if available == 0 {
		return nil // Empty buffer
	}
	
	// Limit to reasonable batch size to prevent huge allocations
	maxBatch := rb.size
	if available > maxBatch {
		available = maxBatch
	}
	
	// Extract items into new slice
	result := make([]TimingData, 0, available)
	for i := uint64(0); i < available; i++ {
		idx := (currentTail + i) & rb.mask
		result = append(result, rb.buffer[idx])
	}
	
	// Advance tail (only consumer modifies tail, so no CAS needed)
	rb.tail.Store(currentTail + available)
	
	return result
}

// PopBatch extracts up to maxItems (called by single consumer)
func (rb *LockFreeRingBuffer) PopBatch(maxItems uint64) []TimingData {
	currentTail := rb.tail.Load()
	currentHead := rb.head.Load()
	
	available := currentHead - currentTail
	if available == 0 {
		return nil
	}
	
	// Take minimum of available and maxItems
	if available > maxItems {
		available = maxItems
	}
	
	result := make([]TimingData, 0, available)
	for i := uint64(0); i < available; i++ {
		idx := (currentTail + i) & rb.mask
		result = append(result, rb.buffer[idx])
	}
	
	rb.tail.Store(currentTail + available)
	return result
}

// Reset clears all data (should only be called when no concurrent access)
func (rb *LockFreeRingBuffer) Reset() {
	rb.tail.Store(rb.head.Load())
}

// GetStats returns buffer statistics
func (rb *LockFreeRingBuffer) GetStats() RingBufferStats {
	return RingBufferStats{
		Size:         rb.size,
		Available:    rb.Available(),
		UsagePercent: rb.UsagePercent(),
		Dropped:      rb.droppedCount.Load(),
		TotalPushed:  rb.totalPushed.Load(),
	}
}

// RingBufferStats contains buffer statistics
type RingBufferStats struct {
	Size         uint64  `json:"size"`
	Available    uint64  `json:"available"`
	UsagePercent float64 `json:"usage_percent"`
	Dropped      uint64  `json:"dropped"`
	TotalPushed  uint64  `json:"total_pushed"`
}

