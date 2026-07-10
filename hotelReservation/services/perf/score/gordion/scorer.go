package gordion

import "math"

// WindowInput is one window's raw signals, extracted from a perf.Sample
// by the Source (which owns the latency-section and rate-signal
// selection).
type WindowInput struct {
	P50Ns, P90Ns float64 // section percentiles, wall-clock ns; 0 when no completions
	ArrivalCount int
	RequestCount int
	RateRps      float64 // configured rate signal (arrival_rps_1s or _3s)
	FreqMHz      float64 // measured actual frequency; used only when FreqOK
	FreqOK       bool
}

// Output is the four-tuple of Algorithm 1 for one window, plus flags.
type Output struct {
	Y50, Y90     float32 // tanh scores, [0, 1]
	Ext50, Ext90 float32 // extrinsic percentages, [0, 1] (0 under no_ext)
	Failure      bool    // failure short-circuit fired (y = 1.0)
	// OK is false only during the initial windows before ANY completion
	// has been observed (there is no latency signal to score yet and no
	// failure has fired). The Source skips publishing those windows.
	OK bool
}

// Scorer is the streaming implementation of Algorithm 1. One instance
// per pod, owned by the Source's loop goroutine; not safe for
// concurrent use.
//
// All latency math happens in the kcyc domain (see Config): the
// measured section percentiles are normalized window-by-window with the
// window's own measured frequency (T*f), matching how the stage-1
// curve and baseline stats were computed, which makes the comparison
// frequency-invariant (DVFS-proof).
type Scorer struct {
	cfg   *Config
	curve *Curve // nil iff cfg.Ablations.NoExt

	s50, s90, sRate *Smoother

	// Hold state: windows with zero completions carry the last observed
	// normalized latency forward so the smoothed estimate decays on the
	// kernel's schedule instead of collapsing toward zero. The hold is
	// BOUNDED by cfg.IdleHoldWindows: a genuinely idle service (no
	// arrivals either) stops publishing after that many windows and the
	// scorer resets, so a frozen end-of-load score never outlives the
	// load by more than the hold budget.
	lastT50, lastT90 float64
	haveLast         bool

	stallRun int // consecutive windows with arrivals but no completions
	idleRun  int // consecutive windows with no completions at all
}

// reset clears all streaming state; the next scored window starts a
// fresh smoothing warm-up.
func (sc *Scorer) reset() {
	cfg := sc.cfg
	sc.s50 = NewSmoother(cfg.SmoothWindow, cfg.Ablations.NoSmoothing)
	sc.s90 = NewSmoother(cfg.SmoothWindow, cfg.Ablations.NoSmoothing)
	sc.sRate = NewSmoother(cfg.SmoothWindow, cfg.Ablations.RawRateIndex)
	sc.lastT50, sc.lastT90 = 0, 0
	sc.haveLast = false
	sc.stallRun, sc.idleRun = 0, 0
}

// NewScorer wires a Scorer from a validated Config and its loaded curve
// (curve may be nil only when cfg.Ablations.NoExt).
func NewScorer(cfg *Config, curve *Curve) *Scorer {
	return &Scorer{
		cfg:   cfg,
		curve: curve,
		s50:   NewSmoother(cfg.SmoothWindow, cfg.Ablations.NoSmoothing),
		s90:   NewSmoother(cfg.SmoothWindow, cfg.Ablations.NoSmoothing),
		sRate: NewSmoother(cfg.SmoothWindow, cfg.Ablations.RawRateIndex),
	}
}

// Score processes one window. See Output for field semantics.
func (sc *Scorer) Score(in WindowInput) Output {
	cfg := sc.cfg

	// ── idle timeout ─────────────────────────────────────────────────
	// A stall (arrivals but no completions) is a failure signal and is
	// handled below; genuine idleness (nothing arriving) just bounds the
	// hold. After IdleHoldWindows of it, stop publishing and reset --
	// stale scores must not outlive the traffic that produced them.
	if in.RequestCount == 0 {
		sc.idleRun++
	} else {
		sc.idleRun = 0
	}
	if in.RequestCount == 0 && in.ArrivalCount == 0 && sc.idleRun > cfg.IdleHoldWindows {
		sc.reset()
		return Output{}
	}

	// ── failure short-circuit inputs ─────────────────────────────────
	// Stall: requests arriving but none completing, sustained over
	// stall_windows consecutive windows. A single empty window at low
	// rate is normal (a 100 ms window can legitimately close with an
	// in-flight request) and only triggers the hold path.
	stalled := in.ArrivalCount > 0 && in.RequestCount == 0
	if stalled {
		sc.stallRun++
	} else {
		sc.stallRun = 0
	}
	failure := sc.stallRun >= cfg.Failure.StallWindows
	// Hard SLO violation on the RAW wall-clock p90 (ms). Deliberately
	// not the kcyc domain: an SLO is a promise in wall-clock time.
	if cfg.Failure.SloP90Ms > 0 && in.RequestCount > 0 &&
		in.P90Ns/1e6 > cfg.Failure.SloP90Ms {
		failure = true
	}

	// ── frequency normalization to kcyc ──────────────────────────────
	f := cfg.Baseline.FreqMHz
	if in.FreqOK && in.FreqMHz > 0 {
		f = in.FreqMHz
	}
	var t50, t90 float64
	if in.RequestCount > 0 {
		// kcyc = (ns / 1000 us) * MHz / 1000 = ns * MHz / 1e6
		t50 = in.P50Ns * f / 1e6
		t90 = in.P90Ns * f / 1e6
		sc.lastT50, sc.lastT90 = t50, t90
		sc.haveLast = true
	} else if sc.haveLast {
		t50, t90 = sc.lastT50, sc.lastT90 // hold
	} else if !failure {
		// Nothing observed yet and no failure: no signal to score.
		return Output{}
	}

	// ── smooth + tanh scoring ────────────────────────────────────────
	t50s := sc.s50.Push(t50)
	t90s := sc.s90.Push(t90)

	y50 := scoreTanh(t50s, cfg.Baseline.P50Kcyc, cfg.Baseline.Sigma50Kcyc, cfg.K)
	y90 := scoreTanh(t90s, cfg.Baseline.P90Kcyc, cfg.Baseline.Sigma90Kcyc, cfg.K)

	// ── extrinsic decomposition ──────────────────────────────────────
	var ext50, ext90 float64
	if !cfg.Ablations.NoExt {
		lambda := sc.sRate.Push(in.RateRps)
		d50, d90 := sc.curve.Lookup(lambda)
		ext50 = extPct(t50s, d50)
		ext90 = extPct(t90s, d90)
	}

	if failure {
		// A hard failure is maximal contention regardless of what the
		// latency math said (there may be no latencies at all mid-stall).
		y50, y90 = 1.0, 1.0
	}

	return Output{
		Y50:     float32(y50),
		Y90:     float32(y90),
		Ext50:   float32(ext50),
		Ext90:   float32(ext90),
		Failure: failure,
		OK:      true,
	}
}

// scoreTanh is Algorithm 1's activation: tanh(k * (T~ - p) / sigma),
// clamped to [0, 1]. The clamp-at-0 realizes the "score becomes
// positive only when the smoothed latency exceeds the baseline
// percentile" range property; tanh itself bounds the top at 1.
func scoreTanh(tSmoothed, baseline, sigma, k float64) float64 {
	y := math.Tanh(k * (tSmoothed - baseline) / sigma)
	if y < 0 {
		return 0
	}
	return y
}

// extPct is Algorithm 1's extrinsic percentage (T~ - D(lambda)) / T~,
// clamped to [0, 1]: negative deviation (running faster than the
// intrinsic curve) means no extrinsic contention, not negative
// contention. The offline data-prep pipeline produced out-of-range
// values (max 22.1 observed); this implementation is the clamped,
// documented reference.
func extPct(tSmoothed, d float64) float64 {
	if tSmoothed <= 0 {
		return 0
	}
	e := (tSmoothed - d) / tSmoothed
	if e < 0 {
		return 0
	}
	if e > 1 {
		return 1
	}
	return e
}
