package onnx

import (
	"encoding/json"
	"math"
	"os"
	"testing"

	"github.com/docc-lab/dsb_hd_counter/hotelReservation/services/perf"
)

// parityFixture mirrors testdata/gru_v3_parity.json: real training
// windows + expected feature vectors computed offline with the
// trainer's exact recipe (gru_train.py::extract_features) under
// online-visible inputs (error_count=0, offset_from_workload_ms=0).
// This is the guard against transcription drift between the Go
// extractor and the Python trainer: any reorder, dropped field, or
// scaling slip shows up as a mismatch here, not as
// plausible-but-wrong scores in production.
type parityFixture struct {
	ServiceName      string          `json:"service_name"`
	WindowIntervalMs float64         `json:"window_interval_ms"`
	RunConfig        RunConfig       `json:"run_config"`
	Samples          []json.RawMessage `json:"samples"`
	Expected         [][]float64     `json:"expected"`
}

func loadParityFixture(t *testing.T) *parityFixture {
	t.Helper()
	data, err := os.ReadFile("testdata/gru_v3_parity.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fx parityFixture
	if err := json.Unmarshal(data, &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if err := fx.RunConfig.Validate(); err != nil {
		t.Fatalf("fixture run config invalid: %v", err)
	}
	if len(fx.Samples) == 0 || len(fx.Samples) != len(fx.Expected) {
		t.Fatalf("fixture has %d samples but %d expected vectors", len(fx.Samples), len(fx.Expected))
	}
	return &fx
}

func TestGruV3GoldenParity(t *testing.T) {
	fx := loadParityFixture(t)

	ex, vocabMiss := newExtractorV3(&fx.RunConfig, fx.ServiceName, fx.WindowIntervalMs)
	if vocabMiss {
		t.Fatalf("fixture service %q unexpectedly not in vocab %v", fx.ServiceName, fx.RunConfig.ServiceVocab)
	}

	for si, raw := range fx.Samples {
		var s perf.Sample
		if err := json.Unmarshal(raw, &s); err != nil {
			t.Fatalf("sample %d: unmarshal into perf.Sample: %v", si, err)
		}
		got := ex.Extract(s)
		want := fx.Expected[si]
		if len(got) != len(want) {
			t.Fatalf("sample %d: got %d features, want %d", si, len(got), len(want))
		}
		for i := range want {
			// Go computes in float64 and casts to float32 at the end
			// (matching the reference client); the fixture stores the
			// float64 values. Tolerance covers the final float32
			// rounding on values up to ~O(100).
			diff := math.Abs(float64(got[i]) - want[i])
			tol := 1e-4 + 1e-5*math.Abs(want[i])
			if diff > tol {
				t.Errorf("sample %d feature[%d]: got %v want %v (|diff|=%g > tol=%g)",
					si, i, got[i], want[i], diff, tol)
			}
		}
	}
}

// TestGruV3VocabFallback verifies the loud-fallback contract: a service
// name missing from the vocab maps to the last (__unknown__) slot and
// is reported so the caller can warn.
func TestGruV3VocabFallback(t *testing.T) {
	fx := loadParityFixture(t)

	ex, vocabMiss := newExtractorV3(&fx.RunConfig, "not-a-real-service", fx.WindowIntervalMs)
	if !vocabMiss {
		t.Fatal("expected vocabMiss=true for a name outside the vocab")
	}
	if want := float64(len(fx.RunConfig.ServiceVocab) - 1); ex.svcIndex != want {
		t.Fatalf("fallback service index = %v, want last slot %v", ex.svcIndex, want)
	}

	// Explicit __unknown__ is a legitimate configuration, not a miss.
	_, miss := newExtractorV3(&fx.RunConfig, unknownService, fx.WindowIntervalMs)
	if miss {
		t.Fatal("explicit __unknown__ must not be reported as a vocab miss")
	}
}

// TestGruV3NilTimingWindow: the first window can arrive before the
// timing aggregator has emitted; the extractor must produce a full
// vector of the right length with zeros in the timing groups (matching
// the trainer's _safe(None)=0 path), not panic.
func TestGruV3NilTimingWindow(t *testing.T) {
	fx := loadParityFixture(t)
	ex, _ := newExtractorV3(&fx.RunConfig, fx.ServiceName, fx.WindowIntervalMs)

	got := ex.Extract(perf.Sample{})
	if len(got) != fx.RunConfig.NFeatures {
		t.Fatalf("empty sample: got %d features, want %d", len(got), fx.RunConfig.NFeatures)
	}
	for i, v := range got {
		if math.IsNaN(float64(v)) || math.IsInf(float64(v), 0) {
			t.Fatalf("empty sample: feature[%d] = %v (must be finite)", i, v)
		}
	}
}

func TestRunConfigValidate(t *testing.T) {
	fx := loadParityFixture(t)

	// The committed pre-training template shape must be rejected with
	// the pointed error, not accepted or crashed on.
	pre := RunConfig{}
	if err := pre.Validate(); err == nil {
		t.Fatal("pre-training template must fail validation")
	}

	// Vocab not ending in __unknown__.
	bad := fx.RunConfig
	bad.ServiceVocab = []string{"search", "profile"}
	if err := bad.Validate(); err == nil {
		t.Fatal("vocab without trailing __unknown__ must fail validation")
	}

	// Missing / legacy service_encoding (pre-a07a375 one-hot config).
	bad = fx.RunConfig
	bad.ServiceEncoding = ""
	if err := bad.Validate(); err == nil {
		t.Fatal("missing service_encoding must fail validation (legacy one-hot config)")
	}
	bad.ServiceEncoding = "one_hot"
	if err := bad.Validate(); err == nil {
		t.Fatal("unsupported service_encoding must fail validation")
	}

	// n_features inconsistent with the fixed recipe width.
	bad = fx.RunConfig
	bad.NFeatures = gruV3NFeatures + 1
	if err := bad.Validate(); err == nil {
		t.Fatal("n_features != 73 must fail validation")
	}

	// Scaler length mismatch.
	bad = fx.RunConfig
	bad.Scaler.Mean = bad.Scaler.Mean[:len(bad.Scaler.Mean)-1]
	if err := bad.Validate(); err == nil {
		t.Fatal("scaler length mismatch must fail validation")
	}
}
