package score

import "github.com/rs/zerolog"

// LogSink writes one zerolog event per ScoreEvent. Unlike the
// instrumentation LogSink (which is debug-only), this one runs at info
// level by default because score events are sparser (~10/sec) and
// genuinely useful in operational logs. Pre-mitigation, this is the
// primary observability for what scores the predictor is producing.
type LogSink struct {
	logger zerolog.Logger
}

// NewLogSink constructs a LogSink writing to the provided logger.
func NewLogSink(logger zerolog.Logger) *LogSink {
	return &LogSink{logger: logger}
}

// Emit writes one info-level log line per ScoreEvent.
func (s *LogSink) Emit(ev ScoreEvent) {
	s.logger.Info().
		Str("event", "score").
		Str("service", ev.Service).
		Int64("sample_id", ev.SampleID).
		Time("timestamp", ev.Timestamp).
		Float32("p50_trend_pred", ev.P50TrendPred).
		Float32("tail_trend_label", ev.TailTrendLabel).
		Float32("y50_current", ev.Y50Current).
		Float32("ext_pct_50", ev.ExtPct50).
		Float32("ext_pct_90", ev.ExtPct90).
		Bool("prediction_on", ev.PredictionOn).
		Str("model_version", ev.ModelVersion).
		Str("source_kind", ev.SourceKind).
		Msg("score_event")
}

// Close is a no-op: zerolog writers are owned by the caller.
func (s *LogSink) Close() error { return nil }
