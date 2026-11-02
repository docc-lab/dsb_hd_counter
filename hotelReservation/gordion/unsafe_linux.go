//go:build linux

package gordion

import "unsafe"

func unsafePointer(p *uint64) unsafe.Pointer { return unsafe.Pointer(p) }
