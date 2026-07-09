package onnx

import (
	"fmt"
	"sync/atomic"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	"github.com/rs/zerolog"
)

// ModelConfig holds the per-Model knobs. score/gordion constructs this
// from env vars (GORDION_MODEL, GORDION_MODEL_CONFIG,
// GORDION_LIBONNXRUNTIME) plus the sampler's configured window interval.
type ModelConfig struct {
	ServiceName      string
	ModelPath        string  // .onnx inside the image, e.g. /etc/gordion/model.onnx
	RunConfigPath    string  // trainer-emitted run config JSON
	LibOnnxRuntime   string  // libonnxruntime.so path; "" -> ORT default search
	WindowIntervalMs float64 // actual configured WINDOW_INTERVAL_MS (not hardcoded)
}

// Model wraps ring + extractor + ONNX session into a synchronous
// predictor: Push one Sample per window, get back the predicted
// next-window y50 once the sequence ring is warm.
//
// Model is NOT a score.Source and never publishes: score/gordion owns
// the scoring loop and calls Push from its single loop goroutine, which
// also satisfies Session's no-concurrent-Run contract.
//
// Inference failures are counted, logged (debounced), and surface as
// ok=false -- the caller degrades to formula-only for that window.
// A Model never crashes the serving pod.
type Model struct {
	rc        *RunConfig
	session   *Session
	ring      *Ring
	extractor *extractorV2
	logger    zerolog.Logger

	inferErrors uint64
}

// NewModel loads the run config, builds the extractor, and opens the
// ONNX session. Any failure returns an error; the caller (gordion
// source) logs it and continues in prediction-off mode.
func NewModel(cfg ModelConfig, logger zerolog.Logger) (*Model, error) {
	rc, err := LoadRunConfig(cfg.RunConfigPath)
	if err != nil {
		return nil, err
	}

	if cfg.WindowIntervalMs <= 0 {
		return nil, fmt.Errorf("window interval must be > 0 (got %v)", cfg.WindowIntervalMs)
	}

	extractor, vocabMiss := newExtractorV2(rc, cfg.ServiceName, cfg.WindowIntervalMs)
	if vocabMiss {
		// Loud by design: an unnoticed fallback to __unknown__ would
		// silently degrade every prediction for the pod's lifetime.
		logger.Warn().
			Str("event", "score_onnx_vocab_miss").
			Str("service", cfg.ServiceName).
			Strs("service_vocab", rc.ServiceVocab).
			Msg("service name not in model vocab; one-hot falls back to __unknown__ -- " +
				"predictions will be degraded; check ServiceName vs the trainer's vocab")
	}

	sess, err := NewSession(cfg.ModelPath, rc.Config.Model.SequenceLength, rc.NFeatures, cfg.LibOnnxRuntime)
	if err != nil {
		return nil, err
	}

	m := &Model{
		rc:        rc,
		session:   sess,
		ring:      NewRing(rc.Config.Model.SequenceLength),
		extractor: extractor,
		logger:    logger,
	}

	logger.Info().
		Str("event", "score_onnx_model_loaded").
		Str("service", cfg.ServiceName).
		Str("model_path", cfg.ModelPath).
		Str("model_version", rc.Version()).
		Int("seq_len", rc.Config.Model.SequenceLength).
		Int("n_features", rc.NFeatures).
		Float64("window_interval_ms", cfg.WindowIntervalMs).
		Msg("ONNX prediction model loaded")

	return m, nil
}

// Push feeds one Sample into the sequence ring and, once the ring is
// warm (seq_len samples), runs inference. Returns (yhat, true) with
// yhat clipped to [0, 1] -- the ONNX graph does not clip; this
// replicates the trainer's np.clip(preds, 0, 1) -- or (0, false)
// during warm-up or on inference error.
//
// Synchronous and single-goroutine by contract: only the gordion loop
// goroutine calls Push.
func (m *Model) Push(s perf.Sample) (float32, bool) {
	m.ring.Push(s)
	if !m.ring.Full() {
		return 0, false // warm-up
	}

	nFeat := m.rc.NFeatures
	seqLen := m.rc.Config.Model.SequenceLength
	buf := m.session.InputBuffer()

	view := m.ring.View()
	for i := 0; i < seqLen; i++ {
		feats := m.extractor.Extract(view[i])
		// Defensive: length drift would corrupt the tensor. Skip the
		// window rather than feeding garbage. (Construction-time
		// validation makes this unreachable unless the recipe itself is
		// edited inconsistently.)
		if len(feats) != nFeat {
			m.warnInferError(fmt.Errorf("feature vector length %d != n_features %d", len(feats), nFeat))
			return 0, false
		}
		copy(buf[i*nFeat:(i+1)*nFeat], feats)
	}

	if err := m.session.Run(); err != nil {
		m.warnInferError(err)
		return 0, false
	}

	out := m.session.Output()
	if len(out) == 0 {
		m.warnInferError(fmt.Errorf("empty output tensor"))
		return 0, false
	}
	y := out[0]
	if y < 0 {
		y = 0
	} else if y > 1 {
		y = 1
	}
	return y, true
}

// Version returns the trained-model identifier for
// ScoreEvent.ModelVersion.
func (m *Model) Version() string { return m.rc.Version() }

// Stats returns observability counters.
type ModelStats struct {
	InferenceErrors uint64
}

// Stats returns a snapshot of the model's counters.
func (m *Model) Stats() ModelStats {
	return ModelStats{InferenceErrors: atomic.LoadUint64(&m.inferErrors)}
}

// Close releases the ONNX session. Idempotent via Session.Close.
func (m *Model) Close() error {
	if m.session != nil {
		_ = m.session.Close()
		m.session = nil
	}
	return nil
}

// warnInferError logs a debounced warning: at 10 Hz a sustained failure
// would otherwise produce 600 log lines/min. Only the first error and
// every Nth after that are logged.
func (m *Model) warnInferError(err error) {
	const everyN = 100
	count := atomic.AddUint64(&m.inferErrors, 1)
	if count == 1 || count%everyN == 0 {
		m.logger.Warn().
			Str("event", "score_onnx_run_error").
			Uint64("count", count).
			Err(err).
			Msg("ONNX inference failed; window degraded to formula-only")
	}
}
