package interceptor

import (
	"testing"
	"time"
)

func TestCalculateWindowDurationStats(t *testing.T) {
	// Test case 1: Empty slice
	stats := calculateWindowDurationStats([]time.Duration{})
	if stats.Count != 0 {
		t.Errorf("Empty slice: expected count 0, got %d", stats.Count)
	}

	// Test case 2: Single value
	durations := []time.Duration{100 * time.Millisecond}
	stats = calculateWindowDurationStats(durations)
	if stats.Count != 1 {
		t.Errorf("Single value: expected count 1, got %d", stats.Count)
	}
	if stats.MinNs != stats.MaxNs || stats.MinNs != stats.MeanNs {
		t.Errorf("Single value: min, max, mean should be equal")
	}

	// Test case 3: Multiple values with known percentiles
	// Using values: 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 (all in ms)
	durations = []time.Duration{
		10 * time.Millisecond,
		20 * time.Millisecond,
		30 * time.Millisecond,
		40 * time.Millisecond,
		50 * time.Millisecond,
		60 * time.Millisecond,
		70 * time.Millisecond,
		80 * time.Millisecond,
		90 * time.Millisecond,
		100 * time.Millisecond,
	}

	stats = calculateWindowDurationStats(durations)

	// Check count
	if stats.Count != 10 {
		t.Errorf("Expected count 10, got %d", stats.Count)
	}

	// Check min and max
	expectedMin := int64(10 * time.Millisecond)
	expectedMax := int64(100 * time.Millisecond)
	if stats.MinNs != expectedMin {
		t.Errorf("Expected min %d ns, got %d ns", expectedMin, stats.MinNs)
	}
	if stats.MaxNs != expectedMax {
		t.Errorf("Expected max %d ns, got %d ns", expectedMax, stats.MaxNs)
	}

	// Check mean
	expectedMean := int64(55 * time.Millisecond)
	if stats.MeanNs != expectedMean {
		t.Errorf("Expected mean %d ns, got %d ns", expectedMean, stats.MeanNs)
	}

	// Check percentiles (with some tolerance for interpolation)
	tolerance := int64(5 * time.Millisecond)

	expectedP50 := int64(55 * time.Millisecond)
	if absDiff(stats.P50Ns, expectedP50) > tolerance {
		t.Errorf("Expected p50 ~%d ns, got %d ns", expectedP50, stats.P50Ns)
	}

	expectedP75 := int64(77.5 * time.Millisecond)
	if absDiff(stats.P75Ns, expectedP75) > tolerance {
		t.Errorf("Expected p75 ~%d ns, got %d ns", expectedP75, stats.P75Ns)
	}

	expectedP90 := int64(91 * time.Millisecond)
	if absDiff(stats.P90Ns, expectedP90) > tolerance {
		t.Errorf("Expected p90 ~%d ns, got %d ns", expectedP90, stats.P90Ns)
	}

	expectedP99 := int64(99.1 * time.Millisecond)
	if absDiff(stats.P99Ns, expectedP99) > tolerance {
		t.Errorf("Expected p99 ~%d ns, got %d ns", expectedP99, stats.P99Ns)
	}

	t.Logf("Stats: min=%dns, max=%dns, mean=%dns, p50=%dns, p60=%dns, p70=%dns, p75=%dns, p80=%dns, p90=%dns, p99=%dns",
		stats.MinNs, stats.MaxNs, stats.MeanNs, stats.P50Ns, stats.P60Ns, stats.P70Ns, stats.P75Ns, stats.P80Ns, stats.P90Ns, stats.P99Ns)
}

func TestCalculatePercentile(t *testing.T) {
	// Test with sorted slice
	sorted := []time.Duration{
		1 * time.Millisecond,
		2 * time.Millisecond,
		3 * time.Millisecond,
		4 * time.Millisecond,
		5 * time.Millisecond,
	}

	// P50 (median) should be 3ms
	p50 := calculatePercentile(sorted, 0.50)
	expected := 3 * time.Millisecond
	if p50 != expected {
		t.Errorf("P50: expected %v, got %v", expected, p50)
	}

	// P100 (max) should be 5ms
	p100 := calculatePercentile(sorted, 1.0)
	expected = 5 * time.Millisecond
	if p100 != expected {
		t.Errorf("P100: expected %v, got %v", expected, p100)
	}

	// P0 (min) should be 1ms
	p0 := calculatePercentile(sorted, 0.0)
	expected = 1 * time.Millisecond
	if p0 != expected {
		t.Errorf("P0: expected %v, got %v", expected, p0)
	}
}

func TestSortDurations(t *testing.T) {
	durations := []time.Duration{
		50 * time.Millisecond,
		10 * time.Millisecond,
		30 * time.Millisecond,
		20 * time.Millisecond,
		40 * time.Millisecond,
	}

	sortDurations(durations)

	// Check if sorted
	for i := 1; i < len(durations); i++ {
		if durations[i] < durations[i-1] {
			t.Errorf("Slice not sorted at index %d: %v >= %v", i, durations[i-1], durations[i])
		}
	}

	// Check expected values
	expected := []time.Duration{
		10 * time.Millisecond,
		20 * time.Millisecond,
		30 * time.Millisecond,
		40 * time.Millisecond,
		50 * time.Millisecond,
	}

	for i, exp := range expected {
		if durations[i] != exp {
			t.Errorf("Index %d: expected %v, got %v", i, exp, durations[i])
		}
	}
}

func absDiff(a, b int64) int64 {
	if a > b {
		return a - b
	}
	return b - a
}

