// Package instrumentation defines the publish/subscribe pipeline for
// per-window Sample data emitted by the windowed sampler.
//
// This package is the Go-side counterpart to the InstrumentationStream
// proto contract in services/perf/proto/instrumentation.proto. It exposes
// the fan-out Publisher that the sampler hands each new Sample to, and a
// pluggable Sink interface that any subscriber can implement.
//
// In-binary subscribers (e.g. a score.Source running in the same Go
// binary) register a Sink directly and receive Emit calls as a function
// dispatch. External cross-language subscribers attach via the GRPCSink
// which wraps the InstrumentationStream gRPC server. See the design
// plan's section 3 architecture diagram for the full picture.
//
// Per-Sink back-pressure: each Sink is responsible for absorbing its own
// load (per-subscriber drop-on-overflow on the instrumentation side).
// The Publisher's fan-out loop never blocks; concrete Sinks should drop
// on overflow rather than blocking the loop.
package instrumentation

import "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"

// Sink is the contract a Publisher fans Samples to. Sinks MUST be
// non-blocking: an Emit call that takes longer than the next window
// boundary will starve other sinks.
type Sink interface {
	// Emit receives one Sample. Implementations must not block (use a
	// bounded channel + drop-on-overflow internally if needed).
	Emit(perf.Sample)

	// Close releases any resources owned by the sink (sockets, files,
	// goroutines). Called once at predictor / service shutdown.
	Close() error
}
