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

// ScoreEvent is the score for one window. All score fields are
// continuous values in [0, 1]; higher = more contention.
//
// The producer is the Gordion scorer (score/gordion), which always
// computes the formula outputs (Y50Current, TailTrendLabel, ExtPct50,
// ExtPct90). When the pod additionally runs the ONNX predictor
// (PredictionOn = true), P50TrendPred carries the model's predicted
// next-window y50; otherwise P50TrendPred = Y50Current so consumers
// always have one primary p50 signal regardless of mode.
//
// Mitigation consumers can use ModelVersion to reject stale streams
// after a model / config swap, and SourceKind to differentiate when
// multiple score sources are wired up to the same Publisher.
type ScoreEvent struct {
	SampleID       int64
	Timestamp      time.Time
	Service        string
	P50TrendPred   float32 // primary p50 signal: predicted y50 when PredictionOn, else current y50
	TailTrendLabel float32 // formula y90, [0, 1]
	ModelVersion   string  // trainer run-config id when PredictionOn, gordion config version otherwise
	SourceKind     string  // "gordion" | future comparator tags
	Y50Current     float32 // formula's current y50, always populated
	ExtPct50       float32 // extrinsic share of the p50 shift, [0, 1]
	ExtPct90       float32 // extrinsic share of the p90 shift, [0, 1]
	PredictionOn   bool    // true when P50TrendPred came from the ONNX predictor
}
