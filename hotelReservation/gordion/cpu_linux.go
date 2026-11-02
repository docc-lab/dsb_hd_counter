//go:build linux

package gordion

import "syscall"

// processCPUNs returns the process's user+system CPU time in ns (RUSAGE_SELF),
// so each window can report the CPU actually spent against the floors offered.
func processCPUNs() int64 {
	var ru syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &ru); err != nil {
		return -1
	}
	return (ru.Utime.Sec+ru.Stime.Sec)*1e9 + (ru.Utime.Usec+ru.Stime.Usec)*1e3
}
