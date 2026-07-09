package gordion

import (
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/interceptor"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf/score"
	"github.com/rs/zerolog"
)

// ── Smoother ──────────────────────────────────────────────────────────

func TestSmootherConstantSeries(t *testing.T) {
	s := NewSmoother(10, false)
	for i := 0; i < 30; i++ {
		if got := s.Push(5.0); math.Abs(got-5.0) > 1e-12 {
			t.Fatalf("push %d: constant series must smooth to itself, got %v", i, got)
		}
	}
}

func TestSmootherFirstPushIsIdentity(t *testing.T) {
	s := NewSmoother(10, false)
	if got := s.Push(42.0); math.Abs(got-42.0) > 1e-12 {
		t.Fatalf("first push must return its input (partial-kernel renorm), got %v", got)
	}
}

func TestSmootherPassthrough(t *testing.T) {
	s := NewSmoother(10, true) // no_smoothing ablation
	for _, x := range []float64{1, 100, 3, -7} {
		if got := s.Push(x); got != x {
			t.Fatalf("passthrough must be identity: got %v want %v", got, x)
		}
	}
}

func TestSmootherHandComputedWarmup(t *testing.T) {
	// w=3 -> sigma=1, weights = [1, e^{-1/2}, e^{-2}] for ages 0,1,2.
	s := NewSmoother(3, false)
	w0, w1 := 1.0, math.Exp(-0.5)

	s.Push(10) // history: [10]
	got := s.Push(20)
	want := (w0*20 + w1*10) / (w0 + w1)
	if math.Abs(got-want) > 1e-12 {
		t.Fatalf("two-sample warmup: got %v want %v", got, want)
	}
}

func TestSmootherStepResponseIsGradual(t *testing.T) {
	s := NewSmoother(10, false)
	for i := 0; i < 20; i++ {
		s.Push(0)
	}
	first := s.Push(100)
	if first >= 100 || first <= 0 {
		t.Fatalf("step must be attenuated on arrival: got %v", first)
	}
	prev := first
	for i := 0; i < 9; i++ {
		cur := s.Push(100)
		if cur < prev {
			t.Fatalf("step response must rise monotonically: %v then %v", prev, cur)
		}
		prev = cur
	}
}

// ── Curve ─────────────────────────────────────────────────────────────

func writeCurveCSV(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "curve.csv")
	// Header mirrors curve_aggregate.py's CSV_HEADER shape (extra
	// columns present and ignored); rows deliberately unsorted.
	csv := "target_rps,arrival_rps_mean,svc_p50_norm_kcyc,svc_p90_norm_kcyc,saturated\n" +
		"1000,995,100,150,0\n" +
		"100,99,90,130,0\n" +
		"5000,4870,120,180,0\n"
	if err := os.WriteFile(path, []byte(csv), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestCurveLookup(t *testing.T) {
	c, err := LoadCurve(writeCurveCSV(t), "target_rps", "svc_p50_norm_kcyc", "svc_p90_norm_kcyc")
	if err != nil {
		t.Fatal(err)
	}

	// Clamp below and above the measured range.
	if d50, d90 := c.Lookup(10); d50 != 90 || d90 != 130 {
		t.Fatalf("below-range clamp: got (%v, %v)", d50, d90)
	}
	if d50, d90 := c.Lookup(99999); d50 != 120 || d90 != 180 {
		t.Fatalf("above-range clamp: got (%v, %v)", d50, d90)
	}
	// Exact point.
	if d50, d90 := c.Lookup(1000); d50 != 100 || d90 != 150 {
		t.Fatalf("exact point: got (%v, %v)", d50, d90)
	}
	// Midpoint interpolation between (100 -> 90/130) and (1000 -> 100/150).
	d50, d90 := c.Lookup(550)
	if math.Abs(d50-95) > 1e-9 || math.Abs(d90-140) > 1e-9 {
		t.Fatalf("interpolated point: got (%v, %v), want (95, 140)", d50, d90)
	}
}

func TestCurveMissingColumn(t *testing.T) {
	if _, err := LoadCurve(writeCurveCSV(t), "no_such_column", "svc_p50_norm_kcyc", "svc_p90_norm_kcyc"); err == nil {
		t.Fatal("missing rate column must error")
	}
}

// ── Scorer ────────────────────────────────────────────────────────────

// testConfig: baseline at 2400 MHz, p50 = 40 us -> 96 kcyc,
// p90 = 60 us -> 144 kcyc.
func testConfig() *Config {
	cfg := &Config{}
	cfg.applyDefaults()
	cfg.Baseline.P50Kcyc = 96
	cfg.Baseline.P90Kcyc = 144
	cfg.Baseline.Sigma50Kcyc = 5
	cfg.Baseline.Sigma90Kcyc = 10
	cfg.Baseline.FreqMHz = 2400
	cfg.Failure.StallWindows = 3
	return cfg
}

func testCurve(t *testing.T) *Curve {
	t.Helper()
	c, err := LoadCurve(writeCurveCSV(t), "target_rps", "svc_p50_norm_kcyc", "svc_p90_norm_kcyc")
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func baselineWindow() WindowInput {
	return WindowInput{
		P50Ns: 40_000, P90Ns: 60_000, // exactly the baseline at 2400 MHz
		ArrivalCount: 200, RequestCount: 190,
		RateRps: 1000, FreqMHz: 2400, FreqOK: true,
	}
}

func TestScorerBaselineScoresNearZero(t *testing.T) {
	sc := NewScorer(testConfig(), testCurve(t))
	var out Output
	for i := 0; i < 50; i++ {
		out = sc.Score(baselineWindow())
	}
	if !out.OK || out.Failure {
		t.Fatalf("baseline window must produce OK non-failure output: %+v", out)
	}
	if out.Y50 > 0.01 || out.Y90 > 0.01 {
		t.Fatalf("baseline input must score ~0: y50=%v y90=%v", out.Y50, out.Y90)
	}
}

func TestScorerHighContentionSaturates(t *testing.T) {
	sc := NewScorer(testConfig(), testCurve(t))
	in := baselineWindow()
	in.P50Ns, in.P90Ns = 400_000, 900_000 // 10x/15x baseline
	var out Output
	for i := 0; i < 60; i++ {
		out = sc.Score(in)
	}
	if out.Y50 < 0.99 || out.Y90 < 0.99 {
		t.Fatalf("sustained 10x latency must saturate: y50=%v y90=%v", out.Y50, out.Y90)
	}
	// The victim's own rate (1000 rps) predicts ~100/150 kcyc, but we
	// measure ~960/2160 -> the deviation is overwhelmingly extrinsic.
	if out.Ext50 < 0.8 || out.Ext90 < 0.8 {
		t.Fatalf("deviation at unchanged arrival rate must attribute extrinsic: ext50=%v ext90=%v", out.Ext50, out.Ext90)
	}
}

func TestScorerRiseAndSlowDecay(t *testing.T) {
	sc := NewScorer(testConfig(), testCurve(t))
	for i := 0; i < 40; i++ {
		sc.Score(baselineWindow())
	}
	high := baselineWindow()
	high.P50Ns, high.P90Ns = 400_000, 900_000
	var peak Output
	for i := 0; i < 40; i++ {
		peak = sc.Score(high)
	}
	if peak.Y50 < 0.99 {
		t.Fatalf("expected saturation at peak, got %v", peak.Y50)
	}
	// Back to baseline: the first post-spike window must NOT snap to 0
	// (P4 slow decay) but must decrease.
	after := sc.Score(baselineWindow())
	if after.Y50 <= 0 {
		t.Fatalf("score must decay gradually, not snap to 0: %v", after.Y50)
	}
	prev := after.Y50
	for i := 0; i < 60; i++ {
		cur := sc.Score(baselineWindow())
		if cur.Y50 > prev+1e-6 {
			t.Fatalf("decay must be monotone: %v then %v", prev, cur.Y50)
		}
		prev = cur.Y50
	}
	if prev > 0.01 {
		t.Fatalf("score must return near 0 after sustained baseline, got %v", prev)
	}
}

func TestScorerStallFailure(t *testing.T) {
	sc := NewScorer(testConfig(), testCurve(t))
	for i := 0; i < 10; i++ {
		sc.Score(baselineWindow())
	}
	stall := WindowInput{ArrivalCount: 100, RequestCount: 0, RateRps: 1000, FreqMHz: 2400, FreqOK: true}

	out := sc.Score(stall)
	if out.Failure {
		t.Fatal("a single empty window must not be a failure")
	}
	sc.Score(stall)
	out = sc.Score(stall) // 3rd consecutive = StallWindows
	if !out.Failure || out.Y50 != 1 || out.Y90 != 1 {
		t.Fatalf("3 consecutive stalls must short-circuit to y=1: %+v", out)
	}

	// Recovery resets the stall run.
	out = sc.Score(baselineWindow())
	if out.Failure {
		t.Fatalf("completion window must clear the failure: %+v", out)
	}
}

func TestScorerSloFailure(t *testing.T) {
	cfg := testConfig()
	cfg.Failure.SloP90Ms = 1.0 // 1 ms SLO
	sc := NewScorer(cfg, testCurve(t))
	in := baselineWindow()
	in.P90Ns = 5_000_000 // 5 ms
	out := sc.Score(in)
	if !out.Failure || out.Y50 != 1 || out.Y90 != 1 {
		t.Fatalf("raw p90 over SLO must short-circuit: %+v", out)
	}
}

func TestScorerHoldOnEmptyWindow(t *testing.T) {
	sc := NewScorer(testConfig(), testCurve(t))
	high := baselineWindow()
	high.P50Ns, high.P90Ns = 400_000, 900_000
	for i := 0; i < 30; i++ {
		sc.Score(high)
	}
	// Idle window (no arrivals, no completions): held latency keeps the
	// score elevated rather than dragging it to zero.
	idle := WindowInput{FreqMHz: 2400, FreqOK: true, RateRps: 1000}
	out := sc.Score(idle)
	if !out.OK || out.Failure {
		t.Fatalf("idle window after signal must still score: %+v", out)
	}
	if out.Y50 < 0.9 {
		t.Fatalf("held latency must keep the score up, got %v", out.Y50)
	}
}

func TestScorerPreSignalWindowsSkipped(t *testing.T) {
	sc := NewScorer(testConfig(), testCurve(t))
	out := sc.Score(WindowInput{FreqMHz: 2400, FreqOK: true})
	if out.OK {
		t.Fatalf("no completions ever observed -> not OK, got %+v", out)
	}
}

func TestScorerFreqFallback(t *testing.T) {
	sc := NewScorer(testConfig(), testCurve(t))
	in := baselineWindow()
	in.FreqOK = false
	in.FreqMHz = 0
	var out Output
	for i := 0; i < 40; i++ {
		out = sc.Score(in)
	}
	// With the fallback to baseline freq (2400), this is exactly the
	// baseline again -> ~0.
	if out.Y50 > 0.01 {
		t.Fatalf("freq fallback must normalize with baseline freq: y50=%v", out.Y50)
	}
}

func TestScorerDVFSInvariance(t *testing.T) {
	sc := NewScorer(testConfig(), testCurve(t))
	// Governor parked at 800 MHz: wall-clock latency 3x, same work in
	// cycles. kcyc normalization must see this as baseline.
	in := baselineWindow()
	in.FreqMHz = 800
	in.P50Ns, in.P90Ns = 120_000, 180_000 // 3x wall-clock at 1/3 clock
	var out Output
	for i := 0; i < 40; i++ {
		out = sc.Score(in)
	}
	if out.Y50 > 0.01 || out.Y90 > 0.01 {
		t.Fatalf("freq-normalized scoring must be DVFS-invariant: y50=%v y90=%v", out.Y50, out.Y90)
	}
}

func TestScorerNoExtAblation(t *testing.T) {
	cfg := testConfig()
	cfg.Ablations.NoExt = true
	sc := NewScorer(cfg, nil) // no curve needed under no_ext
	in := baselineWindow()
	in.P50Ns = 400_000
	var out Output
	for i := 0; i < 30; i++ {
		out = sc.Score(in)
	}
	if out.Ext50 != 0 || out.Ext90 != 0 {
		t.Fatalf("no_ext must publish 0 ext pcts: %+v", out)
	}
	if out.Y50 < 0.9 {
		t.Fatalf("no_ext must not affect the y scores: %v", out.Y50)
	}
}

// ── Config ────────────────────────────────────────────────────────────

func TestConfigValidation(t *testing.T) {
	good := testConfig()
	good.CurveCSV = "x.csv"
	if err := good.Validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}

	bad := testConfig()
	bad.Baseline.Sigma50Kcyc = 0
	if err := bad.Validate(); err == nil {
		t.Fatal("zero sigma must be rejected")
	}

	bad = testConfig()
	bad.LatencySection = "wall_time"
	if err := bad.Validate(); err == nil {
		t.Fatal("unknown latency_section must be rejected")
	}

	bad = testConfig()
	bad.CurveCSV = ""
	if err := bad.Validate(); err == nil {
		t.Fatal("missing curve_csv without no_ext must be rejected")
	}
	bad.Ablations.NoExt = true
	if err := bad.Validate(); err != nil {
		t.Fatalf("no_ext without curve must be accepted: %v", err)
	}
}

// ── Source (end-to-end through the Publisher) ─────────────────────────

type captureSink struct{ ch chan score.ScoreEvent }

func (c *captureSink) Emit(ev score.ScoreEvent) { c.ch <- ev }
func (c *captureSink) Close() error             { return nil }

func writeGordionConfig(t *testing.T, curvePath string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gordion.json")
	body := `{
  "version": "gordion-test",
  "k": 1.0,
  "smooth_window": 5,
  "baseline": { "p50_kcyc": 96, "p90_kcyc": 144,
                "sigma50_kcyc": 5, "sigma90_kcyc": 10, "freq_mhz": 2400 },
  "curve_csv": ` + jsonString(curvePath) + `,
  "failure": { "stall_windows": 3 }
}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func jsonString(s string) string {
	out := `"`
	for _, r := range s {
		if r == '\\' || r == '"' {
			out += `\`
		}
		out += string(r)
	}
	return out + `"`
}

func testSample(id int, p50, p90 int64) perf.Sample {
	return perf.Sample{
		SampleID:  id,
		Timestamp: time.Unix(0, int64(id)*100_000_000),
		TimingWindow: &interceptor.WindowTimingStats{
			ArrivalCount: 200,
			RequestCount: 190,
			ArrivalRps1s: 1000,
			ArrivalRps3s: 1000,
			ProcessingTime: interceptor.WindowDurationStats{
				P50Ns: p50, P90Ns: p90, Count: 190,
			},
		},
		Freq: perf.FreqSample{OK: true, ActualFreqMHz: 2400},
	}
}

func TestSourceEndToEnd(t *testing.T) {
	curvePath := writeCurveCSV(t)
	cfgPath := writeGordionConfig(t, curvePath)

	pub := score.NewPublisher()
	sink := &captureSink{ch: make(chan score.ScoreEvent, 256)}
	pub.Register(sink)

	src, err := New(SourceConfig{
		ServiceName: "search",
		ConfigPath:  cfgPath,
	}, pub, zerolog.Nop())
	if err != nil {
		t.Fatal(err)
	}
	defer src.Close()

	// Feed baseline windows, then contended ones.
	for i := 0; i < 20; i++ {
		src.Emit(testSample(i, 40_000, 60_000))
	}
	for i := 20; i < 40; i++ {
		src.Emit(testSample(i, 400_000, 900_000))
	}

	var events []score.ScoreEvent
	timeout := time.After(5 * time.Second)
	for len(events) < 40 {
		select {
		case ev := <-sink.ch:
			events = append(events, ev)
		case <-timeout:
			t.Fatalf("timed out after %d events", len(events))
		}
	}

	first, last := events[0], events[len(events)-1]
	if first.SourceKind != SourceKind || first.ModelVersion != "gordion-test" {
		t.Fatalf("bad event tagging: %+v", first)
	}
	if first.PredictionOn {
		t.Fatal("no model attached -> prediction_on must be false")
	}
	if first.P50TrendPred != first.Y50Current {
		t.Fatalf("prediction off -> p50_trend_pred must equal y50_current: %+v", first)
	}
	if first.Y50Current > 0.01 {
		t.Fatalf("baseline phase must score ~0, got %v", first.Y50Current)
	}
	if last.Y50Current < 0.9 || last.TailTrendLabel < 0.9 {
		t.Fatalf("contended phase must score high: %+v", last)
	}
	if last.ExtPct50 < 0.5 {
		t.Fatalf("contended phase at unchanged rate must attribute extrinsic: %+v", last)
	}
}
