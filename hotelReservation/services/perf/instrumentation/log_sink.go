package instrumentation

import (
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	"github.com/rs/zerolog"
)

// LogSink writes one zerolog event per Sample at debug level. Intended
// only for development / on-cluster sanity checks; producing 10 lines
// per second to stderr is fine but not what you want during long runs.
//
// The sample_id and counts fields are emitted as structured log fields
// so a `kubectl logs ... | grep instrumentation_sample` filter shows the
// stream. Full Sample contents are omitted because zerolog can't easily
// render the nested maps without expensive Marshal calls; if you need
// the full payload, subscribe to the gRPC stream instead.
//
// The Sample struct itself does not carry the service name (the sampler
// owns it via RunConfig). LogSink takes the service name at construction
// so log lines are self-identifying without forcing a Sample-struct
// change.
type LogSink struct {
	logger      zerolog.Logger
	serviceName string
}

// NewLogSink constructs a LogSink writing to the provided logger. Pass
// the package-level zerolog logger (log.Logger) or a child with a fixed
// service-name field. serviceName is included on every log line as a
// "service" field.
func NewLogSink(logger zerolog.Logger, serviceName string) *LogSink {
	return &LogSink{logger: logger, serviceName: serviceName}
}

// Emit writes one debug-level log line per Sample. Non-blocking in
// practice (zerolog is fast; stderr writes don't back-pressure under
// 10 Hz of small lines), but if the underlying writer ever blocked, this
// would block the Publisher fan-out. For production paths use GRPCSink.
func (s *LogSink) Emit(sample perf.Sample) {
	ev := s.logger.Debug().
		Str("event", "instrumentation_sample").
		Str("service", s.serviceName).
		Int("sample_id", sample.SampleID).
		Time("timestamp", sample.Timestamp).
		Int64("offset_ms", sample.OffsetMs)

	if sample.TimingWindow != nil {
		ev = ev.
			Int("arrival_count", sample.TimingWindow.ArrivalCount).
			Int("request_count", sample.TimingWindow.RequestCount).
			Float64("arrival_rps_3s", sample.TimingWindow.ArrivalRps3s)
	}
	if sample.Freq.OK {
		ev = ev.Float64("actual_freq_mhz", sample.Freq.ActualFreqMHz).
			Float64("freq_util_pct", sample.Freq.FreqUtilPct)
	}
	ev.Msg("sample")
}

// Close is a no-op: zerolog writers are owned by the caller.
func (s *LogSink) Close() error { return nil }
