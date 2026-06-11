package onnx

import (
	"math"
	"sort"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
)

// ExtractorFunc converts one perf.Sample into a flat []float32 of
// length NFeatures (whatever count the paired ONNX model expects). The
// recipe is bespoke per trained model; feature sets evolve between
// training runs as the trainer adds/removes inputs.
//
// The function is called once per Sample per window. With seq_len = N,
// the predictor's ring buffer holds the last N feature vectors, which
// are concatenated into a [1, N, NFeatures] tensor and handed to ONNX.
type ExtractorFunc func(perf.Sample) []float32

// extractors is the registry of available extractors keyed by the
// shortlist's feature_extractor field. When a new training run changes
// the feature set, register a new extractor here under a new name (e.g.
// "gru_v2") and update the trainer's Python extract_features in lockstep.
//
// gru_v1 ports the colleague's scenario_onnx_go.go::extractFeatures
// verbatim so we get a known-good baseline without re-engineering it.
var extractors = map[string]ExtractorFunc{
	"gru_v1": extractGruV1,
}

// extractorNames returns the registered extractor names sorted
// alphabetically; used in shortlist validation error messages.
func extractorNames() []string {
	names := make([]string, 0, len(extractors))
	for name := range extractors {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Lookup resolves a feature_extractor name to its ExtractorFunc.
// Returns nil if the name isn't registered.
func Lookup(name string) ExtractorFunc {
	return extractors[name]
}

// ── gru_v1: ported from scenario_onnx_go.go::extractFeatures ─────────────
//
// Produces 68 features per Sample:
//
//	10  perf_counters absolute   (log1p)
//	10  perf_deltas              (log1p)
//	 4  timing arrival / rps     (log1p)
//	33  timing distribution stats (log1p)
//	 6  freq keys + turbo_on     (log1p)
//	 5  derived ratios           (no log1p; clipped to domain)
//
// Total = 68. Order MUST match gru_train.py::extract_features in the
// trainer's repo so the trained weights apply correctly. If the trainer
// edits one, both must change in lockstep.

// gruV1PerfCounterKeys are the 10 perf-counter names the trainer
// expects, in positional order. Both perf_counters (cumulative) and
// perf_deltas (per-window) use this same key set.
var gruV1PerfCounterKeys = []string{
	"LLC-load-misses", "LLC-loads", "branch-instructions", "branch-misses",
	"cycles", "dTLB-load-misses", "dTLB-loads", "instructions",
	"page-faults", "ref-cycles",
}

// 11 timing-stat fields are read off each DurationStats block in fixed
// order (min_ns, max_ns, mean_ns, p50, p60, p70, p75, p80, p90, p99,
// count). See appendDurationStats below; the order is hard-coded there
// rather than name-driven so the extractor can't silently drop a stat.

// gruV1FreqKeys are the 5 numeric freq fields (turbo_on is handled
// separately as a bool-to-float).
var gruV1FreqKeys = []string{
	"actual_freq_mhz", "current_max_mhz", "active_n", "freq_util_pct", "tsc_freq_mhz",
}

func extractGruV1(s perf.Sample) []float32 {
	// raw accumulates the 63 values that get log1p'd. The 5 derived
	// ratios are appended raw (already in their domain ranges).
	raw := make([]float64, 0, 63)

	// Group 1: perf_counters absolute.
	for _, k := range gruV1PerfCounterKeys {
		raw = append(raw, float64(s.PerfCounters[k]))
	}

	// Group 2: perf_deltas (per-window deltas).
	for _, k := range gruV1PerfCounterKeys {
		raw = append(raw, float64(s.PerfDeltas[k]))
	}

	// Group 3: timing arrival / rps (4 fields). TimingWindow may be nil
	// in the very first window before the aggregator has emitted; treat
	// missing values as zero, matching the colleague's safeFloat default.
	if s.TimingWindow != nil {
		raw = append(raw,
			float64(s.TimingWindow.ArrivalCount),
			float64(s.TimingWindow.RequestCount),
			s.TimingWindow.ArrivalRps1s,
			s.TimingWindow.ArrivalRps3s,
		)
	} else {
		raw = append(raw, 0, 0, 0, 0)
	}

	// Group 4: timing distribution stats. 3 sections * 11 stats = 33.
	if s.TimingWindow != nil {
		raw = appendDurationStats(raw, s.TimingWindow.ProcessingTime)
		raw = appendDurationStats(raw, s.TimingWindow.TotalTime)
		raw = appendDurationStats(raw, s.TimingWindow.BlockingTime)
	} else {
		// No timing window: 33 zeros.
		for i := 0; i < 33; i++ {
			raw = append(raw, 0)
		}
	}

	// Group 5: freq keys (5 numeric) + turbo_on as binary (= 6).
	freqLookup := freqMapView(s.Freq)
	for _, k := range gruV1FreqKeys {
		raw = append(raw, freqLookup[k])
	}
	if s.Freq.TurboOn {
		raw = append(raw, 1.0)
	} else {
		raw = append(raw, 0.0)
	}

	// log1p over all 63 above (matches the trainer's identity-scaler
	// path: log1p is the only transform applied before training).
	logRaw := make([]float64, len(raw))
	for i, v := range raw {
		logRaw[i] = math.Log1p(v)
	}

	// Group 6: 5 derived ratios. Computed from perf_deltas (NOT log1p'd).
	// Epsilon (1e-9) avoids 0/0; clip ranges match the trainer.
	deltaCyc := float64(s.PerfDeltas["cycles"]) + 1e-9
	deltaInst := float64(s.PerfDeltas["instructions"]) + 1e-9
	deltaLLCM := float64(s.PerfDeltas["LLC-load-misses"]) + 1e-9
	deltaLLCL := float64(s.PerfDeltas["LLC-loads"]) + 1e-9
	deltaBr := float64(s.PerfDeltas["branch-instructions"]) + 1e-9
	deltaBrM := float64(s.PerfDeltas["branch-misses"]) + 1e-9
	deltaDTLB := float64(s.PerfDeltas["dTLB-loads"]) + 1e-9
	deltaDTLBM := float64(s.PerfDeltas["dTLB-load-misses"]) + 1e-9

	ipc := clip(deltaInst/deltaCyc, 0.0, 10.0)
	llcMrate := clip(deltaLLCM/deltaLLCL, 0.0, 1.0)
	brMrate := clip(deltaBrM/deltaBr, 0.0, 1.0)
	dtlbMrate := clip(deltaDTLBM/deltaDTLB, 0.0, 1.0)
	freqUtil := clip(s.Freq.FreqUtilPct/100.0, 0.0, 1.0)

	// Concatenate logRaw (63) + ratios (5) = 68.
	out := make([]float32, 0, 68)
	for _, v := range logRaw {
		out = append(out, float32(v))
	}
	out = append(out, float32(ipc), float32(llcMrate), float32(brMrate), float32(dtlbMrate), float32(freqUtil))
	return out
}

// appendDurationStats writes 11 floats from one DurationStats block to
// dst, in the order gruV1TimingStatKeys defines. Order MUST match the
// trainer's extract_features in gru_train.py.
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

// freqMapView returns a map view of the numeric freq fields keyed by
// gruV1FreqKeys. Cheaper than reflection and avoids drift between the
// key list and the field-access logic.
func freqMapView(f perf.FreqSample) map[string]float64 {
	return map[string]float64{
		"actual_freq_mhz": f.ActualFreqMHz,
		"current_max_mhz": float64(f.CurrentMaxMHz),
		"active_n":        float64(f.ActiveN),
		"freq_util_pct":   f.FreqUtilPct,
		"tsc_freq_mhz":    f.TscFreqMHz,
	}
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
