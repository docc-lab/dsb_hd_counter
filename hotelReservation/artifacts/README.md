# Stage 3 model artifacts

`Dockerfile.online` bakes these into the per-service prediction-ON image
(`ims-build-push-rollout.sh --mode-online <svc> <tag>`):

| File | What | Status |
|---|---|---|
| `<svc>.onnx` | trained GRU model | `search.onnx` = the July 2026 retrain (blob `9357ea3`, input `[batch, 20, 75]`, output `p50_score`) |
| `<svc>-config.json` | run config with `n_features`, `service_vocab`, `scaler.mean/scale` | `search-config.json` = **APPROXIMATED** (see below). The trainer-emitted original was lost (the `gru_config_run1.json` on master is the pre-training input template; the post-training file no longer exists on the training host and retraining was abandoned). |

### About the approximated `search-config.json`

- `service_vocab` = `["profile", "search", "__unknown__"]`, deduced from the
  training file paths hardcoded in `gru_train.py` (a search + a profile run).
- The scaler was **re-fit on the committed labeled test file**
  (`run_data_iter1_ready.json`) using ONLINE-style extraction
  (`error_count=0`, `offset_from_workload_ms=0`), matching the Go `gru_v2`
  extractor exactly.
- **Measured quality** against that file's 810 labeled sequences through the
  actual committed model: **pearson r = 0.917, RMSE = 0.153, bias +0.12**
  (an identity scaler scores r = −0.2 — the standardization is what carries
  the signal). Use ŷ50 as a **trend** signal; calibrate absolute thresholds
  on the observed stream, or lean on the formula's `y50_current` for
  absolute levels.
- Caveat: the scaler's coverage is one contended search run; feature regimes
  far outside it (different aggressor mixes, other services) degrade the
  standardization unpredictably. `ScoreEvent.ModelVersion` reports
  `gru-run1@2026-07-09 approx-scaler` so downstream analysis can tag results.
- Supersede this file the moment any trainer-emitted config ships.

Prediction-OFF deployments need nothing from this directory: the Gordion
formula source runs from the `gordion-<svc>` ConfigMap alone (see
`STAGE3-predictor.md`).

When the trainer ships a new run: drop `<svc>.onnx` + `<svc>-config.json`
here, build a new image tag, roll out. If the feature set changed, the Go
extractor (`services/perf/score/onnx/feature_extractor.go`) must change in
lockstep and the run config needs a feature-set discriminator field.
