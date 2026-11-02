//go:build !linux

package gordion

// cpuFreqMHz is only implemented on Linux; 0 means "not available".
func cpuFreqMHz() float64 { return 0 }
