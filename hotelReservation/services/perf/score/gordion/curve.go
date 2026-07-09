package gordion

import (
	"encoding/csv"
	"fmt"
	"os"
	"sort"
	"strconv"
)

// Curve is the stage-1 intrinsic arrival-rate -> latency lookup
// (Algorithm 1's D50/D90 dictionaries), loaded from curve_aggregate.py's
// curve.csv. Latency values are in kcyc (the svc_*_norm_kcyc columns are
// frequency-normalized at aggregation time, window by window).
//
// Lookup is piecewise-linear between measured rate points and clamped
// at both ends: below the lowest measured rate the curve's first point
// applies, above the highest the last. That matches the intent of the
// decomposition -- outside the characterized range we attribute
// deviation conservatively rather than extrapolating a fitted shape.
type Curve struct {
	pts []curvePoint // sorted by rps ascending, strictly increasing rps
}

type curvePoint struct {
	rps, d50, d90 float64
}

// LoadCurve reads the CSV at path and extracts the three configured
// columns. Extra columns are ignored (curve.csv carries ~25); rows with
// unparsable values in the selected columns are an error, not silently
// skipped -- a half-read curve would silently skew every %ext.
func LoadCurve(path, rateCol, p50Col, p90Col string) (*Curve, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open curve csv %q: %w", path, err)
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.TrimLeadingSpace = true

	header, err := r.Read()
	if err != nil {
		return nil, fmt.Errorf("read curve csv header %q: %w", path, err)
	}
	idx := map[string]int{}
	for i, name := range header {
		idx[name] = i
	}
	rateIdx, ok := idx[rateCol]
	if !ok {
		return nil, fmt.Errorf("curve csv %q has no column %q (header: %v)", path, rateCol, header)
	}
	p50Idx, ok := idx[p50Col]
	if !ok {
		return nil, fmt.Errorf("curve csv %q has no column %q (header: %v)", path, p50Col, header)
	}
	p90Idx, ok := idx[p90Col]
	if !ok {
		return nil, fmt.Errorf("curve csv %q has no column %q (header: %v)", path, p90Col, header)
	}

	var pts []curvePoint
	for row := 2; ; row++ {
		rec, err := r.Read()
		if err != nil {
			break // io.EOF or a structural error; structural errors surface as short curves below
		}
		p := curvePoint{}
		if p.rps, err = strconv.ParseFloat(rec[rateIdx], 64); err != nil {
			return nil, fmt.Errorf("curve csv %q row %d: bad %s value %q", path, row, rateCol, rec[rateIdx])
		}
		if p.d50, err = strconv.ParseFloat(rec[p50Idx], 64); err != nil {
			return nil, fmt.Errorf("curve csv %q row %d: bad %s value %q", path, row, p50Col, rec[p50Idx])
		}
		if p.d90, err = strconv.ParseFloat(rec[p90Idx], 64); err != nil {
			return nil, fmt.Errorf("curve csv %q row %d: bad %s value %q", path, row, p90Col, rec[p90Idx])
		}
		pts = append(pts, p)
	}
	if len(pts) == 0 {
		return nil, fmt.Errorf("curve csv %q has no data rows", path)
	}

	sort.Slice(pts, func(i, j int) bool { return pts[i].rps < pts[j].rps })
	// Collapse duplicate rate points (e.g. a re-run level) by keeping the
	// last occurrence; zero-width segments would break interpolation.
	dedup := pts[:1]
	for _, p := range pts[1:] {
		if p.rps == dedup[len(dedup)-1].rps {
			dedup[len(dedup)-1] = p
		} else {
			dedup = append(dedup, p)
		}
	}
	return &Curve{pts: dedup}, nil
}

// Lookup returns (D50(rps), D90(rps)) in kcyc, linearly interpolated
// between the two surrounding measured points, clamped at the ends.
func (c *Curve) Lookup(rps float64) (d50, d90 float64) {
	pts := c.pts
	if rps <= pts[0].rps {
		return pts[0].d50, pts[0].d90
	}
	last := pts[len(pts)-1]
	if rps >= last.rps {
		return last.d50, last.d90
	}
	// Binary search for the first point with pts[i].rps >= rps.
	i := sort.Search(len(pts), func(i int) bool { return pts[i].rps >= rps })
	lo, hi := pts[i-1], pts[i]
	t := (rps - lo.rps) / (hi.rps - lo.rps)
	return lo.d50 + t*(hi.d50-lo.d50), lo.d90 + t*(hi.d90-lo.d90)
}
