//go:build !linux

package gordion

// processCPUNs is only implemented on Linux; -1 means "not available".
func processCPUNs() int64 { return -1 }
