//go:build linux

package gordion

import (
	"os"
	"strconv"
	"strings"
	"syscall"
)

// cpuFreqMHz returns the mean current frequency (MHz) of the cores in the
// process's affinity mask, read from sysfs cpufreq, or 0 when unavailable
// (no cpufreq driver, sysfs not mounted in the container). It lets the
// analysis express CPU costs and latencies at a nominal clock (Gordion's
// kcyc normalisation) instead of wall time when the governor scales the
// cores with load.
func cpuFreqMHz() float64 {
	var set [1024 / 64]uint64
	if _, _, errno := syscall.RawSyscall(syscall.SYS_SCHED_GETAFFINITY, 0, uintptr(len(set)*8), uintptr(unsafePointer(&set[0]))); errno != 0 {
		return 0
	}
	var sum, n float64
	for cpu := 0; cpu < len(set)*64; cpu++ {
		if set[cpu/64]&(1<<(uint(cpu)%64)) == 0 {
			continue
		}
		b, err := os.ReadFile("/sys/devices/system/cpu/cpu" + strconv.Itoa(cpu) + "/cpufreq/scaling_cur_freq")
		if err != nil {
			continue
		}
		if khz, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64); err == nil && khz > 0 {
			sum += khz / 1000
			n++
		}
	}
	if n == 0 {
		return procCpuinfoMHz(set[:])
	}
	return sum / n
}

// procCpuinfoMHz is the fallback when no cpufreq driver exposes the clock (e.g. the harvest
// kernel on the Ice Lake nodes, hardware P-states): the "cpu MHz" lines of /proc/cpuinfo,
// which the kernel derives from APERF/MPERF, averaged over the affinity set.
func procCpuinfoMHz(set []uint64) float64 {
	b, err := os.ReadFile("/proc/cpuinfo")
	if err != nil {
		return 0
	}
	var sum, n float64
	cpu := -1
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		switch k {
		case "processor":
			cpu, _ = strconv.Atoi(v)
		case "cpu MHz":
			if cpu < 0 || cpu >= len(set)*64 || set[cpu/64]&(1<<(uint(cpu)%64)) == 0 {
				continue
			}
			if f, err := strconv.ParseFloat(v, 64); err == nil && f > 0 {
				sum += f
				n++
			}
		}
	}
	if n == 0 {
		return 0
	}
	return sum / n
}
