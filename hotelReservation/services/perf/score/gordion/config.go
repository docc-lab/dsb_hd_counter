// Package gordion implements the Gordion contention scoring algorithm
// (Algorithm 1 of the paper) as the in-pod score.Source. Every window it
// computes, from the interceptor's within-service latency stats:
//
//	y50, y90        tanh scores of the freq-normalized, Gaussian-smoothed
//	                p50/p90 latency against baseline stats from stage 1
//	%ext,50 %ext,90 extrinsic share of each shift, from the deviation
//	                against the stage-1 intrinsic arrival-rate->latency
//	                curve D(lambda)
//
// This is the "prediction OFF" mode in full. When an ONNX model is
// attached (prediction ON), the source additionally publishes the
// model's predicted next-window y-hat50; the formula outputs are always
// computed and published either way. See MITIGATION-INTERFACE.md for
// the wire semantics.
//
// All calibration inputs come from stage 1 and are supplied via a
// mounted JSON config (GORDION_CONFIG) plus the curve CSV it points at;
// nothing is hardcoded to a node or service.
package gordion

import (
	"encoding/json"
	"fmt"
	"os"
)

// Latency-section and rate-signal selector values.
const (
	SectionProcessingTime = "processing_time"
	SectionTotalTime      = "total_time"
	SectionBlockingTime   = "blocking_time"

	RateSignal1s = "arrival_rps_1s"
	RateSignal3s = "arrival_rps_3s"
)

// Config is the gordion scorer's calibration + tuning file, mounted at
// GORDION_CONFIG (default /etc/gordion/gordion.json). All latency
// magnitudes are in KILOCYCLES (kcyc = us x MHz / 1000), the
// frequency-invariant domain: normalized latency = (latency_ns / 1000)
// x freq_mhz / 1000. Stage 1's curve.csv svc_*_norm_kcyc columns are
// already in this domain; the baseline scalars must be computed the
// same way from the no-stressor baseline run, using the SAME
// latency_section as configured here.
type Config struct {
	// Version flows into ScoreEvent.ModelVersion when prediction is off.
	// Bump it when baseline stats / curve / tuning change so mitigation
	// consumers can detect recalibration. Default "gordion-v1".
	Version string `json:"version"`

	// K is the tanh sensitivity (Algorithm 1's k). Default 1.0.
	K float64 `json:"k"`

	// SmoothWindow is the causal Gaussian window w in samples. Default
	// 30 (= 3 s at the 100 ms window interval).
	SmoothWindow int `json:"smooth_window"`

	// LatencySection picks which interceptor duration block drives the
	// score: processing_time (default; matches the stage-1 curve
	// columns), total_time, or blocking_time. The baseline scalars and
	// the curve CSV MUST come from the same section.
	LatencySection string `json:"latency_section"`

	Baseline struct {
		P50Kcyc     float64 `json:"p50_kcyc"`     // baseline p50 (kcyc) = Algorithm 1's p50*f_b
		P90Kcyc     float64 `json:"p90_kcyc"`     // baseline p90 (kcyc)
		Sigma50Kcyc float64 `json:"sigma50_kcyc"` // std of baseline normalized p50 stream
		Sigma90Kcyc float64 `json:"sigma90_kcyc"` // std of baseline normalized p90 stream
		// FreqMHz is the fallback frequency used to normalize windows
		// whose freq sampling failed (Freq.OK=false). Set to the
		// baseline experiment's frequency (f_b).
		FreqMHz float64 `json:"freq_mhz"`
	} `json:"baseline"`

	// CurveCSV is the stage-1 intrinsic curve file (curve_aggregate.py
	// output). Required unless ablations.no_ext.
	CurveCSV     string `json:"curve_csv"`
	CurveColumns struct {
		Rate string `json:"rate"` // default "target_rps"
		P50  string `json:"p50"`  // default "svc_p50_norm_kcyc"
		P90  string `json:"p90"`  // default "svc_p90_norm_kcyc"
	} `json:"curve_columns"`

	// RateSignal picks the arrival-rate stream that indexes the curve:
	// arrival_rps_1s or arrival_rps_3s (default). The chosen stream is
	// additionally Gaussian-smoothed unless ablations.raw_rate_index.
	RateSignal string `json:"rate_signal"`

	Failure struct {
		// SloP90Ms: when > 0, a window whose RAW (wall-clock, not
		// kcyc-normalized) section p90 exceeds this many milliseconds
		// short-circuits to y = 1.0.
		SloP90Ms float64 `json:"slo_p90_ms"`
		// StallWindows: this many CONSECUTIVE windows with arrivals but
		// zero completions short-circuit to y = 1.0. Default 5. A single
		// empty window at low rate is normal and only holds the previous
		// smoothed latency.
		StallWindows int `json:"stall_windows"`
	} `json:"failure"`

	// IdleHoldWindows bounds the zero-completion hold: after this many
	// CONSECUTIVE windows with no completions AND no arrivals (service
	// genuinely idle, not stalled), the scorer stops publishing and
	// resets, so late subscribers never see a stale frozen score from
	// the end of the last load period. Scoring restarts (with smoothing
	// warm-up) when traffic returns. Default 100 (= 10 s at the 100 ms
	// window interval).
	IdleHoldWindows int `json:"idle_hold_windows"`

	// Ablations remove or replace one design element at a time, for the
	// internal ablation studies. All default false (full pipeline).
	Ablations struct {
		NoSmoothing   bool `json:"no_smoothing"`     // skip Gaussian smoothing of T50/T90
		NoExt         bool `json:"no_ext"`           // don't compute %ext (published as 0)
		RawRateIndex  bool `json:"raw_rate_index"`   // index the curve with the raw instantaneous rate
		UseCurrentY50 bool `json:"use_current_y50"`  // ignore the model even if deployed (prediction_on=false)
	} `json:"ablations"`
}

// LoadConfig reads, defaults, and validates the gordion config at path.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read gordion config %q: %w", path, err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse gordion config %q: %w", path, err)
	}
	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid gordion config %q: %w", path, err)
	}
	return &cfg, nil
}

func (c *Config) applyDefaults() {
	if c.Version == "" {
		c.Version = "gordion-v1"
	}
	if c.K == 0 {
		c.K = 1.0
	}
	if c.SmoothWindow == 0 {
		c.SmoothWindow = 30
	}
	if c.LatencySection == "" {
		c.LatencySection = SectionProcessingTime
	}
	if c.CurveColumns.Rate == "" {
		c.CurveColumns.Rate = "target_rps"
	}
	if c.CurveColumns.P50 == "" {
		c.CurveColumns.P50 = "svc_p50_norm_kcyc"
	}
	if c.CurveColumns.P90 == "" {
		c.CurveColumns.P90 = "svc_p90_norm_kcyc"
	}
	if c.RateSignal == "" {
		c.RateSignal = RateSignal3s
	}
	if c.Failure.StallWindows == 0 {
		c.Failure.StallWindows = 5
	}
	if c.IdleHoldWindows == 0 {
		c.IdleHoldWindows = 100
	}
}

// Validate rejects configs that would score garbage. Returns error,
// never panics: a bad config disables the score source but the gRPC
// service keeps serving.
func (c *Config) Validate() error {
	if c.K <= 0 {
		return fmt.Errorf("k must be > 0 (got %v)", c.K)
	}
	if c.SmoothWindow < 1 {
		return fmt.Errorf("smooth_window must be >= 1 (got %d)", c.SmoothWindow)
	}
	switch c.LatencySection {
	case SectionProcessingTime, SectionTotalTime, SectionBlockingTime:
	default:
		return fmt.Errorf("latency_section must be one of %s|%s|%s (got %q)",
			SectionProcessingTime, SectionTotalTime, SectionBlockingTime, c.LatencySection)
	}
	switch c.RateSignal {
	case RateSignal1s, RateSignal3s:
	default:
		return fmt.Errorf("rate_signal must be %s or %s (got %q)", RateSignal1s, RateSignal3s, c.RateSignal)
	}
	if c.Baseline.P50Kcyc <= 0 || c.Baseline.P90Kcyc <= 0 {
		return fmt.Errorf("baseline p50_kcyc/p90_kcyc must be > 0 (got %v/%v) -- "+
			"compute them from the stage-1 no-stressor baseline run",
			c.Baseline.P50Kcyc, c.Baseline.P90Kcyc)
	}
	if c.Baseline.Sigma50Kcyc <= 0 || c.Baseline.Sigma90Kcyc <= 0 {
		return fmt.Errorf("baseline sigma50_kcyc/sigma90_kcyc must be > 0 (got %v/%v)",
			c.Baseline.Sigma50Kcyc, c.Baseline.Sigma90Kcyc)
	}
	if c.Baseline.FreqMHz <= 0 {
		return fmt.Errorf("baseline freq_mhz must be > 0 (got %v)", c.Baseline.FreqMHz)
	}
	if !c.Ablations.NoExt && c.CurveCSV == "" {
		return fmt.Errorf("curve_csv is required unless ablations.no_ext is set")
	}
	if c.Failure.SloP90Ms < 0 {
		return fmt.Errorf("failure.slo_p90_ms must be >= 0 (got %v)", c.Failure.SloP90Ms)
	}
	if c.Failure.StallWindows < 1 {
		return fmt.Errorf("failure.stall_windows must be >= 1 (got %d)", c.Failure.StallWindows)
	}
	if c.IdleHoldWindows < 1 {
		return fmt.Errorf("idle_hold_windows must be >= 1 (got %d)", c.IdleHoldWindows)
	}
	return nil
}
