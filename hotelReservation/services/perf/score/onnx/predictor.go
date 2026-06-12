package onnx

import (
	"sync"
	"sync/atomic"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score"
	"github.com/rs/zerolog"
)

// Source kind tag stamped into every published ScoreEvent.SourceKind.
// Mitigation systems reading the stream can filter by this when
// multiple sources are wired up to the same score.Publisher.
const sourceKind = "onnx"

// Output keys the predictor expects in the shortlist's Outputs map. If
// the shortlist or the loaded ONNX is missing one of these, the
// predictor proceeds in "transitional single-head" mode: the missing
// head is published as 0.0 with a one-time warning.
const (
	outKeyP50Trend  = "p50_trend_pred"
	outKeyTailTrend = "tail_trend_label"
)

// Config holds all the per-Predictor knobs. cmd/<svc>/main.go's
// stage3wire.Setup constructs this from env vars (GORDION_MODEL,
// GORDION_SHORTLIST, GORDION_LIBONNXRUNTIME, GORDION_INFLIGHT_DEPTH).
type Config struct {
	ServiceName    string
	ModelPath      string // .onnx file inside the image, e.g. /etc/gordion/model.onnx
	ShortlistPath  string // metadata JSON, e.g. /etc/gordion/shortlist.json
	LibOnnxRuntime string // libonnxruntime.so path; "" -> ORT default search
	InflightDepth  int    // bounded sampler->predictor channel depth
}

// Predictor implements score.Source by way of instrumentation.Sink: it
// receives Samples via Emit (non-blocking, drop-on-overflow), runs ONNX
// inference per window in its loop goroutine, and publishes ScoreEvents
// through the injected score.Publisher.
//
// Lifecycle:
//
//	pred, err := onnx.New(cfg, scorePub, logger)
//	instrumentationPub.Register(pred)   // pred is an instrumentation.Sink
//	defer pred.Close()
//
// On any ONNX-side error during inference, the predictor logs and
// continues: predictor failures never crash the service. Sustained
// failures show up as zero ScoreEvents on the wire and a steady stream
// of warning logs.
type Predictor struct {
	cfg       Config
	shortlist *Shortlist
	session   *Session
	ring      *Ring
	extractor ExtractorFunc
	pub       *score.Publisher
	logger    zerolog.Logger

	ch chan perf.Sample
	wg sync.WaitGroup

	// Closing quit signals the loop to drain and exit. closeOnce ensures
	// Close is idempotent.
	quit      chan struct{}
	closeOnce sync.Once

	// Atomic counters surfaced via metrics in M8 / a future export
	// path. Exposed via Stats().
	dropped     uint64 // sampler -> predictor channel was full
	inferErrors uint64 // session.Run failures (debounced log)

	// One-time warning state. We log once at startup if a head is
	// missing; we don't spam per-window.
	warnedMissingHeads bool

	// p50TrendBound / tailTrendBound cache the result of HasOutput at
	// New(...) time so the loop doesn't repeat the lookup.
	p50TrendBound  bool
	tailTrendBound bool
}

// New constructs and starts a Predictor. Loads the shortlist, picks
// the configured feature_extractor, opens the ONNX session, allocates
// the bounded channel, and kicks off the inference goroutine.
//
// On any setup failure the predictor returns a non-nil error and the
// caller (stage3wire.Setup) logs and proceeds without ONNX scoring.
// This never propagates a panic; the gRPC service keeps serving
// traffic.
func New(cfg Config, pub *score.Publisher, logger zerolog.Logger) (*Predictor, error) {
	sl, err := LoadShortlist(cfg.ShortlistPath)
	if err != nil {
		return nil, err
	}

	extractor := Lookup(sl.FeatureExtractor)
	if extractor == nil {
		return nil, errInvalidExtractor(sl.FeatureExtractor)
	}

	sess, err := NewSession(cfg.ModelPath, sl, cfg.LibOnnxRuntime)
	if err != nil {
		return nil, err
	}

	depth := cfg.InflightDepth
	if depth <= 0 {
		depth = 16
	}

	p := &Predictor{
		cfg:            cfg,
		shortlist:      sl,
		session:        sess,
		ring:           NewRing(sl.SeqLen),
		extractor:      extractor,
		pub:            pub,
		logger:         logger,
		ch:             make(chan perf.Sample, depth),
		quit:           make(chan struct{}),
		p50TrendBound:  sess.HasOutput(outKeyP50Trend),
		tailTrendBound: sess.HasOutput(outKeyTailTrend),
	}

	// Transitional single-head case: warn once at startup if any
	// expected head is missing from the shortlist / model. The loop
	// publishes 0 for missing heads.
	if !p.p50TrendBound || !p.tailTrendBound {
		p.warnedMissingHeads = true
		p.logger.Warn().
			Str("event", "score_onnx_missing_head").
			Str("service", cfg.ServiceName).
			Bool("p50_trend_bound", p.p50TrendBound).
			Bool("tail_trend_bound", p.tailTrendBound).
			Str("model_path", cfg.ModelPath).
			Str("shortlist_path", cfg.ShortlistPath).
			Msg("ONNX score source running with missing output head; absent fields will publish as 0")
	}

	p.logger.Info().
		Str("event", "score_onnx_started").
		Str("service", cfg.ServiceName).
		Str("model_path", cfg.ModelPath).
		Str("schema_version", sl.SchemaVersion).
		Str("feature_extractor", sl.FeatureExtractor).
		Int("seq_len", sl.SeqLen).
		Int("n_features", sl.NFeatures).
		Int("inflight_depth", depth).
		Msg("ONNX score source started")

	p.wg.Add(1)
	go p.loop()

	return p, nil
}

// Emit satisfies instrumentation.Sink. Non-blocking: if the inflight
// channel is full (predictor falling behind), increment the dropped
// counter and discard the Sample. The sampler tick MUST NOT block on
// inference jitter.
func (p *Predictor) Emit(s perf.Sample) {
	select {
	case p.ch <- s:
	default:
		atomic.AddUint64(&p.dropped, 1)
	}
}

// Close stops the loop goroutine, waits for it to drain, then releases
// the ONNX session. Idempotent.
func (p *Predictor) Close() error {
	p.closeOnce.Do(func() {
		close(p.quit)
	})
	p.wg.Wait()
	if p.session != nil {
		_ = p.session.Close()
		p.session = nil
	}
	p.logger.Info().
		Str("event", "score_onnx_stopped").
		Str("service", p.cfg.ServiceName).
		Uint64("total_dropped", atomic.LoadUint64(&p.dropped)).
		Uint64("total_inference_errors", atomic.LoadUint64(&p.inferErrors)).
		Msg("ONNX score source stopped")
	return nil
}

// Stats returns observability counters; useful for a future Prometheus
// exporter or admin endpoint.
type Stats struct {
	Dropped         uint64
	InferenceErrors uint64
}

// Stats returns a snapshot of the predictor's counters.
func (p *Predictor) Stats() Stats {
	return Stats{
		Dropped:         atomic.LoadUint64(&p.dropped),
		InferenceErrors: atomic.LoadUint64(&p.inferErrors),
	}
}

// loop is the inference goroutine. Reads Samples from p.ch, pushes
// each into the seq ring, runs inference once the ring is full, and
// publishes a ScoreEvent through p.pub.
func (p *Predictor) loop() {
	defer p.wg.Done()

	// Pre-bind references read every iteration to avoid struct field
	// lookup in the tight loop.
	nFeat := p.shortlist.NFeatures
	seqLen := p.shortlist.SeqLen
	inputBuf := p.session.InputBuffer() // [seqLen * nFeat]float32, owned by tensor

	for {
		select {
		case <-p.quit:
			return
		case s, ok := <-p.ch:
			if !ok {
				return
			}
			p.ring.Push(s)
			if !p.ring.Full() {
				continue // warmup
			}

			// Fill the bound input tensor in place. View() returns
			// samples in arrival order (oldest first), which matches
			// what GRU-style models expect.
			view := p.ring.View()
			windowOK := true
			for i := 0; i < seqLen; i++ {
				feats := p.extractor(view[i])
				// Defensive: feature count drift between trainer and
				// extractor would corrupt the tensor. Skip the whole
				// window rather than feeding garbage.
				if len(feats) != nFeat {
					atomic.AddUint64(&p.inferErrors, 1)
					p.warnFeatureMismatch(len(feats), nFeat)
					windowOK = false
					break
				}
				copy(inputBuf[i*nFeat:(i+1)*nFeat], feats)
			}
			if !windowOK {
				continue
			}

			if err := p.session.Run(); err != nil {
				atomic.AddUint64(&p.inferErrors, 1)
				p.warnInferError(err)
				continue
			}

			ev := score.ScoreEvent{
				SampleID:     int64(s.SampleID),
				Timestamp:    s.Timestamp,
				Service:      p.cfg.ServiceName,
				ModelVersion: p.shortlist.SchemaVersion,
				SourceKind:   sourceKind,
			}
			if p.p50TrendBound {
				out := p.session.Output(outKeyP50Trend)
				if len(out) > 0 {
					ev.P50TrendPred = out[0]
				}
			}
			if p.tailTrendBound {
				out := p.session.Output(outKeyTailTrend)
				if len(out) > 0 {
					ev.TailTrendLabel = out[0]
				}
			}
			p.pub.Publish(ev)
		}
	}
}

// warnInferError logs a debounced warning. We rate-limit aggressively
// because at 10 Hz a sustained failure produces 600 lines/min, which
// drowns the log. Implementation: only log the first error and then
// every Nth error after that.
func (p *Predictor) warnInferError(err error) {
	const everyN = 100
	count := atomic.LoadUint64(&p.inferErrors)
	if count == 1 || count%everyN == 0 {
		p.logger.Warn().
			Str("event", "score_onnx_run_error").
			Str("service", p.cfg.ServiceName).
			Uint64("count", count).
			Err(err).
			Msg("ONNX session.Run failed")
	}
}

func (p *Predictor) warnFeatureMismatch(got, want int) {
	const everyN = 100
	count := atomic.LoadUint64(&p.inferErrors)
	if count == 1 || count%everyN == 0 {
		p.logger.Warn().
			Str("event", "score_onnx_feature_mismatch").
			Str("service", p.cfg.ServiceName).
			Uint64("count", count).
			Int("got", got).
			Int("want", want).
			Str("feature_extractor", p.shortlist.FeatureExtractor).
			Msg("feature extractor produced wrong number of features; skipping window")
	}
}

// errInvalidExtractor is a small typed error so callers can
// distinguish setup errors from runtime errors if they ever want to.
type errInvalidExtractorType string

func (e errInvalidExtractorType) Error() string {
	return "unknown feature_extractor: " + string(e) + " (registered: see onnx.extractorNames())"
}

func errInvalidExtractor(name string) error { return errInvalidExtractorType(name) }
