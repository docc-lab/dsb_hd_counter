package score

import "github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/instrumentation"

// Source is anything that consumes Samples (via Emit, inherited from
// instrumentation.Sink) and produces ScoreEvents. By embedding
// instrumentation.Sink in this interface, a Source can be registered
// directly with an instrumentation.Publisher in the same way as any
// other Sink.
//
// Concrete sources (e.g. score/onnx.Predictor) typically receive a
// *score.Publisher at construction time so they can call its Publish
// method with the ScoreEvents they produce. The Source interface
// itself is intentionally minimal -- the contract is: "I'm a Sink
// somewhere upstream, and I push ScoreEvents to a Publisher I was
// configured with."
//
// A Source is selected at startup via GORDION_SCORE_SOURCE=onnx|formula|...
// The selector lives in the service's main.go (or an integration
// helper); each Source impl registers itself with the
// instrumentation.Publisher and writes to the score.Publisher that's
// wired up beside it.
type Source interface {
	instrumentation.Sink
}
