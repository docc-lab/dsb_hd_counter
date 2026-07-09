// Package stage3wire wires up the Stage 3 publishers, sinks, and gRPC
// servers. Each cmd/<svc>/main.go calls Setup once after constructing
// the windowed sampler; the returned Wireup carries handles for shutdown.
//
// Lives outside services/perf to avoid the import cycle that would arise
// if services/perf itself imported services/perf/instrumentation or
// services/perf/score (the publisher packages need perf.Sample, so
// services/perf can't depend on them in turn).
//
// Env knobs controlled here:
//
//	GORDION_SCORE_PORT             - ContentionStream listen port; default 7900.
//	GORDION_INSTRUMENTATION_PORT   - InstrumentationStream listen port; default 7901; 0 disables.
//	GORDION_SUBSCRIBER_BUFFER      - per-subscriber bounded chan depth; default 64.
//	GORDION_SCORE_LOG              - "true"/"false"; emit one info log per ScoreEvent. Default true.
//	GORDION_INSTRUMENTATION_LOG    - "true"/"false"; emit one debug log per Sample. Default false.
//	GORDION_SCORE_SOURCE           - "gordion" (default when the gordion config file exists),
//	                                 "none", or a registered comparator kind. "onnx" is a
//	                                 deprecated alias for gordion-with-prediction.
//	GORDION_CONFIG                 - gordion scorer config JSON; default /etc/gordion/gordion.json.
//	GORDION_MODEL                  - .onnx path; presence enables prediction-ON.
//	GORDION_MODEL_CONFIG           - trainer-emitted run config JSON; default /etc/gordion/model-config.json.
//	GORDION_LIBONNXRUNTIME         - libonnxruntime.so path (prediction-ON only).
//	GORDION_INFLIGHT_DEPTH         - sampler->scorer channel depth; default 16.
package stage3wire

import (
	"os"
	"strconv"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/instrumentation"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score/gordion"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score/onnx"
	"github.com/rs/zerolog"
)

// sourceBuilder constructs one score.Source kind. Comparator algorithms
// (FIRM p50/p90 ratio, CPI signal, slowdown ratio, MAD z-score, SLO
// burn rate) slot in by adding one entry to sourceBuilders -- they
// receive the same deps and read their own env/config.
type sourceBuilder func(serviceName string, pub *score.Publisher, logger zerolog.Logger) (score.Source, error)

// sourceBuilders is the score-source registry keyed by
// GORDION_SCORE_SOURCE. "none" and the deprecated "onnx" alias are
// handled in Setup before the registry lookup.
var sourceBuilders = map[string]sourceBuilder{
	"gordion": buildGordion,
}

// buildGordion wires the Gordion formula source, attaching the ONNX
// prediction model when GORDION_MODEL is set. Model construction
// failure degrades to prediction-off (logged) -- scoring must not be
// lost because a model artifact is broken.
func buildGordion(serviceName string, pub *score.Publisher, logger zerolog.Logger) (score.Source, error) {
	inflight, err := strconv.Atoi(envOrDefault("GORDION_INFLIGHT_DEPTH", "16"))
	if err != nil || inflight <= 0 {
		inflight = 16
	}

	var model *onnx.Model
	if modelPath := os.Getenv("GORDION_MODEL"); modelPath != "" {
		windowMs, err := strconv.ParseFloat(envOrDefault("WINDOW_INTERVAL_MS", "100"), 64)
		if err != nil || windowMs <= 0 {
			windowMs = 100
		}
		model, err = onnx.NewModel(onnx.ModelConfig{
			ServiceName:      serviceName,
			ModelPath:        modelPath,
			RunConfigPath:    envOrDefault("GORDION_MODEL_CONFIG", "/etc/gordion/model-config.json"),
			LibOnnxRuntime:   envOrDefault("GORDION_LIBONNXRUNTIME", "/usr/lib/libonnxruntime.so"),
			WindowIntervalMs: windowMs,
		}, logger)
		if err != nil {
			logger.Warn().Err(err).
				Str("event", "stage3_prediction_disabled").
				Str("model_path", modelPath).
				Msg("ONNX model construction failed; continuing in prediction-OFF mode")
			model = nil
		}
	}

	return gordion.New(gordion.SourceConfig{
		ServiceName:   serviceName,
		ConfigPath:    envOrDefault("GORDION_CONFIG", "/etc/gordion/gordion.json"),
		Model:         model,
		InflightDepth: inflight,
	}, pub, logger)
}

// Wireup carries handles to every Stage 3 component constructed by Setup.
// Callers Close on shutdown; the gRPC servers are stopped gracefully and
// their subscriber goroutines drained.
type Wireup struct {
	InstPub  *instrumentation.Publisher
	ScorePub *score.Publisher

	instGRPC  *instrumentation.GRPCSink // nil if GORDION_INSTRUMENTATION_PORT=0
	scoreGRPC *score.GRPCSink

	// Source is the configured score.Source (e.g. gordion.Source). nil
	// when GORDION_SCORE_SOURCE is "none" / unset / unknown.
	Source score.Source
}

// Setup constructs all Stage 3 components, attaches the instrumentation
// publisher to the sampler, and starts the gRPC servers in dedicated
// goroutines. Returns a Wireup that callers must Close on shutdown.
//
// Setup never returns an error from listener init: instead it logs and
// proceeds without that listener (Stage 3 failures must never break the
// gRPC service). A truly broken setup (e.g. invalid env var) does
// return an error.
func Setup(serviceName string, sampler perf.WindowedSampler, logger zerolog.Logger) (*Wireup, error) {
	scorePort := envOrDefault("GORDION_SCORE_PORT", "7900")
	instPort := envOrDefault("GORDION_INSTRUMENTATION_PORT", "7901")
	subBuf, err := strconv.Atoi(envOrDefault("GORDION_SUBSCRIBER_BUFFER", "64"))
	if err != nil || subBuf <= 0 {
		subBuf = 64
	}

	w := &Wireup{
		InstPub:  instrumentation.NewPublisher(),
		ScorePub: score.NewPublisher(),
	}

	// Score-side: log sink (default on) + gRPC sink :7900.
	if envBool("GORDION_SCORE_LOG", true) {
		w.ScorePub.Register(score.NewLogSink(logger))
	}
	w.scoreGRPC = score.NewGRPCSink(":"+scorePort, logger, subBuf)
	w.ScorePub.Register(w.scoreGRPC)
	go func() {
		if err := w.scoreGRPC.Serve(); err != nil {
			logger.Error().Err(err).Msg("ContentionStream gRPC server exited")
		}
	}()

	// Instrumentation-side: optional log sink (default off; 10 Hz of
	// log lines is a lot) + gRPC sink :7901 unless port=0.
	if envBool("GORDION_INSTRUMENTATION_LOG", false) {
		w.InstPub.Register(instrumentation.NewLogSink(logger, serviceName))
	}
	if instPort != "0" {
		w.instGRPC = instrumentation.NewGRPCSink(":"+instPort, serviceName, logger, subBuf)
		w.InstPub.Register(w.instGRPC)
		go func() {
			if err := w.instGRPC.Serve(); err != nil {
				logger.Error().Err(err).Msg("InstrumentationStream gRPC server exited")
			}
		}()
	} else {
		logger.Info().
			Str("event", "stage3_instrumentation_grpc_disabled").
			Msg("GORDION_INSTRUMENTATION_PORT=0; skipping InstrumentationStream listener")
	}

	// Score source selection. Empty defaults to "gordion" when the
	// gordion config file exists (mounted ConfigMap or baked into the
	// image); "none" (or a missing config) runs the gRPC + log sinks
	// with no events. The deprecated "onnx" value predates the two-mode
	// design and now means gordion-with-prediction.
	srcKind := os.Getenv("GORDION_SCORE_SOURCE")
	gordionCfgPath := envOrDefault("GORDION_CONFIG", "/etc/gordion/gordion.json")
	if srcKind == "" {
		if _, err := os.Stat(gordionCfgPath); err == nil {
			srcKind = "gordion"
		}
	}
	if srcKind == "onnx" {
		logger.Warn().
			Str("event", "stage3_score_source_deprecated").
			Msg("GORDION_SCORE_SOURCE=onnx is deprecated; treating as \"gordion\" " +
				"(prediction enabled by GORDION_MODEL). Update the deployment env.")
		srcKind = "gordion"
	}

	switch srcKind {
	case "", "none":
		logger.Info().
			Str("event", "stage3_score_source_disabled").
			Msg("no score source configured; ScorePub will fan no events to subscribers")
	default:
		build, ok := sourceBuilders[srcKind]
		if !ok {
			logger.Warn().
				Str("event", "stage3_score_source_unknown").
				Str("kind", srcKind).
				Msg("unknown GORDION_SCORE_SOURCE value; skipping score source")
			break
		}
		src, err := build(serviceName, w.ScorePub, logger)
		if err != nil {
			logger.Warn().Err(err).
				Str("event", "stage3_score_source_failed").
				Str("kind", srcKind).
				Msg("score source construction failed; continuing without score source")
		} else {
			w.Source = src
			w.InstPub.Register(src)
		}
	}

	// Hand the publisher to the sampler. After this point, every
	// takeSample tick fans the new Sample to all registered Sinks
	// (LogSink, GRPCSink, and the score Source if configured).
	sampler.AttachInstrumentationPublisher(w.InstPub)

	logger.Info().
		Str("event", "stage3_wired").
		Str("service", serviceName).
		Str("score_port", scorePort).
		Str("instrumentation_port", instPort).
		Int("subscriber_buffer", subBuf).
		Msg("Stage 3 publishers wired")

	return w, nil
}

// Close gracefully tears down Stage 3 in shutdown order:
//
//  1. Stop the score Source first (no more ScoreEvents published).
//  2. GracefulStop both gRPC servers (drain in-flight subscriber streams).
//  3. Close both publishers (idempotently re-closes already-closed sinks).
//
// Detach from the sampler is implicit: callers should already have
// stopped the sampler before Close. The sampler holds a reference to
// InstPub; Publish on a closed publisher with no sinks is a no-op.
func (w *Wireup) Close() error {
	var firstErr error
	collect := func(err error) {
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}

	if w.Source != nil {
		collect(w.Source.Close())
	}
	if w.scoreGRPC != nil {
		collect(w.scoreGRPC.Close())
	}
	if w.instGRPC != nil {
		collect(w.instGRPC.Close())
	}
	collect(w.ScorePub.Close())
	collect(w.InstPub.Close())
	return firstErr
}

func envOrDefault(name, def string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return def
}

func envBool(name string, def bool) bool {
	v := os.Getenv(name)
	if v == "" {
		return def
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def
	}
	return b
}
