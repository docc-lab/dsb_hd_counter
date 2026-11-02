// Package gordion is the per-endpoint latency recorder of the Gordion
// per-endpoint dictionary work, ported from the Blueprint plugin
// (blueprint/runtime/plugins/gordion) to plain gRPC / net/http services:
// grpc.go wires it as gRPC server/client interceptors, http.go as an HTTP
// middleware for the frontend. A Recorder collects, for every endpoint (method) of one
// service, the within-service latency of each completed request and the
// number of arrivals, and emits one JSON line per fixed window (default
// 100 ms) with per-endpoint and service-level percentiles.
//
// Within-service latency = wall time from the request's arrival at the gRPC
// transport (the tap handle from TapOption stamps
// the arrival before the handler goroutine is scheduled, so run-queue wait is
// included) until the handler returns, minus the time the handler spent
// blocked on downstream calls that are themselves wrapped by the gordion
// client wrapper (PauseBegin/PauseEnd). Total, processing (= total - blocked)
// and queue (= handler start - arrival) latencies are reported. Without a
// transport tap (non-gRPC deployment) the timer starts at handler entry and
// queue is 0.
//
// Output line format (one per window, only endpoints with activity listed):
//
//	{"t":<window start, unix ms>,"svc":"big_service","w":100,"a":<arrivals>,
//	 "n":<completions>,"e":<errors>,"drop":<dropped completions>,
//	 "cpu":<process user+sys CPU ns spent in the window (linux)>,
//	 "mhz":<mean current frequency of the process's cores, sysfs cpufreq (linux, if available)>,
//	 "all":[n,p50,p90,p99,mean,max,pp50,pp90,q50,q90,x50,x90,ns,f50,f90],
//	 "ep":{"Ep000":[a,n,p50,p90,p99,mean,max,pp50,pp90,q50,q90,x50,x90,ns,f50,f90],...}}
//
// x = "pre" wait: from the caller's send stamp (gRPC metadata, see Stamp) to
// the server's first in-process timestamp; 0 if the caller sent no stamp.
// ns = number of completions whose caller sent a stamp; f = full latency of
// those completions, send stamp -> handler return minus the time blocked on
// gordion-instrumented downstream calls (= x + queue + processing), i.e. the
// per-endpoint latency Lat_e including the admission wait. Where the caller is
// not instrumented (ns = 0) only p is available and the admission wait is
// invisible to this recorder.
//
// All latencies are in nanoseconds (int). p = total latency, pp = processing
// latency, q = queue wait before the handler ran. Configuration is by
// environment variable:
//
//	GORDION_OUT        "stdout" (default) or a file path (append)
//	GORDION_WINDOW_MS  window length in ms (default 100)
//	GORDION_DISABLE    "1" disables recording (wrappers become pass-through)
//	GORDION_CLIENT_OUT file path for client-side recorders (the gordion client
//	                   wrapper's view of each callee endpoint: RTT as seen by the
//	                   caller, which includes the callee's socket queue and the
//	                   network); unset = client-side recording disabled
//	GORDION_RAW        "1" additionally emits every sample: "raw":{"Ep000":[total_ns,...],...},
//	                   "rawp":{...} (processing ns), "rawq":{...} (queue ns), "rawx":{...} (pre ns)
//	                   and "rawf":{...} (full ns, stamped requests only), for offline analysis
package gordion

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/tap"
)

type ctxKey struct{}
type arrivalKey struct{}

// arrival is stamped into the stream context by the transport tap.
type arrival struct {
	t   int64
	rec *Recorder
	m   int32
}

type tapEntry struct {
	rec *Recorder
	m   int32
}

var (
	tapMu  sync.RWMutex
	tapMap = map[string]tapEntry{} // "/ProtoService/Method" -> recorder, index
)

// TapOption is the server option that routes transport-level arrivals to the
// recorders registered through GetRecorder; pass it to grpc.NewServer.
func TapOption() grpc.ServerOption { return grpc.InTapHandle(tapHandle) }

// tapKeyOf normalises a gRPC full method name "/pkg.Service/Method" (the
// generated protos carry a package prefix) to "/Service/Method".
func tapKeyOf(full string) string {
	i := strings.LastIndexByte(full, '/')
	if i <= 0 {
		return full
	}
	svc := full[:i]
	if j := strings.LastIndexByte(svc, '.'); j >= 0 {
		svc = "/" + svc[j+1:]
	}
	return svc + full[i:]
}

// tapHandle runs on the transport's reader goroutine when a stream is opened,
// before the handler goroutine exists: it counts the arrival and stamps the
// arrival time so Begin can include the scheduling wait.
func tapHandle(ctx context.Context, info *tap.Info) (context.Context, error) {
	tapMu.RLock()
	e, ok := tapMap[tapKeyOf(info.FullMethodName)]
	tapMu.RUnlock()
	if !ok {
		return ctx, nil
	}
	atomic.AddInt64(&e.rec.arrivals[e.m], 1)
	return context.WithValue(ctx, arrivalKey{}, &arrival{t: time.Now().UnixNano(), rec: e.rec, m: e.m}), nil
}

// reqState is attached to the request context by Begin so that client-side
// wrappers (PauseBegin/PauseEnd) can account blocked time to this request.
type reqState struct {
	depth       int32 // atomic: number of outstanding downstream calls
	pauseStart  int64 // atomic: unix ns when depth went 0->1
	pausedTotal int64 // atomic: accumulated blocked ns
}

var statePool = sync.Pool{New: func() any { return &reqState{} }}

// Token identifies an in-flight request between Begin and End.
type Token struct {
	start  int64
	queue  int64
	pre    int64 // ns from the client's send stamp to start (may be negative across hosts); noPre if the caller sent none
	method int32
	st     *reqState
}

type completion struct {
	method  int32
	err     bool
	totalNs int64
	blockNs int64
	queueNs int64
	preNs   int64
}

// noPre marks a request whose caller sent no stamp. A stamped request keeps its
// pre even when negative: across hosts pre = start - sent carries the clock
// offset between caller and callee (sub-ms with NTP, either sign), which the
// idle-load baseline removes offline; dropping negative values would keep only
// the slow requests and bias the f stream.
const noPre = -1 << 62

// sentKey is the gRPC metadata key carrying the caller's send time (unix ns),
// added by Stamp in the client wrapper. On a shared clock, start - sent is the
// time the request spent in the network and in the server's kernel socket
// before user space saw it: the admission wait that no in-process timer can
// measure. Across hosts it also carries the clock offset; the idle-load
// baseline gives that offset plus the one-way network time.
const sentKey = "gordion-sent"

// Stamp adds the caller's send time to the outgoing gRPC metadata.
func Stamp(ctx context.Context) context.Context {
	return metadata.AppendToOutgoingContext(ctx, sentKey, strconv.FormatInt(time.Now().UnixNano(), 10))
}

func sentOf(ctx context.Context) int64 {
	if md, ok := metadata.FromIncomingContext(ctx); ok {
		if v := md.Get(sentKey); len(v) > 0 {
			if t, err := strconv.ParseInt(v[0], 10, 64); err == nil {
				return t
			}
		}
	}
	return 0
}

// Recorder collects timing for one service.
type Recorder struct {
	service  string
	methods  []string
	windowNs int64
	lastCPU  int64 // process CPU ns at the previous flush (0 = none yet)
	disabled bool
	raw      bool

	arrivals []int64 // atomic, per method, reset every window
	dropped  int64   // atomic
	ch       chan completion
	out      *bufio.Writer
	outFile  *os.File
	stopCh   chan struct{}
}

var (
	registryMu sync.Mutex
	registry   = map[string]*Recorder{}
)

// GetRecorder returns the process-wide recorder for serviceName, creating and
// starting it on first use. protoService is the gRPC service name used in
// "/protoService/Method" full method names (the interface's base name), used
// to route transport-level arrivals to this recorder. methods is the ordered
// list of endpoint names; method indices passed to Begin refer to this list.
func GetRecorder(serviceName string, protoService string, methods []string) (*Recorder, error) {
	registryMu.Lock()
	defer registryMu.Unlock()
	if r, ok := registry[serviceName]; ok {
		return r, nil
	}
	r, err := newRecorder(serviceName, methods)
	if err != nil {
		return nil, err
	}
	registry[serviceName] = r
	if !r.disabled {
		tapMu.Lock()
		for i, m := range methods {
			tapMap["/"+protoService+"/"+m] = tapEntry{rec: r, m: int32(i)}
		}
		tapMu.Unlock()
	}
	return r, nil
}

func newRecorder(serviceName string, methods []string) (*Recorder, error) {
	return newRecorderOut(serviceName, methods, os.Getenv("GORDION_OUT"), os.Getenv("GORDION_DISABLE") == "1")
}

func newRecorderOut(serviceName string, methods []string, dest string, disabled bool) (*Recorder, error) {
	r := &Recorder{
		service:  serviceName,
		methods:  methods,
		windowNs: int64(100 * time.Millisecond),
		arrivals: make([]int64, len(methods)),
		ch:       make(chan completion, 1<<16),
		stopCh:   make(chan struct{}),
	}
	if disabled {
		r.disabled = true
		return r, nil
	}
	r.raw = os.Getenv("GORDION_RAW") == "1"
	if v := os.Getenv("GORDION_WINDOW_MS"); v != "" {
		ms, err := strconv.Atoi(v)
		if err != nil || ms <= 0 {
			return nil, fmt.Errorf("gordion: bad GORDION_WINDOW_MS %q", v)
		}
		r.windowNs = int64(ms) * int64(time.Millisecond)
	}
	if dest == "" || dest == "stdout" {
		r.out = bufio.NewWriterSize(os.Stdout, 1<<20)
	} else {
		f, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
		if err != nil {
			return nil, fmt.Errorf("gordion: open GORDION_OUT %q: %w", dest, err)
		}
		r.outFile = f
		r.out = bufio.NewWriterSize(f, 1<<20)
	}
	r.writeStart()
	go r.loop()
	return r, nil
}

func (r *Recorder) writeStart() {
	var sb strings.Builder
	sb.WriteString(`{"event":"start","t":`)
	sb.WriteString(strconv.FormatInt(time.Now().UnixMilli(), 10))
	sb.WriteString(`,"svc":"`)
	sb.WriteString(r.service)
	sb.WriteString(`","w":`)
	sb.WriteString(strconv.FormatInt(r.windowNs/int64(time.Millisecond), 10))
	sb.WriteString(`,"pid":`)
	sb.WriteString(strconv.Itoa(os.Getpid()))
	sb.WriteString(`,"methods":[`)
	for i, m := range r.methods {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteByte('"')
		sb.WriteString(m)
		sb.WriteByte('"')
	}
	sb.WriteString("]}\n")
	r.out.WriteString(sb.String())
	r.out.Flush()
}

// GetClientRecorder returns the recorder used by the gordion client wrapper
// for calls to calleeService. It is disabled unless GORDION_CLIENT_OUT is set.
// Its windows have the same format as server recorders, with "svc" =
// calleeService + "@client"; latencies are caller-observed RTTs.
func GetClientRecorder(calleeService string, methods []string) (*Recorder, error) {
	registryMu.Lock()
	defer registryMu.Unlock()
	name := calleeService + "@client"
	if r, ok := registry[name]; ok {
		return r, nil
	}
	dest := os.Getenv("GORDION_CLIENT_OUT")
	r, err := newRecorderOut(name, methods, dest, dest == "" || os.Getenv("GORDION_DISABLE") == "1")
	if err != nil {
		return nil, err
	}
	registry[name] = r
	return r, nil
}

// BeginCall starts the timer for an outgoing call of method m (client side).
// It counts the call as an arrival and does not touch the context.
func (r *Recorder) BeginCall(m int) Token {
	if r.disabled {
		return Token{method: -1}
	}
	atomic.AddInt64(&r.arrivals[m], 1)
	return Token{start: time.Now().UnixNano(), method: int32(m)}
}

// EndCall records the completion of a call started with BeginCall.
func (r *Recorder) EndCall(tok Token, isErr bool) {
	if tok.method < 0 {
		return
	}
	total := time.Now().UnixNano() - tok.start
	select {
	case r.ch <- completion{method: tok.method, err: isErr, totalNs: total, preNs: noPre}:
	default:
		atomic.AddInt64(&r.dropped, 1)
	}
}

// Begin starts the timer for a request of method m (or, if the transport tap
// stamped an arrival, continues it from the arrival and records the queue
// wait). The returned context carries the request state used by
// PauseBegin/PauseEnd.
func (r *Recorder) Begin(ctx context.Context, m int) (context.Context, Token) {
	if r.disabled {
		return ctx, Token{method: -1}
	}
	now := time.Now().UnixNano()
	start, queue := now, int64(0)
	if a, ok := ctx.Value(arrivalKey{}).(*arrival); ok && a.rec == r && int(a.m) == m {
		start = a.t
		queue = now - a.t
	} else {
		atomic.AddInt64(&r.arrivals[m], 1)
	}
	st := statePool.Get().(*reqState)
	atomic.StoreInt32(&st.depth, 0)
	atomic.StoreInt64(&st.pauseStart, 0)
	atomic.StoreInt64(&st.pausedTotal, 0)
	ctx = context.WithValue(ctx, ctxKey{}, st)
	pre := int64(noPre)
	if sent := sentOf(ctx); sent > 0 {
		pre = start - sent
	}
	return ctx, Token{start: start, queue: queue, pre: pre, method: int32(m), st: st}
}

// End stops the timer and enqueues the completion. Never blocks; if the
// aggregator falls behind the completion is counted as dropped.
func (r *Recorder) End(tok Token, isErr bool) {
	if tok.method < 0 {
		return
	}
	total := time.Now().UnixNano() - tok.start
	blocked := atomic.LoadInt64(&tok.st.pausedTotal)
	statePool.Put(tok.st)
	select {
	case r.ch <- completion{method: tok.method, err: isErr, totalNs: total, blockNs: blocked, queueNs: tok.queue, preNs: tok.pre}:
	default:
		atomic.AddInt64(&r.dropped, 1)
	}
}

// PauseBegin marks the start of a downstream call made on behalf of the
// request in ctx. Returns false if ctx carries no gordion request state.
func PauseBegin(ctx context.Context) bool {
	st, ok := ctx.Value(ctxKey{}).(*reqState)
	if !ok {
		return false
	}
	if atomic.AddInt32(&st.depth, 1) == 1 {
		atomic.StoreInt64(&st.pauseStart, time.Now().UnixNano())
	}
	return true
}

// PauseEnd marks the end of a downstream call started with PauseBegin.
func PauseEnd(ctx context.Context) {
	st, ok := ctx.Value(ctxKey{}).(*reqState)
	if !ok {
		return
	}
	if atomic.AddInt32(&st.depth, -1) == 0 {
		ps := atomic.LoadInt64(&st.pauseStart)
		if ps > 0 {
			atomic.AddInt64(&st.pausedTotal, time.Now().UnixNano()-ps)
			atomic.StoreInt64(&st.pauseStart, 0)
		}
	}
}

type bucket struct {
	total []int64
	proc  []int64
	queue []int64
	pre   []int64 // only requests whose caller sent a stamp
	full  []int64 // pre + total - blocked, same requests as pre: Lat_e incl. the admission wait
	errs  int
}

func (r *Recorder) add(buckets []bucket, c completion) {
	b := &buckets[c.method]
	b.total = append(b.total, c.totalNs)
	b.proc = append(b.proc, c.totalNs-c.blockNs)
	b.queue = append(b.queue, c.queueNs)
	if c.preNs != noPre {
		b.pre = append(b.pre, c.preNs)
		b.full = append(b.full, c.preNs+c.totalNs-c.blockNs)
	}
	if c.err {
		b.errs++
	}
}

func (r *Recorder) loop() {
	k := len(r.methods)
	buckets := make([]bucket, k)
	ticker := time.NewTicker(time.Duration(r.windowNs))
	defer ticker.Stop()
	winStart := time.Now()
	for {
		select {
		case c := <-r.ch:
			r.add(buckets, c)
		case <-ticker.C:
			// drain whatever is already queued so the window is as complete as possible
		drain:
			for {
				select {
				case c := <-r.ch:
					r.add(buckets, c)
				default:
					break drain
				}
			}
			r.flush(winStart, buckets)
			winStart = time.Now()
			for i := range buckets {
				buckets[i].total = buckets[i].total[:0]
				buckets[i].proc = buckets[i].proc[:0]
				buckets[i].queue = buckets[i].queue[:0]
				buckets[i].pre = buckets[i].pre[:0]
				buckets[i].full = buckets[i].full[:0]
				buckets[i].errs = 0
			}
		case <-r.stopCh:
			return
		}
	}
}

func pct(sorted []int64, p float64) int64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	if n == 1 {
		return sorted[0]
	}
	rank := p * float64(n-1)
	lo := int(rank)
	hi := lo + 1
	if hi >= n {
		return sorted[n-1]
	}
	frac := rank - float64(lo)
	return sorted[lo] + int64(float64(sorted[hi]-sorted[lo])*frac)
}

func sortI64(s []int64) {
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
}

// writeStats appends n,p50,p90,p99,mean,max,pp50,pp90,q50,q90,x50,x90,ns,f50,f90
// (no brackets); x = pre-arrival wait from the caller's stamp (0 when none
// sent), ns = stamped completions, f = full latency (pre + total) of those.
func writeStats(sb *strings.Builder, total, proc, queue, pre, full []int64) {
	sortI64(total)
	sortI64(proc)
	sortI64(queue)
	sortI64(pre)
	sortI64(full)
	var sum int64
	for _, v := range total {
		sum += v
	}
	n := int64(len(total))
	mean := int64(0)
	mx := int64(0)
	if n > 0 {
		mean = sum / n
		mx = total[n-1]
	}
	sb.WriteString(strconv.FormatInt(n, 10))
	for _, v := range []int64{pct(total, .5), pct(total, .9), pct(total, .99), mean, mx, pct(proc, .5), pct(proc, .9), pct(queue, .5), pct(queue, .9), pct(pre, .5), pct(pre, .9), int64(len(full)), pct(full, .5), pct(full, .9)} {
		sb.WriteByte(',')
		sb.WriteString(strconv.FormatInt(v, 10))
	}
}

// writeRaw appends `],"raw":{"Ep":[..],..}` (closing the preceding array) and
// reopens an array so the caller's `],"ep":{` continues to parse.
func writeRaw(sb *strings.Builder, key string, methods []string, buckets []bucket, which int) {
	sb.WriteString(`],`)
	sb.WriteString(key)
	sb.WriteString(`:{`)
	first := true
	for i := range buckets {
		vals := buckets[i].total
		switch which {
		case 1:
			vals = buckets[i].proc
		case 2:
			vals = buckets[i].queue
		case 3:
			vals = buckets[i].pre
		case 4:
			vals = buckets[i].full
		}
		if len(vals) == 0 {
			continue
		}
		if !first {
			sb.WriteByte(',')
		}
		first = false
		sb.WriteByte('"')
		sb.WriteString(methods[i])
		sb.WriteString(`":[`)
		for j, v := range vals {
			if j > 0 {
				sb.WriteByte(',')
			}
			sb.WriteString(strconv.FormatInt(v, 10))
		}
		sb.WriteByte(']')
	}
	sb.WriteString(`},"_":[0`)
}

func (r *Recorder) flush(winStart time.Time, buckets []bucket) {
	var allTotal, allProc, allQueue, allPre, allFull []int64
	var arrivals, errs int64
	for i := range buckets {
		allTotal = append(allTotal, buckets[i].total...)
		allProc = append(allProc, buckets[i].proc...)
		allQueue = append(allQueue, buckets[i].queue...)
		allPre = append(allPre, buckets[i].pre...)
		allFull = append(allFull, buckets[i].full...)
		errs += int64(buckets[i].errs)
	}
	arr := make([]int64, len(buckets))
	for i := range arr {
		arr[i] = atomic.SwapInt64(&r.arrivals[i], 0)
		arrivals += arr[i]
	}
	dropped := atomic.SwapInt64(&r.dropped, 0)
	if arrivals == 0 && len(allTotal) == 0 && dropped == 0 {
		// idle window: emit a heartbeat roughly once per second only
		if (winStart.UnixNano()/r.windowNs)%(int64(time.Second)/r.windowNs) != 0 {
			return
		}
	}

	var sb strings.Builder
	sb.Grow(256 + 96*len(buckets))
	sb.WriteString(`{"t":`)
	sb.WriteString(strconv.FormatInt(winStart.UnixMilli(), 10))
	sb.WriteString(`,"svc":"`)
	sb.WriteString(r.service)
	sb.WriteString(`","w":`)
	sb.WriteString(strconv.FormatInt(r.windowNs/int64(time.Millisecond), 10))
	sb.WriteString(`,"a":`)
	sb.WriteString(strconv.FormatInt(arrivals, 10))
	sb.WriteString(`,"n":`)
	sb.WriteString(strconv.Itoa(len(allTotal)))
	sb.WriteString(`,"e":`)
	sb.WriteString(strconv.FormatInt(errs, 10))
	sb.WriteString(`,"drop":`)
	sb.WriteString(strconv.FormatInt(dropped, 10))
	if cpu := processCPUNs(); cpu >= 0 {
		// process CPU time (user+sys, ns) consumed during this window
		if r.lastCPU > 0 {
			sb.WriteString(`,"cpu":`)
			sb.WriteString(strconv.FormatInt(cpu-r.lastCPU, 10))
		}
		r.lastCPU = cpu
	}
	if mhz := cpuFreqMHz(); mhz > 0 {
		// mean current frequency of the process's cores at the end of the window (sysfs cpufreq)
		sb.WriteString(`,"mhz":`)
		sb.WriteString(strconv.FormatInt(int64(mhz), 10))
	}
	sb.WriteString(`,"all":[`)
	writeStats(&sb, allTotal, allProc, allQueue, allPre, allFull)
	if r.raw {
		// unsorted per-endpoint samples (writeStats sorts in place afterwards)
		writeRaw(&sb, `"raw"`, r.methods, buckets, 0)
		writeRaw(&sb, `"rawp"`, r.methods, buckets, 1)
		writeRaw(&sb, `"rawq"`, r.methods, buckets, 2)
		writeRaw(&sb, `"rawx"`, r.methods, buckets, 3)
		writeRaw(&sb, `"rawf"`, r.methods, buckets, 4)
	}
	sb.WriteString(`],"ep":{`)
	first := true
	for i := range buckets {
		if arr[i] == 0 && len(buckets[i].total) == 0 {
			continue
		}
		if !first {
			sb.WriteByte(',')
		}
		first = false
		sb.WriteByte('"')
		sb.WriteString(r.methods[i])
		sb.WriteString(`":[`)
		sb.WriteString(strconv.FormatInt(arr[i], 10))
		sb.WriteByte(',')
		writeStats(&sb, buckets[i].total, buckets[i].proc, buckets[i].queue, buckets[i].pre, buckets[i].full)
		sb.WriteByte(']')
	}
	sb.WriteString("}}\n")
	r.out.WriteString(sb.String())
	r.out.Flush()
}

// Stop halts the flush loop and closes the output file (if any).
func (r *Recorder) Stop() {
	close(r.stopCh)
	if r.out != nil {
		r.out.Flush()
	}
	if r.outFile != nil {
		r.outFile.Close()
	}
}
