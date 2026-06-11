// Package stage3wire wires up the Stage 3 publishers, sinks, and gRPC
// servers. Each cmd/<svc>/main.go calls Setup once after constructing
// the windowed sampler; the returned Wireup carries handles for shutdown.
//
// Lives outside services/perf to avoid the import cycle that would arise
// if services/perf itself imported services/perf/instrumentation or
// services/perf/score (the publisher packages need perf.Sample, so
// services/perf can't depend on them in turn).
//
// Env knobs controlled here (defaults match the design plan, section 8.1):
//
//	GORDION_SCORE_PORT             - ContentionStream listen port; default 7900.
//	GORDION_INSTRUMENTATION_PORT   - InstrumentationStream listen port; default 7901; 0 disables.
//	GORDION_SUBSCRIBER_BUFFER      - per-subscriber bounded chan depth; default 64.
//	GORDION_SCORE_LOG              - "true"/"false"; emit one info log per ScoreEvent. Default true.
//	GORDION_INSTRUMENTATION_LOG    - "true"/"false"; emit one debug log per Sample. Default false.
//	GORDION_SCORE_SOURCE           - "onnx" (default when GORDION_MODEL is set), "none", or future kinds.
package stage3wire

import (
	"os"
	"strconv"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/instrumentation"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score/onnx"
	"github.com/rs/zerolog"
)

// Wireup carries handles to every Stage 3 component constructed by Setup.
// Callers Close on shutdown; the gRPC servers are stopped gracefully and
// their subscriber goroutines drained.
type Wireup struct {
	InstPub  *instrumentation.Publisher
	ScorePub *score.Publisher

	instGRPC  *instrumentation.GRPCSink // nil if GORDION_INSTRUMENTATION_PORT=0
	scoreGRPC *score.GRPCSink

	// Source is the configured score.Source (e.g. onnx.Predictor). nil
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

	// Score source selection. Empty / "none" -> no score source
	// constructed; the score side runs gRPC + log sinks but emits no
	// events. Anything else picks a concrete impl; we currently ship
	// "onnx" (default when GORDION_MODEL is set).
	srcKind := os.Getenv("GORDION_SCORE_SOURCE")
	if srcKind == "" && os.Getenv("GORDION_MODEL") != "" {
		srcKind = "onnx"
	}
	switch srcKind {
	case "", "none":
		logger.Info().
			Str("event", "stage3_score_source_disabled").
			Msg("no score source configured; ScorePub will fan no events to subscribers")
	case "onnx":
		inflight, err := strconv.Atoi(envOrDefault("GORDION_INFLIGHT_DEPTH", "16"))
		if err != nil || inflight <= 0 {
			inflight = 16
		}
		cfg := onnx.Config{
			ServiceName:    serviceName,
			ModelPath:      envOrDefault("GORDION_MODEL", ""),
			ShortlistPath:  envOrDefault("GORDION_SHORTLIST", "/etc/gordion/shortlist.json"),
			LibOnnxRuntime: envOrDefault("GORDION_LIBONNXRUNTIME", "/usr/lib/libonnxruntime.so"),
			InflightDepth:  inflight,
		}
		if cfg.ModelPath == "" {
			logger.Warn().
				Str("event", "stage3_score_source_disabled").
				Msg("GORDION_SCORE_SOURCE=onnx but GORDION_MODEL is unset; skipping ONNX source")
		} else {
			pred, err := onnx.New(cfg, w.ScorePub, logger)
			if err != nil {
				logger.Warn().Err(err).
					Str("event", "stage3_score_source_failed").
					Msg("ONNX predictor construction failed; continuing without score source")
			} else {
				w.Source = pred
				w.InstPub.Register(pred)
			}
		}
	default:
		logger.Warn().
			Str("event", "stage3_score_source_unknown").
			Str("kind", srcKind).
			Msg("unknown GORDION_SCORE_SOURCE value; skipping score source")
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
