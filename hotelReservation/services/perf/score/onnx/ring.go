package onnx

import "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"

// Ring is a bounded sequence buffer of perf.Sample values, sized at
// shortlist.SeqLen. The predictor pushes one Sample per window; once
// Full reports true, View returns the SeqLen most-recent Samples in
// arrival order (oldest first).
//
// SeqLen = 1 collapses naturally to single-window inference: the ring
// has one slot, Full is true after the first push, View returns the
// latest sample. Same code path handles the multi-window sequence case
// (SeqLen = 50 in the colleague's GRU prototype) without branching.
//
// Ring is NOT safe for concurrent use. The predictor's loop owns the
// ring and runs single-goroutine.
type Ring struct {
	buf  []perf.Sample
	head int  // next write index
	full bool // true once we've wrapped at least once
}

// NewRing constructs a Ring of capacity n. n MUST be > 0.
func NewRing(n int) *Ring {
	if n <= 0 {
		panic("onnx.NewRing: n must be > 0")
	}
	return &Ring{buf: make([]perf.Sample, n)}
}

// Cap returns the configured capacity (= shortlist.SeqLen).
func (r *Ring) Cap() int { return len(r.buf) }

// Len returns the number of samples currently in the ring (caps at Cap
// once Full).
func (r *Ring) Len() int {
	if r.full {
		return len(r.buf)
	}
	return r.head
}

// Full reports whether the ring has accumulated SeqLen samples. Until
// Full is true, the predictor skips inference (warmup).
func (r *Ring) Full() bool { return r.full }

// Push writes one Sample to the next slot, advancing head. When the
// ring wraps, full becomes true and stays true.
func (r *Ring) Push(s perf.Sample) {
	r.buf[r.head] = s
	r.head++
	if r.head >= len(r.buf) {
		r.head = 0
		r.full = true
	}
}

// View returns the buffered samples in arrival order (oldest first).
// Allocates a fresh slice each call; the predictor's hot path uses this
// only after Full() is true. Length is always r.Len().
//
// The returned slice is safe to read; callers must not mutate it
// (Sample's maps are shared with the original Sample objects).
func (r *Ring) View() []perf.Sample {
	if !r.full {
		out := make([]perf.Sample, r.head)
		copy(out, r.buf[:r.head])
		return out
	}
	// Wrapped: oldest is at head, newest is at head-1 (mod cap).
	out := make([]perf.Sample, len(r.buf))
	copy(out, r.buf[r.head:])
	copy(out[len(r.buf)-r.head:], r.buf[:r.head])
	return out
}

// Reset clears the ring back to empty (head = 0, full = false). Useful
// for tests; not used in steady-state production.
func (r *Ring) Reset() {
	for i := range r.buf {
		r.buf[i] = perf.Sample{}
	}
	r.head = 0
	r.full = false
}
