package score

import "sync"

// Publisher fans each ScoreEvent to all registered Sinks. Same shape as
// instrumentation.Publisher (only the event type differs).
//
// Publish is a synchronous in-binary call: each Sink's Emit is invoked
// one at a time on the caller's goroutine. No internal goroutine, no
// batching, no buffering inside the Publisher itself; back-pressure
// lives entirely inside each Sink.
//
// Concurrency: Publisher is safe for concurrent Publish and Register
// calls. The Register lock is exclusive (writes); the Publish hot path
// takes a read lock. In steady state the lock is read-only and contended
// only when subscribers connect/disconnect (rare).
type Publisher struct {
	mu    sync.RWMutex
	sinks []Sink
}

// NewPublisher constructs an empty Publisher.
func NewPublisher() *Publisher {
	return &Publisher{}
}

// Register adds a Sink. Idempotent.
func (p *Publisher) Register(s Sink) {
	if s == nil {
		return
	}
	p.mu.Lock()
	p.sinks = append(p.sinks, s)
	p.mu.Unlock()
}

// Unregister removes a Sink (by pointer identity). Safe to call from any
// goroutine; no-op if the Sink isn't registered.
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

// Publish fans the given ScoreEvent to all currently-registered Sinks.
// Synchronous and call-by-value: Sinks see the ScoreEvent directly, no
// copy beyond the function-call argument.
//
// MUST be non-blocking on the steady-state path. Slow Sinks must drop
// internally; the Publisher does not protect against a misbehaving Sink.
func (p *Publisher) Publish(ev ScoreEvent) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	for _, snk := range p.sinks {
		snk.Emit(ev)
	}
}

// Close releases all registered Sinks and clears the registry. Safe to
// call once at shutdown. Callers should arrange shutdown order: stop the
// upstream Source first (no more Publish calls), then Close the
// Publisher.
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
