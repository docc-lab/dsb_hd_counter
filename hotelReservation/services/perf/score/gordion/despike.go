package gordion

import "sort"

// Despiker is a causal impulse filter applied to the normalized latency
// stream BEFORE Gaussian smoothing. Motivation: the eval environment
// exhibits rare process-external stall impulses (window p50 jumping
// 200-500x the surrounding level for 1-2 windows on a ~1.1 s cadence,
// origin outside the scoring stack -- reproduced with scoring fully
// disabled). A Gaussian smoother is a mean: with smooth_window=30 every
// smoothed point absorbs 2-3 such impulses and T~ reads uniformly
// elevated, pinning the score on a healthy baseline. The despiker
// replaces any sample exceeding k x the rolling median of the RAW
// history with that median:
//
//   - impulses (duty cycle << 50%) never move a median and are fully
//     rejected, regardless of magnitude;
//   - a REAL sustained shift raises the raw-history median within
//     ~window/2 samples, after which the shifted values pass through
//     untouched -- detection of extreme (>k x) sustained contention is
//     delayed by at most ~window/2 windows (~1.5 s at defaults), and
//     moderate contention (< k x baseline) is never touched at all;
//   - the failure short-circuit (stall / SLO) bypasses this path
//     entirely, so catastrophic outages still score 1.0 immediately.
//
// Enabled by Config.DespikeK > 0; k around 8-10 sits far above real
// contention shifts (2-10x) and far below the observed impulses.
type Despiker struct {
	k    float64
	buf  []float64 // ring of RAW (pre-filter) samples
	sort []float64 // scratch for median
	idx  int
	n    int
}

// NewDespiker returns nil when k <= 0 (filter disabled).
func NewDespiker(window int, k float64) *Despiker {
	if k <= 0 || window < 1 {
		return nil
	}
	return &Despiker{
		k:    k,
		buf:  make([]float64, window),
		sort: make([]float64, 0, window),
	}
}

// Push records the raw sample and returns it, or the rolling median of
// the raw history when the sample exceeds k x that median. Filtering
// only starts once 5 samples of history exist.
func (d *Despiker) Push(v float64) float64 {
	med := d.median()
	d.buf[d.idx] = v
	d.idx = (d.idx + 1) % len(d.buf)
	if d.n < len(d.buf) {
		d.n++
	}
	if d.n <= 5 || med <= 0 || v <= d.k*med {
		return v
	}
	return med
}

func (d *Despiker) median() float64 {
	if d.n == 0 {
		return 0
	}
	d.sort = d.sort[:0]
	if d.n < len(d.buf) {
		d.sort = append(d.sort, d.buf[:d.n]...)
	} else {
		d.sort = append(d.sort, d.buf...)
	}
	sort.Float64s(d.sort)
	m := len(d.sort) / 2
	if len(d.sort)%2 == 1 {
		return d.sort[m]
	}
	return (d.sort[m-1] + d.sort[m]) / 2
}
