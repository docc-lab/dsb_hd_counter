// hrgen is an open-loop HTTP load generator for the HotelReservation frontend
// with the same output format as the BigSvc workload generator
// (blueprint/examples/bigsvc/workload), so the per-endpoint dictionary analysis
// scripts read it unchanged.
//
// Endpoints: search (/hotels), recommend (/recommendations), reserve
// (/reservation), user (/user), with the request parameters of the stock wrk2
// script mixed-workload_type_1.lua. Arrivals are Poisson at the current rate;
// each request runs in its own goroutine, so the offered load is independent
// of the response time. Every request carries the "gordion-sent" header (unix
// ns) so the frontend's recorder can measure the admission wait.
//
// Mixes: -mix default (0.6/0.39/0.005/0.005 as wrk2), uniform, weights:a=..,b=..,
// single:NAME, file:path (JSON array in endpoint order), dirichlet (resampled
// every -resample s). -ramp-to weights:.. with -ramp-seconds S moves the mix
// linearly from the initial one to the target over S seconds, starting at
// -ramp-start s into the run (a "mix" event is written every second).
//
// Output (JSON lines, -out): run / step / mix events and one report per
// second with per-endpoint client latencies, exactly as wlgen.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"math/rand"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var Endpoints = []string{"search", "recommend", "reserve", "user"}

// -app sn: DSB SocialNetwork through nginx (wrk2 mixed-workload.lua semantics): compose = POST
// /wrk2-api/post/compose, home = GET /wrk2-api/home-timeline/read, utl = GET /wrk2-api/user-timeline/read.
var SNEndpoints = []string{"compose", "home", "utl"}

var (
	fURL        = flag.String("url", "http://localhost:5000", "frontend base URL")
	fApp        = flag.String("app", "hr", "hr (HotelReservation frontend) | sn (SocialNetwork nginx)")
	fSNUsers    = flag.Int("sn-users", 962, "SocialNetwork: max_user_index of the loaded social graph")
	fRate       = flag.Float64("rate", 100, "target arrival rate (req/s) when -schedule is empty")
	fSchedule   = flag.String("schedule", "", "rate schedule 'rate:seconds,rate:seconds,...'")
	fDuration   = flag.Float64("duration", 60, "seconds to run when -schedule is empty")
	fMix        = flag.String("mix", "default", "default | uniform | dirichlet | file:<path> | single:<name> | weights:<name=w,...>")
	fRampTo     = flag.String("ramp-to", "", "target mix (same syntax) for a linear mix ramp")
	fRampStart  = flag.Float64("ramp-start", 0, "seconds into the run when the ramp starts")
	fRampSec    = flag.Float64("ramp-seconds", 300, "ramp duration in seconds")
	fAlpha      = flag.Float64("alpha", 1.0, "Dirichlet concentration for -mix dirichlet")
	fResample   = flag.Float64("resample", 10, "seconds between mix resamples (dirichlet)")
	fSeed       = flag.Int64("seed", 1, "random seed")
	fOut        = flag.String("out", "stdout", "output file for JSON lines")
	fTimeout    = flag.Duration("timeout", 10*time.Second, "per-request timeout")
	fMaxInfl    = flag.Int("max-inflight", 20000, "drop arrivals beyond this many in flight (counted as err)")
	fWarmup     = flag.Float64("warmup", 0, "seconds of warm-up at the first rate before step 0 (reported as step -1)")
	fPoisson    = flag.Bool("poisson", true, "Poisson arrivals (false = deterministic spacing)")
	fConns      = flag.Int("conns", 4096, "max idle keep-alive connections to the frontend")
	fCostsFile  = flag.String("costs", "", "costs.json from the idle runs; its c_e are copied into the run event as cpu_ms")
	fK          = flag.Int("k", 4, "cores of the service under test (written to the run event)")
	fFixed      = flag.Bool("fixed-params", false, "HR: one request content per endpoint (dates 10->12, lat 38.0 lon -122.1, require=dis), same in every run")
)

type step struct {
	rate float64
	dur  time.Duration
}

func parseSchedule(s string) ([]step, error) {
	var out []step
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		rs := strings.SplitN(part, ":", 2)
		if len(rs) != 2 {
			return nil, fmt.Errorf("bad schedule item %q", part)
		}
		r, err := strconv.ParseFloat(rs[0], 64)
		if err != nil {
			return nil, err
		}
		d, err := strconv.ParseFloat(rs[1], 64)
		if err != nil {
			return nil, err
		}
		out = append(out, step{rate: r, dur: time.Duration(d * float64(time.Second))})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("empty schedule")
	}
	return out, nil
}

type mixer struct {
	w   []float64
	cdf []float64
}

func newMixer(w []float64) *mixer {
	sum := 0.0
	for _, v := range w {
		sum += v
	}
	m := &mixer{w: make([]float64, len(w)), cdf: make([]float64, len(w))}
	acc := 0.0
	for i, v := range w {
		m.w[i] = v / sum
		acc += m.w[i]
		m.cdf[i] = acc
	}
	m.cdf[len(w)-1] = 1.0
	return m
}

func (m *mixer) pick(r *rand.Rand) int { return sort.SearchFloat64s(m.cdf, r.Float64()) }

func gamma(r *rand.Rand, a float64) float64 {
	if a < 1 {
		return gamma(r, a+1) * math.Pow(r.Float64(), 1/a)
	}
	d := a - 1.0/3
	c := 1 / math.Sqrt(9*d)
	for {
		x := r.NormFloat64()
		v := 1 + c*x
		if v <= 0 {
			continue
		}
		v = v * v * v
		u := r.Float64()
		if u < 1-0.0331*x*x*x*x || math.Log(u) < 0.5*x*x+d*(1-v+math.Log(v)) {
			return d * v
		}
	}
}

func dirichlet(r *rand.Rand, alpha float64) []float64 {
	w := make([]float64, len(Endpoints))
	for i := range w {
		w[i] = gamma(r, alpha)
	}
	return w
}

func parseWeights(spec string, r *rand.Rand) ([]float64, bool, error) {
	idx := map[string]int{}
	for i, n := range Endpoints {
		idx[n] = i
	}
	w := make([]float64, len(Endpoints))
	switch {
	case spec == "default":
		if *fApp == "sn" {
			return []float64{0.1, 0.6, 0.3}, false, nil // wrk2 mixed-workload: 10 % compose, 60 % home, 30 % user timeline
		}
		return []float64{0.6, 0.39, 0.005, 0.005}, false, nil
	case spec == "uniform":
		for i := range w {
			w[i] = 1
		}
		return w, false, nil
	case spec == "dirichlet":
		return dirichlet(r, *fAlpha), true, nil
	case strings.HasPrefix(spec, "single:"):
		i, ok := idx[strings.TrimPrefix(spec, "single:")]
		if !ok {
			return nil, false, fmt.Errorf("unknown endpoint in %q", spec)
		}
		w[i] = 1
		return w, false, nil
	case strings.HasPrefix(spec, "weights:"):
		for _, kv := range strings.Split(strings.TrimPrefix(spec, "weights:"), ",") {
			p := strings.SplitN(kv, "=", 2)
			if len(p) != 2 {
				return nil, false, fmt.Errorf("bad weight %q", kv)
			}
			i, ok := idx[p[0]]
			if !ok {
				return nil, false, fmt.Errorf("unknown endpoint %q", p[0])
			}
			v, err := strconv.ParseFloat(p[1], 64)
			if err != nil {
				return nil, false, err
			}
			w[i] = v
		}
		return w, false, nil
	case strings.HasPrefix(spec, "file:"):
		b, err := os.ReadFile(strings.TrimPrefix(spec, "file:"))
		if err != nil {
			return nil, false, err
		}
		if err := json.Unmarshal(b, &w); err != nil {
			return nil, false, err
		}
		if len(w) != len(Endpoints) {
			return nil, false, fmt.Errorf("mix file has %d weights, want %d", len(w), len(Endpoints))
		}
		return w, false, nil
	}
	return nil, false, fmt.Errorf("unknown mix %q", spec)
}

// ---------------------------------------------------------------- requests (wrk2 script semantics)

func dateStr(d int) string { return fmt.Sprintf("2015-04-%02d", d) }

func user(r *rand.Rand) (string, string) {
	id := r.Intn(501)
	return "Cornell_" + strconv.Itoa(id), strings.Repeat(strconv.Itoa(id), 10)
}

func latlon(r *rand.Rand) (string, string) {
	lat := 38.0235 + (float64(r.Intn(482))-240.5)/1000.0
	lon := -122.095 + (float64(r.Intn(326))-157.0)/1000.0
	return strconv.FormatFloat(lat, 'f', -1, 64), strconv.FormatFloat(lon, 'f', -1, 64)
}

const alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

func randStr(r *rand.Rand, n int) string {
	b := make([]byte, n)
	for i := range b {
		b[i] = alnum[r.Intn(len(alnum))]
	}
	return string(b)
}

// buildSN mirrors wrk2/scripts/social-network/mixed-workload.lua: method, path, form body.
func buildSN(r *rand.Rand, i int) (string, string, string) {
	switch Endpoints[i] {
	case "compose":
		u := r.Intn(*fSNUsers)
		text := randStr(r, 256)
		for n := r.Intn(6); n >= 0; n-- { // 1..6 mentions (the lua loop runs n+1 times)
			text += " @username_" + strconv.Itoa(r.Intn(*fSNUsers))
		}
		for n := r.Intn(6); n >= 0; n-- { // 1..6 urls
			text += " http://" + randStr(r, 64)
		}
		var ids, types []string
		for n := r.Intn(5); n >= 0; n-- { // 1..5 media
			ids = append(ids, strconv.FormatInt(100000000000000000+r.Int63n(900000000000000000), 10))
			types = append(types, `"png"`)
		}
		body := "username=username_" + strconv.Itoa(u) + "&user_id=" + strconv.Itoa(u) + "&text=" + url.QueryEscape(text) +
			"&media_ids=" + url.QueryEscape("["+strings.Join(ids, ",")+"]") + "&media_types=" + url.QueryEscape("["+strings.Join(types, ",")+"]") + "&post_type=0"
		return "POST", "/wrk2-api/post/compose", body
	case "home":
		start := r.Intn(101)
		return "GET", "/wrk2-api/home-timeline/read?user_id=" + strconv.Itoa(r.Intn(*fSNUsers)) + "&start=" + strconv.Itoa(start) + "&stop=" + strconv.Itoa(start+10), ""
	default: // utl
		start := r.Intn(101)
		return "GET", "/wrk2-api/user-timeline/read?user_id=" + strconv.Itoa(r.Intn(*fSNUsers)) + "&start=" + strconv.Itoa(start) + "&stop=" + strconv.Itoa(start+10), ""
	}
}

func build(r *rand.Rand, i int) (string, string, string) {
	if *fApp == "sn" {
		return buildSN(r, i)
	}
	m, p := buildHR(r, i)
	return m, p, ""
}

func buildHR(r *rand.Rand, i int) (string, string) {
	if *fFixed {
		// Phase F: fixed request content (the floor must not move with the query); the other two endpoints keep
		// their random user/hotel (they are not single-endpoint SUTs)
		switch Endpoints[i] {
		case "search":
			return "GET", "/hotels?inDate=" + dateStr(10) + "&outDate=" + dateStr(12) + "&lat=38.0&lon=-122.1"
		case "recommend":
			return "GET", "/recommendations?require=dis&lat=38.0&lon=-122.1"
		}
	}
	switch Endpoints[i] {
	case "search":
		in := 9 + r.Intn(15)
		out := in + 1 + r.Intn(24-in)
		lat, lon := latlon(r)
		return "GET", "/hotels?inDate=" + dateStr(in) + "&outDate=" + dateStr(out) + "&lat=" + lat + "&lon=" + lon
	case "recommend":
		req := []string{"dis", "rate", "price"}[r.Intn(3)]
		lat, lon := latlon(r)
		return "GET", "/recommendations?require=" + req + "&lat=" + lat + "&lon=" + lon
	case "reserve":
		in := 9 + r.Intn(15)
		out := in + 1 + r.Intn(5)
		lat, lon := latlon(r)
		u, p := user(r)
		return "POST", "/reservation?inDate=" + dateStr(in) + "&outDate=" + dateStr(out) + "&lat=" + lat + "&lon=" + lon +
			"&hotelId=" + strconv.Itoa(1+r.Intn(80)) + "&customerName=" + u + "&username=" + u + "&password=" + p + "&number=1"
	default:
		u, p := user(r)
		return "POST", "/user?username=" + u + "&password=" + p
	}
}

// ---------------------------------------------------------------- stats

type perEndpoint struct {
	mu   sync.Mutex
	lat  []int64
	errs int64
}

type stats struct {
	eps  []perEndpoint
	sent int64
	done int64
	errs int64
	infl int64
}

func pct(sorted []int64, p float64) int64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	rank := p * float64(n-1)
	lo := int(rank)
	hi := lo + 1
	if hi >= n {
		return sorted[n-1]
	}
	return sorted[lo] + int64(float64(sorted[hi]-sorted[lo])*(rank-float64(lo)))
}

func report(st *stats, emit func(any), stepID, mixID int64, rate float64) {
	var all []int64
	ep := map[string][]int64{}
	for i := range st.eps {
		e := &st.eps[i]
		e.mu.Lock()
		lat, errs := e.lat, e.errs
		e.lat, e.errs = nil, 0
		e.mu.Unlock()
		if len(lat) == 0 && errs == 0 {
			continue
		}
		sort.Slice(lat, func(a, b int) bool { return lat[a] < lat[b] })
		var sum int64
		for _, v := range lat {
			sum += v
		}
		mean := int64(0)
		if len(lat) > 0 {
			mean = sum / int64(len(lat))
		}
		ep[Endpoints[i]] = []int64{int64(len(lat)), pct(lat, .5), pct(lat, .9), mean, errs}
		all = append(all, lat...)
	}
	sort.Slice(all, func(a, b int) bool { return all[a] < all[b] })
	var sum int64
	for _, v := range all {
		sum += v
	}
	mean := int64(0)
	if len(all) > 0 {
		mean = sum / int64(len(all))
	}
	emit(map[string]any{
		"t": time.Now().UnixMilli(), "step": stepID, "mix": mixID, "rate": rate,
		"sent": atomic.LoadInt64(&st.sent), "done": atomic.LoadInt64(&st.done), "err": atomic.LoadInt64(&st.errs),
		"inflight": atomic.LoadInt64(&st.infl),
		"all":      []int64{int64(len(all)), pct(all, .5), pct(all, .9), pct(all, .99), mean},
		"ep":       ep,
	})
}

func sleepUntil(t time.Time) {
	for {
		d := time.Until(t)
		if d <= 0 {
			return
		}
		if d > 150*time.Microsecond {
			time.Sleep(d - 100*time.Microsecond)
		} else {
			for time.Now().Before(t) {
			}
			return
		}
	}
}

func one(ctx context.Context, client *http.Client, st *stats, i int, method, path, body string) {
	cctx, cancel := context.WithTimeout(ctx, *fTimeout)
	defer cancel()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequestWithContext(cctx, method, *fURL+path, rd)
	if body != "" {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	t0 := time.Now()
	req.Header.Set("gordion-sent", strconv.FormatInt(t0.UnixNano(), 10))
	resp, err := client.Do(req)
	if err == nil {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
		if resp.StatusCode != 200 {
			err = fmt.Errorf("status %d", resp.StatusCode)
		}
	}
	lat := time.Since(t0).Nanoseconds()
	atomic.AddInt64(&st.infl, -1)
	atomic.AddInt64(&st.done, 1)
	e := &st.eps[i]
	e.mu.Lock()
	if err != nil {
		e.errs++
		atomic.AddInt64(&st.errs, 1)
	} else {
		e.lat = append(e.lat, lat)
	}
	e.mu.Unlock()
}

func main() {
	flag.Parse()
	if *fApp == "sn" {
		Endpoints = SNEndpoints
	}
	r := rand.New(rand.NewSource(*fSeed))
	var out *bufio.Writer
	if *fOut == "" || *fOut == "stdout" {
		out = bufio.NewWriterSize(os.Stdout, 1<<20)
	} else {
		f, err := os.OpenFile(*fOut, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		defer f.Close()
		out = bufio.NewWriterSize(f, 1<<20)
	}
	defer out.Flush()
	var emu sync.Mutex
	emit := func(v any) {
		b, _ := json.Marshal(v)
		emu.Lock()
		out.Write(b)
		out.WriteByte('\n')
		emu.Unlock()
	}

	var steps []step
	if *fSchedule != "" {
		var err error
		if steps, err = parseSchedule(*fSchedule); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	} else {
		steps = []step{{rate: *fRate, dur: time.Duration(*fDuration * float64(time.Second))}}
	}
	if *fWarmup > 0 {
		steps = append([]step{{rate: steps[0].rate, dur: time.Duration(*fWarmup * float64(time.Second))}}, steps...)
	}
	w0, resample, err := parseWeights(*fMix, r)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	mix := newMixer(w0)
	var w1 []float64
	if *fRampTo != "" {
		if w1, _, err = parseWeights(*fRampTo, r); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		w1 = newMixer(w1).w
	}
	costs := make([]float64, len(Endpoints))
	if *fCostsFile != "" {
		var c struct {
			Costs map[string]float64 `json:"costs_ms"`
		}
		b, err := os.ReadFile(*fCostsFile)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		json.Unmarshal(b, &c)
		for i, n := range Endpoints {
			costs[i] = c.Costs[n]
		}
	}
	k := len(Endpoints)
	st := &stats{eps: make([]perEndpoint, k)}
	tr := &http.Transport{MaxIdleConns: *fConns, MaxIdleConnsPerHost: *fConns, MaxConnsPerHost: 0, IdleConnTimeout: 90 * time.Second, DisableCompression: true}
	client := &http.Client{Transport: tr}

	args := map[string]any{}
	flag.VisitAll(func(f *flag.Flag) { args[f.Name] = f.Value.String() })
	kinds := make([]string, k)
	viol := make([]bool, k)
	for i := range kinds {
		kinds[i] = "http"
	}
	emit(map[string]any{"event": "run", "t": time.Now().UnixMilli(), "k": *fK, "endpoints": Endpoints,
		"floors_ms": costs, "cpu_ms": costs, "kinds": kinds, "params": make([]float64, k), "violators": viol, "args": args})
	mixID := int64(0)
	emit(map[string]any{"event": "mix", "t": time.Now().UnixMilli(), "mix": mixID, "w": mix.w})

	curStep := int64(-1)
	curRate := new(float64)
	stopRep := make(chan struct{})
	repDone := make(chan struct{})
	var curMix atomic.Int64
	go func() {
		defer close(repDone)
		tk := time.NewTicker(time.Second)
		defer tk.Stop()
		for {
			select {
			case <-stopRep:
				return
			case <-tk.C:
				report(st, emit, atomic.LoadInt64(&curStep), curMix.Load(), *curRate)
			}
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runStart := time.Now()
	var mmu sync.Mutex
	rampStart := runStart.Add(time.Duration(*fRampStart * float64(time.Second)))
	rampEnd := rampStart.Add(time.Duration(*fRampSec * float64(time.Second)))
	nextRampTick := rampStart
	firstStep := 0
	if *fWarmup > 0 {
		firstStep = -1
	}
	for si, s := range steps {
		stepID := int64(si + firstStep)
		atomic.StoreInt64(&curStep, stepID)
		*curRate = s.rate
		emit(map[string]any{"event": "step", "t": time.Now().UnixMilli(), "step": stepID, "rate": s.rate, "dur_s": s.dur.Seconds()})
		stepEnd := time.Now().Add(s.dur)
		nextResample := time.Now().Add(time.Duration(*fResample * float64(time.Second)))
		next := time.Now()
		for {
			now := time.Now()
			if now.After(stepEnd) {
				break
			}
			if resample && now.After(nextResample) {
				mmu.Lock()
				mix = newMixer(dirichlet(r, *fAlpha))
				mmu.Unlock()
				mixID++
				curMix.Store(mixID)
				emit(map[string]any{"event": "mix", "t": now.UnixMilli(), "mix": mixID, "w": mix.w})
				nextResample = now.Add(time.Duration(*fResample * float64(time.Second)))
			}
			if w1 != nil && now.After(nextRampTick) && nextRampTick.Before(rampEnd.Add(time.Second)) {
				f := math.Min(1, math.Max(0, now.Sub(rampStart).Seconds() / rampEnd.Sub(rampStart).Seconds()))
				w := make([]float64, k)
				for i := range w {
					w[i] = (1-f)*w0[i]/sum(w0) + f*w1[i]
				}
				mmu.Lock()
				mix = newMixer(w)
				mmu.Unlock()
				mixID++
				curMix.Store(mixID)
				emit(map[string]any{"event": "mix", "t": now.UnixMilli(), "mix": mixID, "w": mix.w, "ramp": f})
				nextRampTick = nextRampTick.Add(time.Second)
			}
			var gap time.Duration
			if *fPoisson {
				gap = time.Duration(r.ExpFloat64() / s.rate * float64(time.Second))
			} else {
				gap = time.Duration(float64(time.Second) / s.rate)
			}
			next = next.Add(gap)
			sleepUntil(next)
			if time.Since(next) > 2*time.Second {
				next = time.Now()
			}
			mmu.Lock()
			i := mix.pick(r)
			mmu.Unlock()
			method, path, body := build(r, i)
			atomic.AddInt64(&st.sent, 1)
			if atomic.LoadInt64(&st.infl) >= int64(*fMaxInfl) {
				atomic.AddInt64(&st.errs, 1)
				st.eps[i].mu.Lock()
				st.eps[i].errs++
				st.eps[i].mu.Unlock()
				continue
			}
			atomic.AddInt64(&st.infl, 1)
			go one(ctx, client, st, i, method, path, body)
		}
	}
	deadline := time.Now().Add(*fTimeout + time.Second)
	for atomic.LoadInt64(&st.infl) > 0 && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	close(stopRep)
	<-repDone
	report(st, emit, -2, -1, 0)
	emit(map[string]any{"event": "end", "t": time.Now().UnixMilli(),
		"sent": atomic.LoadInt64(&st.sent), "done": atomic.LoadInt64(&st.done), "err": atomic.LoadInt64(&st.errs)})
}

func sum(w []float64) float64 {
	s := 0.0
	for _, v := range w {
		s += v
	}
	return s
}
