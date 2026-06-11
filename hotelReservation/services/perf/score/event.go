// Package score defines the publish/subscribe pipeline for ScoreEvents
// produced by a score.Source from each Sample.
//
// This package is the Go-side counterpart to the ContentionStream proto
// contract in services/perf/proto/contention.proto. It exposes:
//
//   - The Source interface: anything that consumes Samples and produces
//     ScoreEvents. The ONNX predictor in score/onnx/ is one impl; future
//     formula-based or rule-based sources implement the same interface
//     and select via GORDION_SCORE_SOURCE.
//   - The Publisher: fans each ScoreEvent to all registered Sinks
//     (LogSink, GRPCSink, future SSE/NATS sinks).
//   - GRPCSink: the gRPC ContentionStream server :7900 that mitigation
//     systems and any other consumer subscribe to.
//
// See the design plan's section 3 architecture diagram for the full
// data flow. The score side is symmetric to the instrumentation side
// (same Publisher/Sink pattern, same per-subscriber drop-on-overflow).
package score

import "time"

// ScoreEvent is the score for one window. Both P50TrendPred and
// TailTrendLabel are continuous regression outputs in [0, 1].
//
// During the single-head transitional period (M7), TailTrendLabel may
// be 0.0 with a startup warning logged on the producer side -- this is
// the case when the loaded ONNX model has only the colleague's existing
// p50_score head (gru_model_run1.onnx).
//
// Mitigation consumers can use ModelVersion to reject stale streams
// after a model swap, and SourceKind to differentiate when multiple
// score sources are wired up to the same Publisher.
type ScoreEvent struct {
	SampleID       int64
	Timestamp      time.Time
	Service        string
	P50TrendPred   float32 // [0, 1]
	TailTrendLabel float32 // [0, 1]
	ModelVersion   string  // typically the shortlist.schema_version
	SourceKind     string  // "onnx" | "formula" | "rules" | ...
}
