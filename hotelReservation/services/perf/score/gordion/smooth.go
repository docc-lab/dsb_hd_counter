package gordion

import "math"

// Smoother is the causal Gaussian smoother of Algorithm 1's
// GaussianSmooth step: each Push returns the Gaussian-weighted average
// of the last w samples (the new one included), weighting recent
// history most. Causal by construction -- only past samples exist in an
// online scorer -- and renormalized over however many samples are
// available during warm-up, so the very first Push returns its input
// and the estimate tightens as history accumulates.
//
// sigma = w/3 puts the kernel's +-3sigma support exactly on the window,
// the conventional choice for a truncated Gaussian.
//
// The same type smooths the arrival-rate stream that indexes the
// intrinsic curve (unless the raw_rate_index ablation).
//
// Not safe for concurrent use; the scoring loop owns each instance.
type Smoother struct {
	weights     []float64 // weights[age], age 0 = newest
	buf         []float64 // ring of the last w inputs
	head        int       // next write slot
	n           int       // samples seen, capped at len(buf)
	passthrough bool      // no_smoothing ablation: Push returns its input
}

// NewSmoother builds a Smoother over window w. passthrough (the
// no_smoothing ablation) makes Push the identity. w < 2 also collapses
// to passthrough: a one-sample Gaussian is the identity anyway.
func NewSmoother(w int, passthrough bool) *Smoother {
	if passthrough || w < 2 {
		return &Smoother{passthrough: true}
	}
	sigma := float64(w) / 3.0
	weights := make([]float64, w)
	for age := 0; age < w; age++ {
		weights[age] = math.Exp(-float64(age*age) / (2 * sigma * sigma))
	}
	return &Smoother{
		weights: weights,
		buf:     make([]float64, w),
	}
}

// Push records x and returns the smoothed estimate over the samples
// seen so far (at most w).
func (s *Smoother) Push(x float64) float64 {
	if s.passthrough {
		return x
	}
	s.buf[s.head] = x
	s.head = (s.head + 1) % len(s.buf)
	if s.n < len(s.buf) {
		s.n++
	}

	var num, den float64
	for age := 0; age < s.n; age++ {
		// The sample with the given age sits age+1 slots behind head.
		i := s.head - 1 - age
		if i < 0 {
			i += len(s.buf)
		}
		w := s.weights[age]
		num += w * s.buf[i]
		den += w
	}
	return num / den
}
