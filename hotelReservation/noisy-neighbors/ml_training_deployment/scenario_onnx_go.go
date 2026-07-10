package main

import (
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

const unknownService = "__unknown__"

// nFeaturesFixed mirrors N_FEATURES_FIXED in gru_train.py: 67 (log1p groups
// 1-6) + 1 (service index scalar) + 5 (ratios) = 73. Kept here purely as a
// sanity check against the loaded config; the authoritative value at
// runtime is always cfg.NFeatures.
const nFeaturesFixed = 73

// ── run config (gru_config_run{N}.json / gru_config_best.json) ────────────

type RunConfig struct {
	Config struct {
		Model struct {
			SequenceLength int `json:"sequence_length"`
		} `json:"model"`
	} `json:"config"`
	NFeatures        int      `json:"n_features"`
	ServiceVocab     []string `json:"service_vocab"`
	ServiceEncoding  string   `json:"service_encoding"` // "scalar_index" (new) or "" / "one_hot" (legacy)
	Scaler           struct {
		Mean  []float64 `json:"mean"`
		Scale []float64 `json:"scale"`
	} `json:"scaler"`
}

func loadRunConfig(path string) RunConfig {
	data, err := os.ReadFile(path)
	if err != nil {
		panic(fmt.Sprintf("reading config %s: %v", path, err))
	}
	var cfg RunConfig
	if err := json.Unmarshal(data, &cfg); err != nil {
		panic(fmt.Sprintf("parsing config %s: %v", path, err))
	}
	if cfg.Config.Model.SequenceLength == 0 || cfg.NFeatures == 0 || len(cfg.ServiceVocab) == 0 {
		panic("config missing sequence_length / n_features / service_vocab")
	}
	if len(cfg.Scaler.Mean) != cfg.NFeatures || len(cfg.Scaler.Scale) != cfg.NFeatures {
		panic("scaler mean/scale length does not match n_features")
	}
	// This binary only implements the scalar-index service encoding
	// (matching the current gru_train.py). Configs produced before that
	// change used one-hot and had a variable-length feature vector
	// (72 + len(service_vocab)) — loading one of those here would silently
	// produce a mis-shaped input, so fail loudly instead.
	switch cfg.ServiceEncoding {
	case "scalar_index":
		// expected
	case "":
		panic("config has no \"service_encoding\" field — this looks like a " +
			"legacy one-hot config, which this binary does not support. " +
			"Re-train with the updated gru_train.py or use the matching " +
			"legacy inference binary.")
	default:
		panic(fmt.Sprintf("unsupported service_encoding %q — this binary only "+
			"supports \"scalar_index\"", cfg.ServiceEncoding))
	}
	if cfg.NFeatures != nFeaturesFixed {
		panic(fmt.Sprintf("config n_features=%d does not match expected fixed "+
			"count %d for scalar_index encoding — code/config mismatch",
			cfg.NFeatures, nFeaturesFixed))
	}
	return cfg
}

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

// serviceIndex returns the index of name within vocab as a float64,
// mirroring _service_index() in gru_train.py. Unknown/unseen names fall
// back to the last index (the UNKNOWN_SERVICE bucket), matching Python's
// fallback behavior exactly.
func serviceIndex(name string, vocab []string) float64 {
	idx := len(vocab) - 1 // default: unknown bucket is always last
	for i, v := range vocab {
		if v == name {
			idx = i
			break
		}
	}
	return float64(idx)
}

// ── feature extraction (mirrors extract_features in gru_train.py) ─────────
// Returns the RAW (pre-standardization) feature vector.
func extractFeaturesRaw(sample map[string]interface{}, serviceVocab []string) []float64 {
	perfC, _ := sample["perf_counters"].(map[string]interface{})
	perfD, _ := sample["perf_deltas"].(map[string]interface{})
	timing, _ := sample["timing_window"].(map[string]interface{})
	freq, _ := sample["freq"].(map[string]interface{})

	if perfC == nil {
		perfC = map[string]interface{}{}
	}
	if perfD == nil {
		perfD = map[string]interface{}{}
	}
	if timing == nil {
		timing = map[string]interface{}{}
	}
	if freq == nil {
		freq = map[string]interface{}{}
	}

	var raw []float64

	// group 1: perf_counters absolute
	for _, k := range perfCounterKeys {
		raw = append(raw, safeFloat(perfC[k]))
	}
	// group 2: perf_deltas
	for _, k := range perfCounterKeys {
		raw = append(raw, safeFloat(perfD[k]))
	}
	// group 3: arrival / rps / errors
	raw = append(raw,
		safeFloat(timing["arrival_count"]),
		safeFloat(timing["request_count"]),
		safeFloat(timing["error_count"]),
		safeFloat(timing["arrival_rps_1s"]),
		safeFloat(timing["arrival_rps_3s"]),
	)
	// group 4: timing distributions
	for _, section := range timingSections {
		sec, _ := timing[section].(map[string]interface{})
		if sec == nil {
			sec = map[string]interface{}{}
		}
		for _, k := range timingStatKeys {
			raw = append(raw, safeFloat(sec[k]))
		}
	}
	// group 5: freq keys + turbo_on
	for _, k := range freqKeys {
		raw = append(raw, safeFloat(freq[k]))
	}
	turbo := 0.0
	if v, ok := freq["turbo_on"].(bool); ok && v {
		turbo = 1.0
	}
	raw = append(raw, turbo)

	// group 6: sample offsets / window interval
	raw = append(raw,
		safeFloat(sample["offset_ms"]),
		safeFloat(sample["offset_from_workload_ms"]),
		safeFloat(sample["window_interval_ms"]),
	)

	// log1p on groups 1-6
	logRaw := make([]float64, len(raw))
	for i, v := range raw {
		logRaw[i] = math.Log1p(v)
	}

	// group 7: service_name as a single scalar index (NOT one-hot,
	// NOT log1p'd) — matches gru_train.py's _service_index()
	serviceName, _ := sample["service_name"].(string)
	if serviceName == "" {
		serviceName = unknownService
	}
	g7 := []float64{serviceIndex(serviceName, serviceVocab)}

	// group 8: derived ratios (NOT log1p'd)
	deltaCyc := safeFloat(perfD["cycles"]) + 1e-9
	deltaInst := safeFloat(perfD["instructions"]) + 1e-9
	deltaLLCM := safeFloat(perfD["LLC-load-misses"]) + 1e-9
	deltaLLCL := safeFloat(perfD["LLC-loads"]) + 1e-9
	deltaBr := safeFloat(perfD["branch-instructions"]) + 1e-9
	deltaBrM := safeFloat(perfD["branch-misses"]) + 1e-9
	deltaDTLB := safeFloat(perfD["dTLB-loads"]) + 1e-9
	deltaDTLBM := safeFloat(perfD["dTLB-load-misses"]) + 1e-9

	ipc := clip(deltaInst/deltaCyc, 0.0, 10.0)
	llcMrate := clip(deltaLLCM/deltaLLCL, 0.0, 1.0)
	brMrate := clip(deltaBrM/deltaBr, 0.0, 1.0)
	dtlbMrate := clip(deltaDTLBM/deltaDTLB, 0.0, 1.0)
	freqUtil := clip(safeFloat(freq["freq_util_pct"])/100.0, 0.0, 1.0)

	g8 := []float64{ipc, llcMrate, brMrate, dtlbMrate, freqUtil}

	out := make([]float64, 0, len(logRaw)+len(g7)+len(g8))
	out = append(out, logRaw...)
	out = append(out, g7...)
	out = append(out, g8...)
	return out
}

// standardize applies (x - mean) / scale elementwise, matching sklearn's
// StandardScaler fit on the full feature vector during training.
func standardize(raw []float64, mean, scale []float64) []float32 {
	out := make([]float32, len(raw))
	for i, v := range raw {
		out[i] = float32((v - mean[i]) / scale[i])
	}
	return out
}

// ── load JSON and build input sequence ───────────────────────────────────

func loadSequence(jsonPath string, cfg RunConfig) []float32 {
	data, err := os.ReadFile(jsonPath)
	if err != nil {
		panic(err)
	}

	var root map[string]interface{}
	if err := json.Unmarshal(data, &root); err != nil {
		panic(err)
	}

	rawSamples, ok := root["samples"].([]interface{})
	if !ok {
		panic("input json missing top-level \"samples\" array")
	}

	// file-level metadata injected into every sample, mirroring
	// GRUTrainer.load_from_file in gru_train.py
	serviceName, _ := root["service_name"].(string)
	if serviceName == "" {
		serviceName = unknownService
	}
	windowIntervalMs, hasWindowInterval := root["window_interval_ms"]

	samples := make([]map[string]interface{}, len(rawSamples))
	for i, item := range rawSamples {
		s, ok := item.(map[string]interface{})
		if !ok {
			panic(fmt.Sprintf("sample %d is not a JSON object", i))
		}
		if _, exists := s["service_name"]; !exists {
			s["service_name"] = serviceName
		}
		if hasWindowInterval {
			if _, exists := s["window_interval_ms"]; !exists {
				s["window_interval_ms"] = windowIntervalMs
			}
		}
		samples[i] = s
	}

	seqLen := cfg.Config.Model.SequenceLength
	if len(samples) < seqLen {
		panic(fmt.Sprintf("need at least %d samples, got %d", seqLen, len(samples)))
	}

	// take the last seqLen samples (predicts the p50 score for the sample
	// immediately following this window)
	start := len(samples) - seqLen
	window := samples[start:]

	flat := make([]float32, seqLen*cfg.NFeatures)
	for i, s := range window {
		raw := extractFeaturesRaw(s, cfg.ServiceVocab)
		if len(raw) != cfg.NFeatures {
			panic(fmt.Sprintf("feature vector length %d != config n_features %d — "+
				"code/config mismatch", len(raw), cfg.NFeatures))
		}
		scaled := standardize(raw, cfg.Scaler.Mean, cfg.Scaler.Scale)
		copy(flat[i*cfg.NFeatures:(i+1)*cfg.NFeatures], scaled)
	}
	return flat
}

// ── inference ─────────────────────────────────────────────────────────────

func runOnnxGo(floats []float32, seqLen, nFeatures int, modelPath, libPath string) (float32, float64) {
	ort.SetSharedLibraryPath(libPath)
	if err := ort.InitializeEnvironment(); err != nil {
		panic(err)
	}
	defer ort.DestroyEnvironment()

	inputShape := ort.NewShape(1, int64(seqLen), int64(nFeatures))
	inputTensor, err := ort.NewTensor(inputShape, floats)
	if err != nil {
		panic(err)
	}
	defer inputTensor.Destroy()

	outputShape := ort.NewShape(1)
	outputTensor, err := ort.NewEmptyTensor[float32](outputShape)
	if err != nil {
		panic(err)
	}
	defer outputTensor.Destroy()

	session, err := ort.NewAdvancedSession(modelPath,
		[]string{"input"}, []string{"p50_score"},
		[]ort.ArbitraryTensor{inputTensor},
		[]ort.ArbitraryTensor{outputTensor},
		nil)
	if err != nil {
		panic(err)
	}
	defer session.Destroy()

	t1 := time.Now()
	if err = session.Run(); err != nil {
		panic(err)
	}
	elapsed := time.Since(t1).Seconds()

	// the ONNX graph does not clip; replicate GRUTrainer.test()'s
	// np.clip(preds, 0.0, 1.0)
	result := float64(outputTensor.GetData()[0])
	result = clip(result, 0.0, 1.0)

	return float32(result), elapsed
}

// ── main ─────────────────────────────────────────────────────────────────

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr,
			"Usage: go run scenario_onnx_go.go <input.json> <gru_config_*.json> "+
				"[onnx_model_path=gru_model_best.onnx] [onnxruntime_lib_path]")
		os.Exit(1)
	}

	inputPath := os.Args[1]
	configPath := os.Args[2]

	modelPath := "gru_model_best.onnx"
	if len(os.Args) >= 4 {
		modelPath = os.Args[3]
	}

	libPath := "/users/frknsrky/onnxruntime-linux-x64-1.18.0/lib/libonnxruntime.so"
	if len(os.Args) >= 5 {
		libPath = os.Args[4]
	}

	cfg := loadRunConfig(configPath)
	floats := loadSequence(inputPath, cfg)
	result, elapsed := runOnnxGo(floats, cfg.Config.Model.SequenceLength, cfg.NFeatures, modelPath, libPath)

	fmt.Println(result)
	fmt.Printf("%.9f\n", elapsed)
}