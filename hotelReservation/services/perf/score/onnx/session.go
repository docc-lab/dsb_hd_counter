package onnx

import (
	"fmt"
	"sort"
	"sync"

	ort "github.com/yalue/onnxruntime_go"
)

// Session wraps an ort.AdvancedSession plus its bound input and output
// tensors. Designed for the long-running predictor pattern: the
// expensive ORT init + session creation happens once at startup, then
// the per-window hot path is just InputBuffer() write + Run() +
// Output() read. No per-window allocation.
//
// The colleague's scenario_onnx_go.go demonstrates the same primitives
// but allocates everything per inference (it's a benchmark, not a
// service). This wrapper takes that proven pattern and lifts the
// allocations out of the hot path.
//
// Thread safety: Session is NOT safe for concurrent Run calls. The
// predictor's loop owns it and runs single-goroutine.
type Session struct {
	sess        *ort.AdvancedSession
	inputTensor *ort.Tensor[float32]
	outputs     map[string]*ort.Tensor[float32] // shortlist output key -> bound tensor
}

// envInit is a single-shot global init for the ORT environment.
// InitializeEnvironment is process-global; calling it twice is undefined
// in older versions. Multiple Session instances in one binary share the
// init via sync.Once.
var envInit struct {
	once sync.Once
	err  error
}

// initEnv configures the shared library path and runs InitializeEnvironment
// exactly once per process. libPath is read from GORDION_LIBONNXRUNTIME
// in the wireup helper; passed in here so it's testable.
func initEnv(libPath string) error {
	envInit.once.Do(func() {
		if libPath != "" {
			ort.SetSharedLibraryPath(libPath)
		}
		envInit.err = ort.InitializeEnvironment()
	})
	return envInit.err
}

// NewSession loads the ONNX model at modelPath, binds an input tensor of
// shape [1, sl.SeqLen, sl.NFeatures], and binds one output tensor per
// shortlist Outputs entry. Names come from the shortlist (input via
// ResolvedInputName, outputs via each entry's Name field).
//
// Lifecycle: callers must Close on shutdown to release ORT resources.
//
// Per the design plan (Section 6.3), this constructor runs ONCE per
// predictor lifetime; subsequent inferences just call Run.
func NewSession(modelPath string, sl *Shortlist, libPath string) (*Session, error) {
	if err := initEnv(libPath); err != nil {
		return nil, fmt.Errorf("ort init: %w", err)
	}

	// Allocate input tensor: [1, seq_len, n_features], float32.
	inputShape := ort.NewShape(int64(1), int64(sl.SeqLen), int64(sl.NFeatures))
	inputTensor, err := ort.NewEmptyTensor[float32](inputShape)
	if err != nil {
		return nil, fmt.Errorf("alloc input tensor: %w", err)
	}

	// Walk shortlist outputs in deterministic order so test expectations
	// can match (map iteration is non-deterministic in Go).
	outNames := make([]string, 0, len(sl.Outputs))
	for k := range sl.Outputs {
		outNames = append(outNames, k)
	}
	sort.Strings(outNames)

	outputs := make(map[string]*ort.Tensor[float32], len(outNames))
	outputTensorsArbitrary := make([]ort.ArbitraryTensor, 0, len(outNames))
	outputModelNames := make([]string, 0, len(outNames))

	for _, key := range outNames {
		out := sl.Outputs[key]
		shape := make([]int64, len(out.Shape))
		for i, d := range out.Shape {
			shape[i] = int64(d)
		}
		t, err := ort.NewEmptyTensor[float32](ort.NewShape(shape...))
		if err != nil {
			cleanupTensors(inputTensor, outputs)
			return nil, fmt.Errorf("alloc output %q: %w", key, err)
		}
		outputs[key] = t
		outputTensorsArbitrary = append(outputTensorsArbitrary, t)
		outputModelNames = append(outputModelNames, out.Name)
	}

	sess, err := ort.NewAdvancedSession(
		modelPath,
		[]string{sl.ResolvedInputName()},
		outputModelNames,
		[]ort.ArbitraryTensor{inputTensor},
		outputTensorsArbitrary,
		nil, // SessionOptions; default
	)
	if err != nil {
		cleanupTensors(inputTensor, outputs)
		return nil, fmt.Errorf("new advanced session %q: %w", modelPath, err)
	}

	return &Session{
		sess:        sess,
		inputTensor: inputTensor,
		outputs:     outputs,
	}, nil
}

// InputBuffer returns the input tensor's backing []float32, length
// 1 * SeqLen * NFeatures. The predictor writes feature vectors here in
// place each window before calling Run.
//
// The slice is owned by the underlying tensor; do NOT cache it past a
// Run call (semantically the data is consumed by the next Run, but the
// slice itself stays valid until Close).
func (s *Session) InputBuffer() []float32 {
	return s.inputTensor.GetData()
}

// Run runs one forward pass. Reads input tensor data, writes outputs.
// Sub-millisecond for small sequence models on CPU per the colleague's
// benchmarks; ~5-10 ms p99 worst case.
func (s *Session) Run() error {
	return s.sess.Run()
}

// Output returns the bound output tensor's backing []float32 for the
// given shortlist output key. Length matches the shortlist's declared
// shape (e.g. [1, 1] -> length 1).
//
// Returns nil if the shortlist did not declare this output. Callers
// should sanity-check with HasOutput first when handling transitional
// models that may not have all expected heads.
func (s *Session) Output(key string) []float32 {
	t, ok := s.outputs[key]
	if !ok {
		return nil
	}
	return t.GetData()
}

// HasOutput reports whether key was declared in the shortlist Outputs
// map at NewSession time. Lets the predictor handle transitional
// single-head models gracefully: the shortlist for the colleague's
// gru_model_run1.onnx would only declare p50_trend_pred, so
// HasOutput("tail_trend_label") returns false and the predictor zeros
// that field with a warning.
func (s *Session) HasOutput(key string) bool {
	_, ok := s.outputs[key]
	return ok
}

// Close releases the session and all bound tensors. Safe to call once.
func (s *Session) Close() error {
	if s.sess != nil {
		s.sess.Destroy()
		s.sess = nil
	}
	cleanupTensors(s.inputTensor, s.outputs)
	s.inputTensor = nil
	s.outputs = nil
	return nil
}

func cleanupTensors(input *ort.Tensor[float32], outputs map[string]*ort.Tensor[float32]) {
	if input != nil {
		input.Destroy()
	}
	for _, t := range outputs {
		if t != nil {
			t.Destroy()
		}
	}
}
