// Package onnx wraps the in-pod ONNX predictor used by the Gordion score
// source when prediction is enabled (GORDION_MODEL set). It is NOT a
// score.Source itself: score/gordion owns the scoring loop and calls
// Model.Push once per window to obtain the predicted next-window y50.
//
// This package owns:
//
//	runconfig.go          // trainer-emitted run config parsed at startup
//	feature_extractor.go  // gru_v3 recipe, ported from scenario_onnx_go.go
//	ring.go               // bounded sequence buffer
//	session.go            // ORT init + NewAdvancedSession + Run
//	model.go              // glue: ring + extractor + session -> Push()
//
// The deployment contract is the trainer's own: gru_train.py finishes a
// run by writing gru_config_run{N}.json with the fitted StandardScaler,
// the service vocabulary (+ its encoding discriminator), and n_features.
// The same file drives the colleague's reference client
// (scenario_onnx_go.go::loadRunConfig); this package reads the identical
// format so the trainer ships exactly two artifacts per run: the .onnx
// and its run config.
package onnx

import (
	"encoding/json"
	"fmt"
	"os"
)

// unknownService is the catch-all vocab bucket. build_service_vocab in
// gru_train.py always appends it last, so a service name unseen at
// training time maps to the final vocab index instead of failing.
const unknownService = "__unknown__"

// serviceEncodingScalarIndex is the only service encoding this binary
// implements (commit a07a375's "model fixed size"): the service name is
// a SINGLE scalar feature — its integer index in service_vocab — so the
// input width is fixed at gruV3NFeatures regardless of vocab size.
// Legacy one-hot configs (no service_encoding field) had a variable
// width (72 + len(vocab)) and are rejected with a pointed error.
const serviceEncodingScalarIndex = "scalar_index"

// gruV3NFeatures mirrors N_FEATURES_FIXED in gru_train.py: 67 log1p'd
// raw values + 1 service-index scalar + 5 derived ratios = 73. See
// feature_extractor.go for the full layout.
const gruV3NFeatures = 73

// RunConfig is the parsed trainer-emitted run config
// (gru_config_run{N}.json AFTER training; the pre-training template with
// only model/training/data keys fails Validate with a pointed error).
// Field layout mirrors scenario_onnx_go.go::RunConfig.
type RunConfig struct {
	RunID  int `json:"run_id"`
	Config struct {
		Model struct {
			SequenceLength int `json:"sequence_length"`
		} `json:"model"`
	} `json:"config"`
	NFeatures       int      `json:"n_features"`
	ServiceVocab    []string `json:"service_vocab"`
	ServiceEncoding string   `json:"service_encoding"` // must be "scalar_index"
	Scaler          struct {
		Mean  []float64 `json:"mean"`
		Scale []float64 `json:"scale"`
	} `json:"scaler"`
	Timestamp string `json:"timestamp,omitempty"`
}

// LoadRunConfig reads and validates the run config at path. Unlike the
// reference client (which panics -- it's a benchmark), this returns
// errors: a bad config disables prediction but never crashes the
// serving pod.
func LoadRunConfig(path string) (*RunConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read run config %q: %w", path, err)
	}
	var rc RunConfig
	if err := json.Unmarshal(data, &rc); err != nil {
		return nil, fmt.Errorf("parse run config %q: %w", path, err)
	}
	if err := rc.Validate(); err != nil {
		return nil, fmt.Errorf("invalid run config %q: %w", path, err)
	}
	return &rc, nil
}

// Validate sanity-checks a parsed RunConfig. Deterministic and
// self-contained: does not touch the .onnx file (session construction
// cross-checks shapes against the actual model).
func (rc *RunConfig) Validate() error {
	if rc.Config.Model.SequenceLength <= 0 || rc.NFeatures <= 0 || len(rc.ServiceVocab) == 0 {
		return fmt.Errorf("missing sequence_length / n_features / service_vocab -- " +
			"this looks like the PRE-training config template; the predictor needs " +
			"the post-training gru_config_run{N}.json written by gru_train.py")
	}
	if rc.ServiceVocab[len(rc.ServiceVocab)-1] != unknownService {
		return fmt.Errorf("service_vocab must end with %q (got %v)", unknownService, rc.ServiceVocab)
	}
	switch rc.ServiceEncoding {
	case serviceEncodingScalarIndex:
		// expected
	case "":
		return fmt.Errorf("config has no service_encoding field -- this looks like a " +
			"legacy one-hot config (pre-a07a375), which this binary does not support; " +
			"retrain with the updated gru_train.py")
	default:
		return fmt.Errorf("unsupported service_encoding %q (this binary only supports %q)",
			rc.ServiceEncoding, serviceEncodingScalarIndex)
	}
	if rc.NFeatures != gruV3NFeatures {
		return fmt.Errorf("n_features=%d does not match the fixed scalar_index recipe width %d; "+
			"if the trainer changed the feature set, the Go extractor must change in lockstep",
			rc.NFeatures, gruV3NFeatures)
	}
	if len(rc.Scaler.Mean) != rc.NFeatures || len(rc.Scaler.Scale) != rc.NFeatures {
		return fmt.Errorf("scaler mean/scale lengths (%d/%d) do not match n_features (%d)",
			len(rc.Scaler.Mean), len(rc.Scaler.Scale), rc.NFeatures)
	}
	for i, s := range rc.Scaler.Scale {
		if s == 0 {
			return fmt.Errorf("scaler.scale[%d] is 0 (sklearn emits 1.0 for zero-variance features; "+
				"a literal 0 means a corrupted config)", i)
		}
	}
	return nil
}

// Version returns a stable identifier for this trained model, stamped
// into ScoreEvent.ModelVersion when prediction is on.
func (rc *RunConfig) Version() string {
	if rc.Timestamp != "" {
		return fmt.Sprintf("gru-run%d@%s", rc.RunID, rc.Timestamp)
	}
	return fmt.Sprintf("gru-run%d", rc.RunID)
}
