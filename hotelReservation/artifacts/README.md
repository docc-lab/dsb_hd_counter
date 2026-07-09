# Stage 3 model artifacts

`Dockerfile.online` bakes these into the per-service prediction-ON image
(`ims-build-push-rollout.sh --mode-online <svc> <tag>`):

| File | What | Status |
|---|---|---|
| `<svc>.onnx` | trained GRU model | `search.onnx` = the a07a375 "model fixed size" retrain (blob `e062053`, input `[batch, 20, 73]`, output `p50_score`, service encoded as a **scalar index**) |
| `<svc>-config.json` | run config with `n_features`, `service_vocab`, `service_encoding`, `scaler.mean/scale` | `search-config.json` = **APPROXIMATED** (see below). The trainer-emitted config was again not committed with a07a375. |

### About the approximated `search-config.json`

- `service_vocab` = `["profile", "search", "__unknown__"]`, deduced from the
  training file paths hardcoded in `gru_train.py` (unchanged at a07a375);
  `service_encoding` = `scalar_index` (search → index 1.0).
- The scaler was **re-fit on the committed labeled test file**
  (`run_data_iter1_ready.json`) using ONLINE-style gru_v3 extraction
  (`error_count=0`, `offset_from_workload_ms=0`), matching the Go extractor
  exactly, with the wall-clock offset features neutralized.
- **Measured quality** against that file's 810 labeled sequences through the
  actual a07a375 model: **pearson r = 0.901, RMSE = 0.184, bias +0.15**
  (an identity scaler scores negative correlation — the standardization is
  what carries the signal). Use ŷ50 as a **trend** signal; calibrate
  absolute thresholds on the observed stream, or lean on the formula's
  `y50_current` for absolute levels.
- The Go extractor **neutralizes the two wall-clock offset features**
  (`offset_ms`, `offset_from_workload_ms`) to z = 0 after standardization —
  measured quality-neutral, while preventing the drift a long-lived pod
  would otherwise feed (offset_ms = pod uptime; simulated 1-day uptime
  without neutralization degraded the previous model from r 0.917 to 0.888).
- Caveat: the scaler's coverage is one contended search run; feature regimes
  far outside it (different aggressor mixes, other services) degrade the
  standardization unpredictably. `ScoreEvent.ModelVersion` reports
  `gru-run1@2026-07-09 approx-scaler-v3` so downstream analysis can tag
  results.
- Supersede this file the moment any trainer-emitted config ships (it will
  carry the same `service_encoding: "scalar_index"` field, which the Go
  loader now requires).

Prediction-OFF deployments need nothing from this directory: the Gordion
formula source runs from the `gordion-<svc>` ConfigMap alone (see
`STAGE3-predictor.md`).

When the trainer ships a new run: drop `<svc>.onnx` + `<svc>-config.json`
here, build a new image tag, roll out. If the feature set changed, the Go
extractor (`services/perf/score/onnx/feature_extractor.go`) must change in
lockstep and the run config needs a feature-set discriminator field.
