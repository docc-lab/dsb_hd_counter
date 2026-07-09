package gordion

import (
	"sync"
	"sync/atomic"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score/onnx"
	"github.com/rs/zerolog"
)

// SourceKind tags every published ScoreEvent. The mode (prediction
// on/off) is expressed by ScoreEvent.PredictionOn, not by the kind:
// future comparator algorithms (FIRM ratio, CPI, slowdown, MAD z-score,
// SLO burn) get their own kinds.
const SourceKind = "gordion"

// SourceConfig carries everything the Source needs at construction.
// stage3wire builds it from env vars; Model is optional (nil = pure
// prediction-off mode) and its construction failures are the caller's
// to log -- a nil Model here is already a fully functional deployment.
type SourceConfig struct {
	ServiceName   string
	ConfigPath    string      // gordion config JSON (GORDION_CONFIG)
	Model         *onnx.Model // optional ONNX predictor; may be nil
	InflightDepth int         // sampler->scorer channel depth; default 16
}

// Source implements score.Source: it consumes Samples via Emit
// (non-blocking, drop-on-overflow), runs the Gordion scorer -- and the
// ONNX model when attached -- in its loop goroutine, and publishes one
// ScoreEvent per scored window through the injected score.Publisher.
//
// Lifecycle:
//
//	src, err := gordion.New(cfg, scorePub, logger)
//	instrumentationPub.Register(src) // src is an instrumentation.Sink
//	defer src.Close()
type Source struct {
	cfg    *Config
	scorer *Scorer
	model  *onnx.Model // nil in prediction-off mode
	pub    *score.Publisher
	logger zerolog.Logger

	serviceName string

	ch chan perf.Sample
	wg sync.WaitGroup

	quit      chan struct{}
	closeOnce sync.Once

	dropped uint64 // sampler -> scorer channel was full
	skipped uint64 // pre-signal windows (Output.OK == false)
}

// New loads the gordion config + curve and starts the scoring loop.
// On any setup failure it returns a non-nil error; the caller
// (stage3wire.Setup) logs and proceeds without a score source. Never
// panics: the gRPC service keeps serving traffic no matter what.
func New(cfg SourceConfig, pub *score.Publisher, logger zerolog.Logger) (*Source, error) {
	gc, err := LoadConfig(cfg.ConfigPath)
	if err != nil {
		return nil, err
	}

	var curve *Curve
	if !gc.Ablations.NoExt {
		curve, err = LoadCurve(gc.CurveCSV, gc.CurveColumns.Rate, gc.CurveColumns.P50, gc.CurveColumns.P90)
		if err != nil {
			return nil, err
		}
	}

	model := cfg.Model
	if model != nil && gc.Ablations.UseCurrentY50 {
		// The use_current_y50 ablation studies the pipeline with the
		// prediction element removed; an attached model is deliberately
		// ignored (and released) rather than silently half-used.
		logger.Warn().
			Str("event", "score_gordion_model_ignored").
			Msg("ablations.use_current_y50 is set; ignoring the attached ONNX model")
		_ = model.Close()
		model = nil
	}

	depth := cfg.InflightDepth
	if depth <= 0 {
		depth = 16
	}

	s := &Source{
		cfg:         gc,
		scorer:      NewScorer(gc, curve),
		model:       model,
		pub:         pub,
		logger:      logger,
		serviceName: cfg.ServiceName,
		ch:          make(chan perf.Sample, depth),
		quit:        make(chan struct{}),
	}

	ev := logger.Info().
		Str("event", "score_gordion_started").
		Str("service", cfg.ServiceName).
		Str("config_version", gc.Version).
		Str("latency_section", gc.LatencySection).
		Str("rate_signal", gc.RateSignal).
		Int("smooth_window", gc.SmoothWindow).
		Float64("k", gc.K).
		Bool("prediction_on", model != nil).
		Bool("ablation_no_smoothing", gc.Ablations.NoSmoothing).
		Bool("ablation_no_ext", gc.Ablations.NoExt).
		Bool("ablation_raw_rate_index", gc.Ablations.RawRateIndex)
	if model != nil {
		ev = ev.Str("model_version", model.Version())
	}
	ev.Msg("Gordion score source started")

	s.wg.Add(1)
	go s.loop()

	return s, nil
}

// Emit satisfies instrumentation.Sink. Non-blocking: if the inflight
// channel is full (scorer falling behind), the Sample is dropped and
// counted. The sampler tick MUST NOT block on scoring jitter.
func (s *Source) Emit(sample perf.Sample) {
	select {
	case s.ch <- sample:
	default:
		atomic.AddUint64(&s.dropped, 1)
	}
}

// Close stops the loop goroutine, waits for it to drain, then releases
// the ONNX model (if any). Idempotent.
func (s *Source) Close() error {
	s.closeOnce.Do(func() {
		close(s.quit)
	})
	s.wg.Wait()
	if s.model != nil {
		_ = s.model.Close()
		s.model = nil
	}
	s.logger.Info().
		Str("event", "score_gordion_stopped").
		Str("service", s.serviceName).
		Uint64("total_dropped", atomic.LoadUint64(&s.dropped)).
		Uint64("total_skipped", atomic.LoadUint64(&s.skipped)).
		Msg("Gordion score source stopped")
	return nil
}

// Stats returns observability counters.
type Stats struct {
	Dropped uint64 // samples dropped at the inflight channel
	Skipped uint64 // pre-signal windows not published
}

// Stats returns a snapshot of the source's counters.
func (s *Source) Stats() Stats {
	return Stats{
		Dropped: atomic.LoadUint64(&s.dropped),
		Skipped: atomic.LoadUint64(&s.skipped),
	}
}

// loop is the scoring goroutine: one iteration per Sample, formula
// always, model when attached, one Publish per scored window.
func (s *Source) loop() {
	defer s.wg.Done()
	for {
		select {
		case <-s.quit:
			return
		case sample, ok := <-s.ch:
			if !ok {
				return
			}
			s.scoreOne(sample)
		}
	}
}

func (s *Source) scoreOne(sample perf.Sample) {
	out := s.scorer.Score(s.windowInput(sample))
	if !out.OK {
		atomic.AddUint64(&s.skipped, 1)
		return
	}

	ev := score.ScoreEvent{
		SampleID:       int64(sample.SampleID),
		Timestamp:      sample.Timestamp,
		Service:        s.serviceName,
		TailTrendLabel: out.Y90,
		Y50Current:     out.Y50,
		ExtPct50:       out.Ext50,
		ExtPct90:       out.Ext90,
		SourceKind:     SourceKind,
		ModelVersion:   s.cfg.Version,
	}

	// Prediction-ON: the model consumes the same Sample stream and, once
	// its sequence ring is warm, contributes the predicted next-window
	// y-hat50 as the primary p50 signal. Any model hiccup (warm-up,
	// inference error) degrades that window to formula-only.
	predicted := false
	if s.model != nil {
		if yhat, ok := s.model.Push(sample); ok {
			ev.P50TrendPred = yhat
			ev.PredictionOn = true
			ev.ModelVersion = s.model.Version()
			predicted = true
		}
	}
	if !predicted {
		ev.P50TrendPred = out.Y50
	}

	s.pub.Publish(ev)
}

// windowInput extracts the scorer's inputs from one Sample, applying
// the configured latency-section and rate-signal selection.
func (s *Source) windowInput(sample perf.Sample) WindowInput {
	in := WindowInput{
		FreqMHz: sample.Freq.ActualFreqMHz,
		FreqOK:  sample.Freq.OK,
	}
	tw := sample.TimingWindow
	if tw == nil {
		return in
	}

	var d interceptor.WindowDurationStats
	switch s.cfg.LatencySection {
	case SectionTotalTime:
		d = tw.TotalTime
	case SectionBlockingTime:
		d = tw.BlockingTime
	default:
		d = tw.ProcessingTime
	}

	in.P50Ns = float64(d.P50Ns)
	in.P90Ns = float64(d.P90Ns)
	in.ArrivalCount = tw.ArrivalCount
	in.RequestCount = tw.RequestCount
	if s.cfg.RateSignal == RateSignal1s {
		in.RateRps = tw.ArrivalRps1s
	} else {
		in.RateRps = tw.ArrivalRps3s
	}
	return in
}
