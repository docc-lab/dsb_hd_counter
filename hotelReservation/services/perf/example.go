package main

/*
#cgo CFLAGS: -I.
#cgo LDFLAGS: -L. -lperf_api
#include "perf_api.h"
*/
import "C"

import (
	"fmt"
)

func main() {
	// Start performance counters
	if C.perf_start() != 0 {
		fmt.Println("Failed to start performance counters")
		return
	}

	// Simulated workload
	for i := 0; i < 100000000; i++ {
		_ = i * i
	}

	// Stop and collect results
	result := C.perf_stop()
	fmt.Println("Perf Results:", C.GoString(result))
}
