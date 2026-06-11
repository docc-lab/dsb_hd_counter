package score

// Sink is the contract a score.Publisher fans ScoreEvents to. Symmetric
// to instrumentation.Sink (which fans Samples). Sinks MUST be
// non-blocking: an Emit call that takes longer than the next window
// boundary will starve other sinks.
type Sink interface {
	// Emit receives one ScoreEvent. Implementations must not block (use
	// a bounded channel + drop-on-overflow internally if needed).
	Emit(ScoreEvent)

	// Close releases any resources owned by the sink (sockets, files,
	// goroutines). Called once at predictor / service shutdown.
	Close() error
}
