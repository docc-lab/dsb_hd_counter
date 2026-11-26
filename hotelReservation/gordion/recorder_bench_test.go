package gordion

// K5 follow-up: the cost of one recorded request, by interceptor mode, along the path a gRPC request takes
// (transport tap -> interceptor method lookup -> Begin -> End), with the collector goroutine draining.
//
//	go test -run '^$' -bench Request -benchmem ./gordion/
//	go test -run '^$' -bench 'Request/full/parallel' -cpuprofile cpu.out ./gordion/ && go tool pprof -top gordion.test cpu.out

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/tap"
)

const benchFull = "/recommendation.Recommendation/GetRecommendations"

func benchRecorder(b *testing.B, mode int32, gate, diag bool) *Recorder {
	b.Helper()
	os.Setenv("GORDION_GATE", map[bool]string{true: "1", false: "0"}[gate])
	r, err := newRecorderOut("recommendation", []string{"GetRecommendations"}, filepath.Join(b.TempDir(), "rec.jsonl"), false)
	if err != nil {
		b.Fatal(err)
	}
	atomic.StoreInt32(&r.mode, mode)
	atomic.StoreInt32(&r.reads, 0)
	r.diag = diag
	tapMu.Lock()
	tapMap[tapKeyOf(benchFull)] = tapEntry{rec: r, m: 0}
	tapCache.Store(map[string]tapEntry{})
	r.tapped = true
	tapMu.Unlock()
	b.Cleanup(r.Stop)
	return r
}

// one request as the server sees it: the caller's stamp in the metadata, the tap, the interceptor's lookup, Begin, End
func benchOne(r *Recorder, base context.Context, idx map[string]int32, info *tap.Info) {
	ctx, _ := tapHandle(base, info)
	m, ok := idx[info.FullMethodName]
	if !ok {
		return
	}
	ctx, tok := r.Begin(ctx, int(m))
	_ = ctx
	r.End(tok, false)
}

func BenchmarkRequest(b *testing.B) {
	modes := []struct {
		name string
		mode int32
		gate bool
		diag bool
	}{
		{"off", 0, false, false}, {"count", iCount, false, false}, {"slot", iSlot, false, false}, {"count+slot", iCount | iSlot, false, false},
		{"full", iCount | iSlot | iTime, false, false}, {"full+gate", iCount | iSlot | iTime, true, false},
		{"full-diag", iCount | iSlot | iTime, false, true}, {"full-diag+gate", iCount | iSlot | iTime, true, true},
	}
	for _, md := range modes {
		for _, par := range []bool{false, true} {
			name := md.name + "/serial"
			if par {
				name = md.name + "/parallel"
			}
			b.Run(name, func(b *testing.B) {
				r := benchRecorder(b, md.mode, md.gate, md.diag)
				idx := map[string]int32{benchFull: 0} // the interceptor resolves the raw full method name (grpc.go)
				info := &tap.Info{FullMethodName: benchFull}
				base := metadata.NewIncomingContext(context.Background(),
					metadata.Pairs(sentKey, strconv.FormatInt(time.Now().UnixNano(), 10)))
				b.ReportAllocs()
				b.ResetTimer()
				if par {
					b.RunParallel(func(pb *testing.PB) {
						for pb.Next() {
							benchOne(r, base, idx, info)
						}
					})
				} else {
					for i := 0; i < b.N; i++ {
						benchOne(r, base, idx, info)
					}
				}
				b.StopTimer()
				if d := atomic.LoadInt64(&r.dropped); d > 0 {
					b.ReportMetric(float64(d)/float64(b.N), "dropped/op")
				}
			})
		}
	}
}

var _ = fmt.Sprint

// TestHist checks the production histogram's percentiles against the exact ones (bucket resolution ±4.5 %).
func TestHist(t *testing.T) {
	r := &Recorder{}
	var xs []int64
	for i := 0; i < 20000; i++ {
		v := int64(1000 + (i*7919)%400000) // 1 us .. 401 us, spread
		xs = append(xs, v)
		r.hist[histIdx(v)]++
	}
	sortI64(xs)
	n, p50, p90, p99 := r.histWindow()
	if n != uint64(len(xs)) {
		t.Fatalf("n %d", n)
	}
	for _, c := range []struct {
		got int64
		p   float64
	}{{p50, 0.5}, {p90, 0.9}, {p99, 0.99}} {
		want := xs[int(c.p*float64(len(xs)))-1]
		if d := float64(c.got-want) / float64(want); d > 0.07 || d < -0.07 {
			t.Errorf("p%.0f: got %d want %d (%.1f %%)", c.p*100, c.got, want, d*100)
		}
	}
	if n2, _, _, _ := r.histWindow(); n2 != 0 {
		t.Fatalf("second window not empty: %d", n2)
	}
}
