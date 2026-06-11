// Package onnx implements an ONNX-Runtime-based score.Source. It is one
// concrete implementation of the score.Source interface; future
// formula-based or rule-based sources implement the same interface and
// are selected at startup via GORDION_SCORE_SOURCE.
//
// This package owns:
//
//	feature_extractor.go  // ported from colleague's scenario_onnx_go.go
//	shortlist.go          // metadata-only JSON parsed at startup
//	ring.go               // bounded sequence buffer
//	session.go            // ORT init + NewAdvancedSession + Run (M6)
//	predictor.go          // glue: implements score.Source (M7)
//
// Per the design plan (Section 4.3), the feature extractor is bespoke
// Go code paired with the trained model. The shortlist file is metadata
// only -- it does not declare individual features by dotted path,
// because the real recipe involves log1p, derived ratios, and bool
// encoding that don't fit a declarative form. The shortlist's role is
// to (a) name which feature_extractor function to use, (b) declare the
// expected input/output tensor shapes for sanity checks, and (c) carry
// a schema_version that flows through to ScoreEvent.ModelVersion.
package onnx

import (
	"encoding/json"
	"fmt"
	"os"
)

// Shortlist is the parsed metadata-only JSON file paired with each
// trained ONNX model. Format mirrors the design plan's Section 4.3
// example, switched from YAML to JSON to avoid a go.mod dependency
// (matches the colleague's gru_config_run1.json convention).
//
// Example shortlist file:
//
//	{
//	  "schema_version":    "v1",
//	  "feature_extractor": "gru_v1",
//	  "seq_len":           50,
//	  "n_features":        68,
//	  "outputs": {
//	    "p50_trend_pred":   { "name": "p50_trend_pred",   "shape": [1, 1], "dtype": "float32", "range": [0.0, 1.0] },
//	    "tail_trend_label": { "name": "tail_trend_label", "shape": [1, 1], "dtype": "float32", "range": [0.0, 1.0] }
//	  }
//	}
//
// During the single-head transitional period (M7), a model trained with
// only the colleague's existing p50_score head can be expressed by
// declaring just one entry in outputs (or by the predictor logging a
// warning when it can't bind one of the expected names).
type Shortlist struct {
	SchemaVersion    string                  `json:"schema_version"`
	FeatureExtractor string                  `json:"feature_extractor"`
	SeqLen           int                     `json:"seq_len"`
	NFeatures        int                     `json:"n_features"`
	// InputName is the name of the model's input tensor as set by the
	// trainer's torch.onnx.export(input_names=...). Defaults to "input"
	// when omitted (matches the colleague's gru_model_run1.onnx).
	InputName string                  `json:"input_name,omitempty"`
	Outputs   map[string]ShortlistOut `json:"outputs"`
}

// ResolvedInputName returns the input tensor name to use, falling back
// to "input" when the shortlist did not specify one.
func (s *Shortlist) ResolvedInputName() string {
	if s.InputName == "" {
		return "input"
	}
	return s.InputName
}

// ShortlistOut describes one ONNX output binding: the name the model
// uses internally (matching what was set during torch.onnx.export), the
// tensor shape, the element dtype, and the expected value range. The
// range is informational; the predictor doesn't clamp.
type ShortlistOut struct {
	Name  string    `json:"name"`
	Shape []int     `json:"shape"`
	Dtype string    `json:"dtype"`
	Range []float32 `json:"range,omitempty"`
}

// LoadShortlist reads and parses the shortlist file at path. Returns a
// validated Shortlist or an error describing the first problem found.
// Errors here cause the score source to be disabled: the service keeps
// running but no ScoreEvents are emitted.
func LoadShortlist(path string) (*Shortlist, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read shortlist %q: %w", path, err)
	}
	var sl Shortlist
	if err := json.Unmarshal(data, &sl); err != nil {
		return nil, fmt.Errorf("parse shortlist %q: %w", path, err)
	}
	if err := sl.Validate(); err != nil {
		return nil, fmt.Errorf("invalid shortlist %q: %w", path, err)
	}
	return &sl, nil
}

// Validate sanity-checks a parsed Shortlist. Returns an error if any
// field is missing, inconsistent, or refers to an unknown extractor.
//
// Validation MUST be deterministic and self-contained: it doesn't read
// the .onnx file or call the runtime. M6's session wrapper performs
// shape-cross-check between Shortlist and the actual ONNX I/O metadata.
func (s *Shortlist) Validate() error {
	if s.SchemaVersion == "" {
		return fmt.Errorf("schema_version is required")
	}
	if s.FeatureExtractor == "" {
		return fmt.Errorf("feature_extractor is required")
	}
	if _, ok := extractors[s.FeatureExtractor]; !ok {
		return fmt.Errorf("unknown feature_extractor %q (known: %v)", s.FeatureExtractor, extractorNames())
	}
	if s.SeqLen <= 0 {
		return fmt.Errorf("seq_len must be > 0 (got %d)", s.SeqLen)
	}
	if s.NFeatures <= 0 {
		return fmt.Errorf("n_features must be > 0 (got %d)", s.NFeatures)
	}
	if len(s.Outputs) == 0 {
		return fmt.Errorf("outputs must have at least one entry")
	}
	for key, out := range s.Outputs {
		if out.Name == "" {
			return fmt.Errorf("outputs[%s].name is required", key)
		}
		if len(out.Shape) == 0 {
			return fmt.Errorf("outputs[%s].shape is required", key)
		}
		if out.Dtype == "" {
			return fmt.Errorf("outputs[%s].dtype is required", key)
		}
	}
	return nil
}

// Output looks up a shortlist output entry by key; returns the entry and
// true if found, zero value and false otherwise. Used by the predictor
// loop to bind result tensors by ONNX name.
func (s *Shortlist) Output(key string) (ShortlistOut, bool) {
	out, ok := s.Outputs[key]
	return out, ok
}
