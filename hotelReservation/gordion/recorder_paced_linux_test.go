package gordion

// K5 follow-up: CPU per request at a production rate (the benchmark runs flat out, so the collector goroutine never
// parks; at 3 600 req/s each completion can wake it). Requests arrive on a ticker, one goroutine each, with a fixed
// handler spin; the process CPU (getrusage) and context switches over the run are divided by the requests served.
//
//	K5_PACE=1 GOMAXPROCS=2 taskset -c 40,42 go test -run TestPaced -v ./gordion/

import (
	"context"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/tap"
)

func spin(d time.Duration) {
	t := time.Now()
	for time.Since(t) < d {
	}
}

func TestPaced(t *testing.T) {
	if os.Getenv("K5_PACE") == "" {
		t.Skip("set K5_PACE=1")
	}
	rate, _ := strconv.Atoi(os.Getenv("K5_RATE"))
	if rate <= 0 {
		rate = 3600
	}
	work := 150 * time.Microsecond
	secs := 5
	modes := []struct {
		name string
		mode int32
		gate bool
		diag bool
	}{
		{"off", 0, false, false}, {"count+slot", iCount | iSlot, false, false}, {"full-diag", iCount | iSlot | iTime, false, true},
		{"full", iCount | iSlot | iTime, false, false}, {"full+gate", iCount | iSlot | iTime, true, false}, {"off", 0, false, false},
	}
	for _, md := range modes {
		os.Setenv("GORDION_GATE", map[bool]string{true: "1", false: "0"}[md.gate])
		r, err := newRecorderOut("recommendation", []string{"GetRecommendations"}, t.TempDir()+"/rec.jsonl", false)
		if err != nil {
			t.Fatal(err)
		}
		atomic.StoreInt32(&r.mode, md.mode)
		atomic.StoreInt32(&r.reads, 0)
		r.diag = md.diag
		tapMu.Lock()
		tapMap[tapKeyOf(benchFull)] = tapEntry{rec: r, m: 0}
		tapCache.Store(map[string]tapEntry{})
		r.tapped = true
		tapMu.Unlock()
		idx := map[string]int32{benchFull: 0} // the interceptor resolves the raw full method name (grpc.go)
		info := &tap.Info{FullMethodName: benchFull}
		time.Sleep(300 * time.Millisecond)
		var ru0, ru1 syscall.Rusage
		syscall.Getrusage(syscall.RUSAGE_SELF, &ru0)
		var wg sync.WaitGroup
		var n int64
		tick := time.NewTicker(time.Second / time.Duration(rate))
		end := time.Now().Add(time.Duration(secs) * time.Second)
		for time.Now().Before(end) {
			<-tick.C
			wg.Add(1)
			go func() {
				defer wg.Done()
				base := metadata.NewIncomingContext(context.Background(), metadata.Pairs(sentKey, strconv.FormatInt(time.Now().UnixNano(), 10)))
				ctx, _ := tapHandle(base, info)
				m := idx[info.FullMethodName]
				ctx, tok := r.Begin(ctx, int(m))
				_ = ctx
				spin(work)
				r.End(tok, false)
				atomic.AddInt64(&n, 1)
			}()
		}
		tick.Stop()
		wg.Wait()
		syscall.Getrusage(syscall.RUSAGE_SELF, &ru1)
		r.Stop()
		cpu := float64((ru1.Utime.Nano()+ru1.Stime.Nano())-(ru0.Utime.Nano()+ru0.Stime.Nano())) / float64(n)
		vcs := float64(ru1.Nvcsw-ru0.Nvcsw) / float64(n)
		ivcs := float64(ru1.Nivcsw-ru0.Nivcsw) / float64(n)
		t.Logf("%-10s rate %d: %d req, CPU %.2f us/req (handler spin %.0f us), voluntary cs %.3f/req, involuntary %.3f/req",
			md.name, rate, n, cpu/1e3, float64(work)/1e3, vcs, ivcs)
	}
}
