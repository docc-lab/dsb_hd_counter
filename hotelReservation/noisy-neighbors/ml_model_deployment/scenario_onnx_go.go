package main

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"time"

	ort "github.com/yalue/onnxruntime_go"
)

// ── key definitions (must match gru_train.py) ─────────────────────────────

var perfCounterKeys = []string{
	"LLC-load-misses", "LLC-loads", "branch-instructions", "branch-misses",
	"cycles", "dTLB-load-misses", "dTLB-loads", "instructions",
	"page-faults", "ref-cycles",
}

var timingSections = []string{"processing_time", "total_time", "blocking_time"}

var timingStatKeys = []string{
	"min_ns", "max_ns", "mean_ns",
	"p50_ns", "p60_ns", "p70_ns", "p75_ns", "p80_ns", "p90_ns", "p99_ns",
	"count",
}

var freqKeys = []string{
	"actual_freq_mhz", "current_max_mhz", "active_n", "freq_util_pct", "tsc_freq_mhz",
}

const sequenceLength = 50

// ── helpers ───────────────────────────────────────────────────────────────

func safeFloat(v interface{}) float64 {
	if v == nil {
		return 0.0
	}
	switch val := v.(type) {
	case float64:
		return val
	case float32:
		return float64(val)
	}
	return 0.0
}

func clip(v, lo, hi float64) float64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// ── feature extraction (mirrors extract_features in gru_train.py) ─────────

func extractFeatures(sample map[string]interface{}) []float32 {
	perfC, _ := sample["perf_counters"].(map[string]interface{})
	perfD, _ := sample["perf_deltas"].(map[string]interface{})
	timing, _ := sample["timing_window"].(map[string]interface{})
	freq, _ := sample["freq"].(map[string]interface{})

	if perfC == nil { perfC = map[string]interface{}{} }
	if perfD == nil { perfD = map[string]interface{}{} }
	if timing == nil { timing = map[string]interface{}{} }
	if freq == nil { freq = map[string]interface{}{} }

	var raw []float64

	// group 1: perf_counters absolute
	for _, k := range perfCounterKeys {
		raw = append(raw, safeFloat(perfC[k]))
	}
	// group 2: perf_deltas
	for _, k := range perfCounterKeys {
		raw = append(raw, safeFloat(perfD[k]))
	}
	// group 3: arrival / rps
	raw = append(raw,
		safeFloat(timing["arrival_count"]),
		safeFloat(timing["request_count"]),
		safeFloat(timing["arrival_rps_1s"]),
		safeFloat(timing["arrival_rps_3s"]),
	)
	// group 4: timing distributions
	for _, section := range timingSections {
		sec, _ := timing[section].(map[string]interface{})
		if sec == nil { sec = map[string]interface{}{} }
		for _, k := range timingStatKeys {
			raw = append(raw, safeFloat(sec[k]))
		}
	}
	// group 5: freq keys
	for _, k := range freqKeys {
		raw = append(raw, safeFloat(freq[k]))
	}
	// turbo_on as binary
	turbo := 0.0
	if v, ok := freq["turbo_on"]; ok && v != nil {
		if b, ok := v.(bool); ok && b {
			turbo = 1.0
		}
	}
	raw = append(raw, turbo)

	// log1p on all the above (identity scaler = no scaling needed)
	logRaw := make([]float64, len(raw))
	for i, v := range raw {
		logRaw[i] = math.Log1p(v)
	}

	// group 6: derived ratios
	deltaCyc  := safeFloat(perfD["cycles"])               + 1e-9
	deltaInst := safeFloat(perfD["instructions"])          + 1e-9
	deltaLLCM := safeFloat(perfD["LLC-load-misses"])       + 1e-9
	deltaLLCL := safeFloat(perfD["LLC-loads"])             + 1e-9
	deltaBr   := safeFloat(perfD["branch-instructions"])   + 1e-9
	deltaBrM  := safeFloat(perfD["branch-misses"])         + 1e-9
	deltaDTLB := safeFloat(perfD["dTLB-loads"])            + 1e-9
	deltaDTLBM:= safeFloat(perfD["dTLB-load-misses"])      + 1e-9

	ipc       := clip(deltaInst/deltaCyc,  0.0, 10.0)
	llcMrate  := clip(deltaLLCM/deltaLLCL, 0.0, 1.0)
	brMrate   := clip(deltaBrM/deltaBr,    0.0, 1.0)
	dtlbMrate := clip(deltaDTLBM/deltaDTLB,0.0, 1.0)
	freqUtil  := clip(safeFloat(freq["freq_util_pct"])/100.0, 0.0, 1.0)

	ratios := []float64{ipc, llcMrate, brMrate, dtlbMrate, freqUtil}

	all := append(logRaw, ratios...)
	out := make([]float32, len(all))
	for i, v := range all {
		out[i] = float32(v)
	}
	return out
}

// ── load JSON and build input sequence ───────────────────────────────────

func loadSequence(jsonPath string) []float32 {
	data, err := os.ReadFile(jsonPath)
	if err != nil {
		panic(err)
	}

	var root map[string]interface{}
	if err := json.Unmarshal(data, &root); err != nil {
		panic(err)
	}

	var samples []map[string]interface{}
	if s, ok := root["samples"]; ok {
		for _, item := range s.([]interface{}) {
			samples = append(samples, item.(map[string]interface{}))
		}
	} else {
		for _, item := range root["samples"].([]interface{}) {
			samples = append(samples, item.(map[string]interface{}))
		}
	}

	// extract features for all samples
	allFeats := make([][]float32, len(samples))
	for i, s := range samples {
		allFeats[i] = extractFeatures(s)
	}

	nFeatures := len(allFeats[0])

	// take last sequenceLength samples
	start := len(allFeats) - sequenceLength
	if start < 0 {
		start = 0
	}
	seq := allFeats[start:]

	// flatten to [1, seqLen, nFeatures]
	flat := make([]float32, sequenceLength*nFeatures)
	for i, feat := range seq {
		for j, v := range feat {
			flat[i*nFeatures+j] = v
		}
	}
	return flat
}

// ── write .bin file (optional, for verification) ─────────────────────────

func writeInputBin(floats []float32, path string) {
	f, _ := os.Create(path)
	defer f.Close()
	for _, v := range floats {
		binary.Write(f, binary.LittleEndian, v)
	}
}

// ── inference ─────────────────────────────────────────────────────────────

func runOnnxGo(floats []float32) (float32, float64) {
	ort.SetSharedLibraryPath("/users/frknsrky/onnxruntime-linux-x64-1.18.0/lib/libonnxruntime.so")
	if err := ort.InitializeEnvironment(); err != nil {
		panic(err)
	}
	defer ort.DestroyEnvironment()

	inputShape := ort.NewShape(1, 50, 68)
	inputTensor, err := ort.NewTensor(inputShape, floats)
	if err != nil { panic(err) }
	defer inputTensor.Destroy()

	outputShape := ort.NewShape(1)
	outputTensor, err := ort.NewEmptyTensor[float32](outputShape)
	if err != nil { panic(err) }
	defer outputTensor.Destroy()

	session, err := ort.NewAdvancedSession("gru_model_run1.onnx",
		[]string{"input"}, []string{"p50_score"},
		[]ort.ArbitraryTensor{inputTensor},
		[]ort.ArbitraryTensor{outputTensor},
		nil)
	if err != nil { panic(err) }
	defer session.Destroy()

	t1 := time.Now()
	if err = session.Run(); err != nil { panic(err) }
	elapsed := time.Since(t1).Seconds()

	return outputTensor.GetData()[0], elapsed
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "Usage: go run scenario_onnx_go.go <input.json>")
		os.Exit(1)
	}
	floats := loadSequence(os.Args[1])
	result, elapsed := runOnnxGo(floats)
	fmt.Println(result)
	fmt.Printf("%.9f\n", elapsed)
}