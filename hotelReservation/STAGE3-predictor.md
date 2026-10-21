# Stage 3: In-Pod Contention Scoring (two modes)

This document describes how to build, deploy, and smoke-test the in-pod
scoring pipeline. The wire contract for consumers is in
[`MITIGATION-INTERFACE.md`](MITIGATION-INTERFACE.md); the plan +
verified findings behind this design are in
[`STAGE3-TWO-MODE-SCORING-PLAN.md`](STAGE3-TWO-MODE-SCORING-PLAN.md).

## Architecture

Each wired gRPC service binary exposes two proto-defined boundaries:

1. **Instrumentation publisher** (`:7901`, `InstrumentationStream`) fans
   every per-window `Sample` to in-binary subscribers (the score source)
   and any external gRPC consumers.
2. **Score publisher** (`:7900`, `ContentionStream`) fans every
   `ScoreEvent` to in-binary log sinks and external gRPC consumers
   (mitigation systems, research notebooks, the score-verify recorder).

Between them sits the **Gordion score source**
(`services/perf/score/gordion`), which implements Algorithm 1 of the
paper every window: frequency-normalize the interceptor's p50/p90
latency to kilocycles, causal-Gaussian smooth, tanh-score against
stage-1 baseline stats, and decompose the shift against the stage-1
intrinsic arrival-rate→latency curve into extrinsic percentages.

**Two modes:**

| | prediction-OFF | prediction-ON |
|---|---|---|
| What runs | Gordion formula only (pure Go) | formula + in-pod ONNX model |
| Artifacts needed | gordion ConfigMap (gordion.json + curve.csv) | ConfigMap **+** `.onnx` + trainer run config |
| Image | any windowed-sampling image | `Dockerfile.online` image |
| `p50_trend_pred` on the wire | formula's current y50 | model's predicted next-window ŷ50 |
| ONNX runtime dependency | none | libonnxruntime.so baked in image |

The formula outputs (`y50_current`, `tail_trend_label`, `ext_pct_50/90`)
are computed and published in **both** modes. A broken/missing model
degrades to prediction-OFF with a warning; scoring is never lost because
a model artifact is bad.

## Layout

```
services/perf/proto/instrumentation.proto  Sample wire format
services/perf/proto/contention.proto       ScoreEvent wire format (fields 8-11 = formula outputs)
services/perf/instrumentation/             in-binary publisher + sinks (:7901)
services/perf/score/                       ScoreEvent, publisher + sinks (:7900)
services/perf/score/gordion/               THE score source: config, curve, smoother, scorer, source
services/perf/score/onnx/                  prediction helper: run config, gru_v2 extractor, Model
cmd/internal/stage3wire/setup.go           wire-up + source registry (GORDION_SCORE_SOURCE)
artifacts/<svc>.onnx                       trained model (prediction-ON builds)
artifacts/<svc>-config.json                trainer-emitted run config (see artifacts/README.md)
noisy-neighbors/stage3-eval/score-verify/  calibration generator + recorder + analyzer + runbook
```

## Calibration (both modes; one-time per service + node type)

The Gordion scorer needs stage-1 outputs, mounted as a ConfigMap at
`/etc/gordion-conf/` (NOT `/etc/gordion/` — that would shadow the baked
model files in the online image):

```bash
# baseline stats from the no-stressor run at the operating point:
python3 noisy-neighbors/stage3-eval/score-verify/make_gordion_config.py \
    <baseline_run_data.json> --curve-csv /etc/gordion-conf/curve.csv --out gordion.json
kubectl create configmap gordion-search \
    --from-file=gordion.json --from-file=curve.csv
```

`gordion.json` fields: `k`, `smooth_window`, `latency_section`
(default `processing_time`, must match the curve's section), `baseline`
(p50/p90/σ in kcyc + fallback `freq_mhz`), `curve_csv` + column names,
`rate_signal`, `failure` (SLO ms + stall windows), `idle_hold_windows`
(bounds how long a score is held across zero-traffic windows before the
scorer goes silent and resets; default 100 = 10 s), and the four
`ablations` flags (`no_smoothing`, `no_ext`, `raw_rate_index`,
`use_current_y50`) for the internal ablation studies. Recalibration =
update the ConfigMap + restart the pod; no image rebuild.

## Model contract (prediction-ON)

The trainer (`gru_train.py`) finishes a run by writing
`gru_model_run{N}.onnx` + `gru_config_run{N}.json` (the POST-training
version with `run_id`, `n_features`, `service_vocab`, `scaler.mean/scale`).
Both are the deployment contract:

- input `"input"` `[batch, seq_len=20, n_features=73]`, output
  `"p50_score"` `[batch]`, clipped to [0,1] by the Go side (the graph
  doesn't clip);
- `n_features` is **fixed at 73** since a07a375 ("model fixed size"):
  the service is a single scalar index into `service_vocab` (not
  one-hot), and the emitted config carries a
  `service_encoding: "scalar_index"` discriminator which the Go loader
  requires. The Go `gru_v3` extractor
  (services/perf/score/onnx/feature_extractor.go) mirrors the trainer's
  `extract_features` byte-for-byte — guarded by the golden parity test
  (`go test ./services/perf/score/onnx/`);
- the run config validation rejects the PRE-training template and
  legacy one-hot configs with pointed errors (see `artifacts/README.md`
  — currently deploying with an approximated config, measured r = 0.90
  against ground truth).

Copy the pair to `artifacts/<svc>.onnx` + `artifacts/<svc>-config.json`
and build. If the trainer changes the feature set, the extractor changes
in lockstep and the run config needs a discriminator field.

## Build & deploy

```bash
# One-time after pulling this change, on the Linux dev host:
make proto            # regenerate contention.pb.go (new fields 8-11)
go build ./... && go vet ./...
go test ./services/perf/score/...

# prediction-ON image (needs artifacts/, see above):
./ims-build-push-rollout.sh --mode-online search v2.0

# prediction-OFF: any windowed image + the ConfigMap; leave GORDION_MODEL unset.
```

`kubernetes/search/search-deployment.yaml` mounts the `gordion-search`
ConfigMap (marked optional: pods start without it, the score source just
stays disabled) and sets `GORDION_SCORE_SOURCE=gordion`.

## Smoke-testing on cluster

```bash
kubectl get pods -l io.kompose.service=search -o name
kubectl logs <pod> | grep -E "score_gordion_started|score_onnx_model_loaded|vocab_miss"

kubectl port-forward <pod> 7900:7900 &
grpcurl -plaintext -d '{}' localhost:7900 \
        gordion.contention.ContentionStream/Subscribe
# expect ~10 events/s under load, with y50_current/ext_pct_* populated
# and prediction_on matching the deployed mode.
```

Full up/down contention verification: see
[`noisy-neighbors/stage3-eval/score-verify/RUNBOOK.md`](noisy-neighbors/stage3-eval/score-verify/RUNBOOK.md).

## Env knobs (per pod)

| Var | Effect |
|---|---|
| `ENABLE_WINDOWED_SAMPLING=true` | Required to start the windowed sampler at all. |
| `GORDION_SCORE_SOURCE` | `gordion` (auto-selected when the config file exists) \| `none`. `onnx` is a deprecated alias for gordion. |
| `GORDION_CONFIG` | gordion calibration JSON; default `/etc/gordion-conf/gordion.json` (Dockerfile.online) / `/etc/gordion/gordion.json` (bare code default). |
| `GORDION_MODEL` | `.onnx` path — presence enables prediction-ON; empty/unset = OFF. |
| `GORDION_MODEL_CONFIG` | trainer-emitted run config; default `/etc/gordion/model-config.json`. |
| `GORDION_LIBONNXRUNTIME` | `libonnxruntime.so` path (prediction-ON only). |
| `WINDOW_INTERVAL_MS` | sampler window; also fed into the model's `window_interval_ms` feature. |
| `GORDION_SCORE_PORT` / `GORDION_INSTRUMENTATION_PORT` | stream ports; defaults 7900/7901; instrumentation `0` disables. |
| `GORDION_INFLIGHT_DEPTH` / `GORDION_SUBSCRIBER_BUFFER` | channel depths; defaults 16/64. |

## Comparator score sources (follow-up pass)

`stage3wire/setup.go` selects the source from a registry
(`sourceBuilders`); each external baseline from the eval protocol
(FIRM p50/p90 ratio, C-Koordinator CPI signal, slowdown ratio, MAD
robust z-score, SLO burn rate) becomes one Go file implementing
`score.Source` + one registry entry, selected by `GORDION_SCORE_SOURCE`.
Internal ablations of Gordion itself are config flags, not separate
sources.

## Known issues to raise with the trainer

- `offset_ms` / `offset_from_workload_ms` features encode experiment
  wall-clock and have no faithful online equivalent — drop them at the
  next retrain. Online, the extractor neutralizes both to z = 0
  (measured quality-neutral; prevents pod-uptime drift).
- The offline `pct_ext_50/90` columns in the prepared training data are
  out of spec (`pct_ext_50` ≡ 0; `pct_ext_90` up to 22.1, but %ext < 1
  by construction) — the Go implementation (clamped) is the reference.
- `p90_contention_score` is zero in 83% of training windows — a future
  tail head needs higher-contention training coverage.
- The post-training `gru_config_run1.json` (and any non-`search`
  training files) were never committed and no longer exist on the
  training host. Current deployment uses an **approximated run config**
  (`artifacts/search-config.json`: vocab deduced from the training file
  paths, scaler re-fit on the committed labeled test file; measured
  r = 0.917 / RMSE 0.153 / bias +0.12 against ground truth through the
  actual model — see `artifacts/README.md`). Any future trainer-emitted
  config supersedes it.
