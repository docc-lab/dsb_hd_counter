package interceptor

import (
	"math"
	"testing"
	"time"
)

const epsilon = 1e-9

func approxEqual(a, b float64) bool {
	return math.Abs(a-b) <= epsilon
}

// TestArrivalRateSmoother_Stationary feeds N windows with a constant per-window
// count and checks the trailing rate equals count / Δt. This is the simplest
// invariant: at steady state, sliding-window RPS is unbiased.
func TestArrivalRateSmoother_Stationary(t *testing.T) {
	const window = 100 * time.Millisecond
	const horizon = 1 * time.Second
	const perWindowCount = 6

	rs := newArrivalRateSmoother(horizon, window)

	if got, want := len(rs.ring), 10; got != want {
		t.Fatalf("ring size = %d, want %d", got, want)
	}

	// Drive the smoother until the ring is full and a few extra windows beyond
	// to confirm steady state.
	var rps float64
	for i := 0; i < 30; i++ {
		rps = rs.push(perWindowCount)
	}

	expected := float64(perWindowCount) / window.Seconds() // 6 / 0.1 = 60 RPS
	if !approxEqual(rps, expected) {
		t.Fatalf("steady-state rps = %v, want %v", rps, expected)
	}
}

// TestArrivalRateSmoother_Bootstrap verifies that on a partial buffer the
// smoother divides by the elapsed time so far (option b) rather than the full
// horizon. With per-window counts of 5 and 10 fed in over 2 windows of 100 ms,
// expected rate is (5 + 10) / 0.2 = 75 RPS, NOT (5 + 10) / 1.0 = 15.
func TestArrivalRateSmoother_Bootstrap(t *testing.T) {
	const window = 100 * time.Millisecond
	const horizon = 1 * time.Second

	rs := newArrivalRateSmoother(horizon, window)

	// Tick 1: 5 arrivals -> 5 / 0.1 = 50 RPS
	rps := rs.push(5)
	if !approxEqual(rps, 50.0) {
		t.Fatalf("after 1 tick: rps = %v, want 50.0 (bootstrap divides by elapsed = 0.1 s)", rps)
	}

	// Tick 2: 10 arrivals -> total 15 over 0.2 s = 75 RPS
	rps = rs.push(10)
	if !approxEqual(rps, 75.0) {
		t.Fatalf("after 2 ticks: rps = %v, want 75.0 (bootstrap divides by elapsed = 0.2 s)", rps)
	}

	// Drive until the ring is full with constant 10 arrivals/window. Final
	// steady-state rate should be 10 / 0.1 = 100 RPS.
	var final float64
	for i := 0; i < 20; i++ {
		final = rs.push(10)
	}
	if !approxEqual(final, 100.0) {
		t.Fatalf("steady-state after fill: rps = %v, want 100.0", final)
	}
}

// TestArrivalRateSmoother_StepTransition feeds N zeros to fill the ring at 0,
// then N nines and checks that the smoothed rate ramps linearly from 0 toward
// 9 / Δt over exactly N ticks (no overshoot, no ringing). This validates the
// boxcar / SMA character of the smoother — the property the design relies on
// to avoid distorting ground truth.
func TestArrivalRateSmoother_StepTransition(t *testing.T) {
	const window = 100 * time.Millisecond
	const horizon = 1 * time.Second
	const high = 9
	rs := newArrivalRateSmoother(horizon, window)
	n := len(rs.ring) // 10

	for i := 0; i < n; i++ {
		rs.push(0)
	}

	// After N ticks of zeros the ring is full and reading 0.
	if rps := rs.push(0); !approxEqual(rps, 0.0) {
		t.Fatalf("after N zeros + 1 zero: rps = %v, want 0.0", rps)
	}

	// Now feed N highs. After k highs, the ring contains k highs and (N-k)
	// zeros, so rate should be k * high / horizon == k * 9 / 1.0.
	for k := 1; k <= n; k++ {
		rps := rs.push(high)
		want := float64(k*high) / horizon.Seconds()
		if !approxEqual(rps, want) {
			t.Fatalf("step+%d: rps = %v, want %v (linear ramp expected)", k, rps, want)
		}
	}

	// One more high evicts the oldest high; rate stays at the steady-state
	// value (no overshoot).
	rps := rs.push(high)
	want := float64(high) / window.Seconds() // 9 / 0.1 = 90
	if !approxEqual(rps, want) {
		t.Fatalf("step+N+1: rps = %v, want %v (no overshoot at steady state)", rps, want)
	}
}

// TestArrivalRateSmoother_ClampsHorizonBelowWindow verifies that when the
// requested horizon is shorter than the window interval, the smoother clamps
// to a single-window ring (effective horizon == window). Useful sanity check
// for misconfiguration; matches the WARN log behavior in the aggregator.
func TestArrivalRateSmoother_ClampsHorizonBelowWindow(t *testing.T) {
	const window = 200 * time.Millisecond
	const horizon = 100 * time.Millisecond // < window
	rs := newArrivalRateSmoother(horizon, window)

	if got, want := len(rs.ring), 1; got != want {
		t.Fatalf("ring size = %d, want %d (clamped to 1)", got, want)
	}

	// With N=1, the rate is just the latest count / window.
	if rps := rs.push(8); !approxEqual(rps, 40.0) { // 8 / 0.2
		t.Fatalf("clamped smoother: rps = %v, want 40.0", rps)
	}
	if rps := rs.push(2); !approxEqual(rps, 10.0) { // 2 / 0.2 (oldest evicted)
		t.Fatalf("clamped smoother after evict: rps = %v, want 10.0", rps)
	}
}

// TestArrivalRateSmoother_DefaultWindow verifies the constructor's
// defensive fallback when called with a non-positive window duration. The
// aggregator should never hand it a zero window in practice, but the smoother
// is a leaf utility so a sane default keeps it safe to use elsewhere.
func TestArrivalRateSmoother_DefaultWindow(t *testing.T) {
	rs := newArrivalRateSmoother(1*time.Second, 0)

	if rs.windowSecs <= 0 {
		t.Fatalf("expected windowSecs > 0 after defaulting, got %v", rs.windowSecs)
	}
	if len(rs.ring) < 1 {
		t.Fatalf("expected ring length >= 1, got %d", len(rs.ring))
	}
}
