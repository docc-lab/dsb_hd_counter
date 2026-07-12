package perf

// Env-gated pprof server for the goroutine-wait investigation: when
// PPROF_PORT is set, every service importing this package serves
// net/http/pprof on that port with block and mutex profiling enabled.
//
// Purpose (2026-07-11): freeze events park individual request
// goroutines 10-50ms while the process schedules normally -- the wait
// therefore lives in Go-runtime wait states (channel/select/mutex) or
// syscalls. /debug/pprof/block and /debug/pprof/mutex name the former
// with stacks and cumulative durations; /debug/pprof/goroutine?debug=2
// polling covers the latter. Default off (unset PPROF_PORT): zero
// overhead, no listener.

import (
	"net/http"
	_ "net/http/pprof"
	"os"
	"runtime"

	"github.com/rs/zerolog/log"
)

func init() {
	port := os.Getenv("PPROF_PORT")
	if port == "" {
		return
	}
	// Record every blocking event and 1-in-5 mutex contention events.
	// Rate 1 is aggressive but the freeze magnitudes (10-50ms) dwarf the
	// bookkeeping cost, and this path is diagnosis-only.
	runtime.SetBlockProfileRate(1)
	runtime.SetMutexProfileFraction(5)
	go func() {
		addr := ":" + port
		log.Info().Str("addr", addr).
			Msg("pprof server listening (block+mutex profiling enabled)")
		if err := http.ListenAndServe(addr, nil); err != nil {
			log.Warn().Err(err).Msg("pprof server exited")
		}
	}()
}
