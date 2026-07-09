package onnx

import (
	"fmt"
	"sync"

	ort "github.com/yalue/onnxruntime_go"
)

// Model I/O contract, fixed by the trainer's torch.onnx.export call
// (gru_train.py: input_names=['input'], output_names=['p50_score']) and
// verified against the exported graph: input "input" [batch, seq,
// n_features]; single output "p50_score" shape [batch] (bound here as
// [1], matching the reference client's ort.NewShape(1)).
const (
	inputTensorName  = "input"
	outputTensorName = "p50_score"
)

// Session wraps an ort.AdvancedSession plus its bound input and output
// tensors. Designed for the long-running predictor pattern: the
// expensive ORT init + session creation happens once at startup, then
// the per-window hot path is just InputBuffer() write + Run() +
// Output() read. No per-window allocation.
//
// Thread safety: Session is NOT safe for concurrent Run calls. The
// gordion loop goroutine owns it via Model and runs single-goroutine.
type Session struct {
	sess         *ort.AdvancedSession
	inputTensor  *ort.Tensor[float32]
	outputTensor *ort.Tensor[float32]
}

// envInit is a single-shot global init for the ORT environment.
// InitializeEnvironment is process-global; calling it twice is undefined
// in older versions. Multiple Session instances in one binary share the
// init via sync.Once. Prediction-off deployments never reach this, so
// libonnxruntime.so is not required at runtime in that mode.
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

// NewSession loads the ONNX model at modelPath and binds the input
// tensor [1, seqLen, nFeatures] and the single p50_score output [1].
//
// Lifecycle: callers must Close on shutdown to release ORT resources.
// This constructor runs ONCE per Model lifetime; subsequent inferences
// just call Run.
func NewSession(modelPath string, seqLen, nFeatures int, libPath string) (*Session, error) {
	if err := initEnv(libPath); err != nil {
		return nil, fmt.Errorf("ort init: %w", err)
	}

	inputShape := ort.NewShape(1, int64(seqLen), int64(nFeatures))
	inputTensor, err := ort.NewEmptyTensor[float32](inputShape)
	if err != nil {
		return nil, fmt.Errorf("alloc input tensor: %w", err)
	}

	outputTensor, err := ort.NewEmptyTensor[float32](ort.NewShape(1))
	if err != nil {
		inputTensor.Destroy()
		return nil, fmt.Errorf("alloc output tensor: %w", err)
	}

	sess, err := ort.NewAdvancedSession(
		modelPath,
		[]string{inputTensorName},
		[]string{outputTensorName},
		[]ort.ArbitraryTensor{inputTensor},
		[]ort.ArbitraryTensor{outputTensor},
		nil, // SessionOptions; default
	)
	if err != nil {
		inputTensor.Destroy()
		outputTensor.Destroy()
		return nil, fmt.Errorf("new advanced session %q: %w", modelPath, err)
	}

	return &Session{
		sess:         sess,
		inputTensor:  inputTensor,
		outputTensor: outputTensor,
	}, nil
}

// InputBuffer returns the input tensor's backing []float32, length
// 1 * seqLen * nFeatures. The Model writes feature vectors here in
// place each window before calling Run.
//
// The slice is owned by the underlying tensor; it stays valid until
// Close.
func (s *Session) InputBuffer() []float32 {
	return s.inputTensor.GetData()
}

// Run runs one forward pass. Reads input tensor data, writes the output.
// Sub-millisecond for small sequence models on CPU per the colleague's
// benchmarks; ~5-10 ms p99 worst case.
func (s *Session) Run() error {
	return s.sess.Run()
}

// Output returns the p50_score output tensor's backing []float32
// (length 1).
func (s *Session) Output() []float32 {
	if s.outputTensor == nil {
		return nil
	}
	return s.outputTensor.GetData()
}

// Close releases the session and both bound tensors. Safe to call once.
func (s *Session) Close() error {
	if s.sess != nil {
		s.sess.Destroy()
		s.sess = nil
	}
	if s.inputTensor != nil {
		s.inputTensor.Destroy()
		s.inputTensor = nil
	}
	if s.outputTensor != nil {
		s.outputTensor.Destroy()
		s.outputTensor = nil
	}
	return nil
}
