package onnx

import (
	"math"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
)

// gru_v2 feature recipe, ported from the trainer's extract_features
// (gru_train.py @ d38b8dd) via the colleague's reference client
// (scenario_onnx_go.go::extractFeaturesRaw). The Go extractor and the
// trainer's Python MUST produce byte-identical features for the same
// sample; the golden parity test in feature_extractor_test.go guards
// the transcription.
//
// Layout (n_features = 72 + len(service_vocab)):
//
//	group 1   10  perf_counters absolute       ┐
//	group 2   10  perf_deltas                  │
//	group 3    5  arrival/request/error/rps    │ log1p'd (67 values)
//	group 4   33  timing stats (3 sections)    │
//	group 5    6  freq fields + turbo_on       │
//	group 6    3  offset_ms / offset_from_workload_ms / window_interval_ms ┘
//	group 7    |vocab|  service one-hot        (NOT log1p'd)
//	group 8    5  derived ratios               (NOT log1p'd, clipped)
//
// then StandardScaler (x - mean) / scale over the FULL vector.
//
// Online-vs-training field notes:
//   - error_count: not collected by interceptor.WindowTimingStats;
//     constant 0 in ALL training samples (injected offline), so a
//     constant 0 here matches the training distribution exactly.
//   - offset_from_workload_ms: training-only field (ms since loadgen
//     start, injected offline); no online equivalent exists, so we feed
//     0. This is a known train/serve skew -- the trainer has been asked
//     to drop it at the next retrain.
//   - offset_ms: ms since sampler run start. Online this grows without
//     bound (pod lifetime) vs 70-155 s in training; same skew note.
//   - window_interval_ms: file-level in training data; online it is the
//     actual configured sampler interval (WINDOW_INTERVAL_MS env),
//     plumbed in at construction. Do NOT hardcode 100.

// gruV2PerfCounterKeys are the 10 perf-counter names in trainer order.
// Both perf_counters (cumulative) and perf_deltas (per-window) use this
// same key set.
var gruV2PerfCounterKeys = []string{
	"LLC-load-misses", "LLC-loads", "branch-instructions", "branch-misses",
	"cycles", "dTLB-load-misses", "dTLB-loads", "instructions",
	"page-faults", "ref-cycles",
}

// extractorV2 holds the per-deployment constants resolved once at
// construction so the per-window hot path is allocation-light and
// branch-light.
type extractorV2 struct {
	mean, scale      []float64 // StandardScaler params, len == nFeatures
	oneHotIdx        int       // this service's slot in the vocab
	vocabLen         int
	windowIntervalMs float64
	nFeatures        int
}

// newExtractorV2 resolves the service's one-hot slot and captures the
// scaler. Returns (extractor, vocabMiss): vocabMiss is true when
// serviceName is not in the vocab and the extractor fell back to the
// __unknown__ bucket -- the caller MUST log this loudly, because a
// silently-unknown service degrades every prediction.
func newExtractorV2(rc *RunConfig, serviceName string, windowIntervalMs float64) (*extractorV2, bool) {
	idx := len(rc.ServiceVocab) - 1 // unknown bucket is always last
	vocabMiss := true
	for i, v := range rc.ServiceVocab {
		if v == serviceName {
			idx = i
			vocabMiss = false
			break
		}
	}
	if serviceName == unknownService {
		vocabMiss = false // explicitly unknown is not a misconfiguration
	}
	return &extractorV2{
		mean:             rc.Scaler.Mean,
		scale:            rc.Scaler.Scale,
		oneHotIdx:        idx,
		vocabLen:         len(rc.ServiceVocab),
		windowIntervalMs: windowIntervalMs,
		nFeatures:        rc.NFeatures,
	}, vocabMiss
}

// Extract converts one perf.Sample into the standardized feature vector
// of length nFeatures. Called once per Sample per window; with
// seq_len = N the Model's ring holds the last N vectors, concatenated
// into a [1, N, nFeatures] tensor.
func (e *extractorV2) Extract(s perf.Sample) []float32 {
	// raw accumulates the 67 values that get log1p'd.
	raw := make([]float64, 0, 67)

	// Group 1: perf_counters absolute.
	for _, k := range gruV2PerfCounterKeys {
		raw = append(raw, float64(s.PerfCounters[k]))
	}

	// Group 2: perf_deltas (per-window deltas).
	for _, k := range gruV2PerfCounterKeys {
		raw = append(raw, float64(s.PerfDeltas[k]))
	}

	// Group 3: arrival / request / error / rps (5). TimingWindow may be
	// nil in the very first window before the aggregator has emitted;
	// missing values are zero, matching the trainer's _safe default.
	// error_count is a constant 0 online (see file header).
	if s.TimingWindow != nil {
		raw = append(raw,
			float64(s.TimingWindow.ArrivalCount),
			float64(s.TimingWindow.RequestCount),
			0, // error_count
			s.TimingWindow.ArrivalRps1s,
			s.TimingWindow.ArrivalRps3s,
		)
	} else {
		raw = append(raw, 0, 0, 0, 0, 0)
	}

	// Group 4: timing distribution stats. 3 sections x 11 stats = 33,
	// section order processing_time, total_time, blocking_time.
	if s.TimingWindow != nil {
		raw = appendDurationStats(raw, s.TimingWindow.ProcessingTime)
		raw = appendDurationStats(raw, s.TimingWindow.TotalTime)
		raw = appendDurationStats(raw, s.TimingWindow.BlockingTime)
	} else {
		for i := 0; i < 33; i++ {
			raw = append(raw, 0)
		}
	}

	// Group 5: 5 numeric freq fields + turbo_on as binary (= 6).
	raw = append(raw,
		s.Freq.ActualFreqMHz,
		float64(s.Freq.CurrentMaxMHz),
		float64(s.Freq.ActiveN),
		s.Freq.FreqUtilPct,
		s.Freq.TscFreqMHz,
	)
	if s.Freq.TurboOn {
		raw = append(raw, 1.0)
	} else {
		raw = append(raw, 0.0)
	}

	// Group 6: sample position / window info (3). offset_from_workload_ms
	// has no online source -> 0 (documented skew).
	raw = append(raw,
		float64(s.OffsetMs),
		0, // offset_from_workload_ms
		e.windowIntervalMs,
	)

	// log1p over groups 1-6.
	out := make([]float64, 0, e.nFeatures)
	for _, v := range raw {
		out = append(out, math.Log1p(v))
	}

	// Group 7: service one-hot (NOT log1p'd).
	for i := 0; i < e.vocabLen; i++ {
		if i == e.oneHotIdx {
			out = append(out, 1.0)
		} else {
			out = append(out, 0.0)
		}
	}

	// Group 8: derived ratios (NOT log1p'd). Epsilon avoids 0/0; clip
	// ranges match the trainer.
	deltaCyc := float64(s.PerfDeltas["cycles"]) + 1e-9
	deltaInst := float64(s.PerfDeltas["instructions"]) + 1e-9
	deltaLLCM := float64(s.PerfDeltas["LLC-load-misses"]) + 1e-9
	deltaLLCL := float64(s.PerfDeltas["LLC-loads"]) + 1e-9
	deltaBr := float64(s.PerfDeltas["branch-instructions"]) + 1e-9
	deltaBrM := float64(s.PerfDeltas["branch-misses"]) + 1e-9
	deltaDTLB := float64(s.PerfDeltas["dTLB-loads"]) + 1e-9
	deltaDTLBM := float64(s.PerfDeltas["dTLB-load-misses"]) + 1e-9

	out = append(out,
		clip(deltaInst/deltaCyc, 0.0, 10.0),
		clip(deltaLLCM/deltaLLCL, 0.0, 1.0),
		clip(deltaBrM/deltaBr, 0.0, 1.0),
		clip(deltaDTLBM/deltaDTLB, 0.0, 1.0),
		clip(s.Freq.FreqUtilPct/100.0, 0.0, 1.0),
	)

	// StandardScaler over the FULL vector, then cast to float32 --
	// matching scenario_onnx_go.go::standardize (float64 math, float32
	// output).
	scaled := make([]float32, len(out))
	for i, v := range out {
		scaled[i] = float32((v - e.mean[i]) / e.scale[i])
	}
	return scaled
}

// appendDurationStats writes 11 floats from one WindowDurationStats
// block in trainer order: min, max, mean, p50, p60, p70, p75, p80, p90,
// p99, count. Order MUST match TIMING_STAT_KEYS in gru_train.py.
func appendDurationStats(dst []float64, d interceptor.WindowDurationStats) []float64 {
	return append(dst,
		float64(d.MinNs),
		float64(d.MaxNs),
		float64(d.MeanNs),
		float64(d.P50Ns),
		float64(d.P60Ns),
		float64(d.P70Ns),
		float64(d.P75Ns),
		float64(d.P80Ns),
		float64(d.P90Ns),
		float64(d.P99Ns),
		float64(d.Count),
	)
}

// clip returns v clamped to [lo, hi].
func clip(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
