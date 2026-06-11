package instrumentation

import (
	"sync"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
)

// Publisher fans each Sample to all registered Sinks. The same shape
// appears on the score side (score.Publisher fans ScoreEvents).
// Publish is a synchronous in-binary call: each Sink's Emit is invoked
// one at a time on the caller's goroutine. There is no internal
// goroutine, no batching, no buffering inside the Publisher itself;
// back-pressure lives entirely inside each Sink.
//
// This keeps the latency invariant: one Sample -> one Publish ->
// per-Sink Emit, no extra hops.
//
// Concurrency: Publisher is safe for concurrent Publish and Register
// calls. The Register lock is exclusive (writes); the Publish hot path
// takes a read lock. In steady state the lock is read-only and contended
// only when subscribers connect/disconnect (rare).
type Publisher struct {
	mu    sync.RWMutex
	sinks []Sink
}

// NewPublisher constructs an empty Publisher. Register Sinks before the
// sampler starts driving Publish, or dynamically as gRPC subscribers
// connect.
func NewPublisher() *Publisher {
	return &Publisher{}
}

// Register adds a Sink. Idempotent: registering the same Sink twice
// causes it to receive each event twice, so callers must dedupe.
func (p *Publisher) Register(s Sink) {
	if s == nil {
		return
	}
	p.mu.Lock()
	p.sinks = append(p.sinks, s)
	p.mu.Unlock()
}

// Unregister removes a Sink (by pointer identity). Safe to call from any
// goroutine; if the Sink isn't registered it's a no-op.
func (p *Publisher) Unregister(s Sink) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for i, existing := range p.sinks {
		if existing == s {
			p.sinks = append(p.sinks[:i], p.sinks[i+1:]...)
			return
		}
	}
}

// Publish fans the given Sample to all currently-registered Sinks.
// Synchronous and call-by-value: Sinks see the Sample directly, no
// copy beyond the function-call argument. Maps inside the Sample are
// shared but never mutated after readPerfCounters returns (see
// services/perf/windowed_sampler.go::takeSample).
//
// MUST be non-blocking on the steady-state path. Slow Sinks must drop
// internally; the Publisher does not protect against a misbehaving Sink.
func (p *Publisher) Publish(s perf.Sample) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	for _, snk := range p.sinks {
		snk.Emit(s)
	}
}

// Close releases all registered Sinks and clears the registry. Safe to
// call once at shutdown. After Close, further Register or Publish calls
// are no-ops in the sense that a closed publisher with no sinks doesn't
// fan anything out, but Sinks may have unrecoverable state after Close.
// Callers should arrange for shutdown order: Stop the sampler first
// (no more Publish calls), then Close the Publisher.
func (p *Publisher) Close() error {
	p.mu.Lock()
	sinks := p.sinks
	p.sinks = nil
	p.mu.Unlock()

	var firstErr error
	for _, s := range sinks {
		if err := s.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
