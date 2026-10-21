# Stage 3: Two-Mode Contention Scoring — Plan (refined)

Status: PLAN (nothing implemented yet). Branch: `stage3-predictor`.
Refined 2026-07-09 by a background planning agent; all new claims re-verified against the repo
(merge-base, artifact blobs, env plumbing). Companion docs: `STAGE3-predictor.md`,
`MITIGATION-INTERFACE.md`.

## 1. Context

Stage 1 (intrinsic latency–arrival-rate curve + baseline stats) and stage 2 (controlled
contention sweeps → training data) are essentially done. Stage 3 — the in-pod online
scoring pipeline — needs three things:

1. **New model contract.** Furkan pushed a retrained GRU to `origin/master` (`d38b8dd`,
   files in `noisy-neighbors/ml_model_deployment/`). The I/O contract changed (§3); the
   in-pod Go extractor (`gru_v1`, identity scaler, 68 features, seq 50) no longer matches.
2. **Prediction is now optional.** Two modes:
   - **Prediction-OFF**: the Gordion scoring algorithm (Algorithm 1) implemented purely in
     Go inside each service pod. No model artifact, no ONNX runtime needed at runtime.
   - **Prediction-ON**: everything from prediction-off, **plus** the ONNX model runs in-pod
     and adds a predicted next-window ŷ50. Only this mode needs the model deployed.
   Comparison scoring algorithms will also be Go implementations, substitutable behind the
   same interface (§8, deferred).
3. **Verification** that the published score stream tracks contention up and down, using
   the working `example-mixed-aggressors.yaml` setup (victim search @ 2400 RPS;
   SN 5200 + SS 6100 → E2E p90 76 ms "moderate"; SN 5400 + SS 6300 → E2E p90 1.54 s
   "severe").

Existing pipeline (verified): `windowedSampler.AttachInstrumentationPublisher` →
`instrumentation.Publisher` (gRPC :7901) → `score.Source` (today: only
`services/perf/score/onnx.Predictor`, registered as an `instrumentation.Sink`) →
`score.Publisher` → `score.GRPCSink` ContentionStream :7900 (**reflection already
registered** — grpcurl needs no proto flags).

### Branch topology (verified — this reshapes step ordering)

- **`d38b8dd` is NOT on `stage3-predictor`** (merge-base `12c28d2`). The retrained model,
  updated `scenario_onnx_go.go` (75-feature extractor + `loadRunConfig`), and `gru_train.py`
  live only on master. `stage3-predictor`'s `artifacts/search.onnx` (blob `e652e28`) is the
  **old** model; the new one is blob `9357ea3`.
- **`stage1-characterization/`** (curve_aggregate.py, curve_stats.py, …) exists **only on
  the `batch-perf` branch** — not on `stage3-predictor`, not on master.
- `WINDOW_INTERVAL_MS` is env-configurable (`services/perf/integration.go`) — the extractor
  must NOT hardcode 100.
- Both `kubernetes/{search,profile}` deployments hardcode `GORDION_SCORE_SOURCE=onnx` and
  reference the non-online `panic-fixed-1.3` image.
- The repo **vendors** dependencies (`vendor/` committed) — any new module requires
  `go mod tidy && go mod vendor` or the Docker build breaks.

## 2. Two points explained in plain language

### 2.1 The model's `.onnx` file alone is not enough to run it — a companion stats file is missing from the repo

The new training recipe normalizes every feature with sklearn's **StandardScaler**: at
inference time each feature must be transformed as `(x − mean) / scale` using the **exact
mean/scale values computed during training**. The training script also builds a
**service-name vocabulary** for the one-hot feature. So to run the model, Go needs three
things the `.onnx` does not contain: `scaler.mean/scale`, `service_vocab`, `n_features`.

`gru_train.py` writes all of these into a JSON **when training finishes**. Exact filename:
**`gru_config_run{N}.json`** (best run also copied to `gru_config_best.json`) — the *same
name* as the training-input template. The copy committed to master has only the
`model/training/data` keys → it is the **pre-training input template** (byte-identical in
shape to the hardcoded `config_plato` dict in gru_train.py), not the post-training output.
Furkan's own Go reference (`scenario_onnx_go.go::loadRunConfig`) panics on the committed
file. Note: this file is **neither** the stage-1 baseline **nor** the stage-1 intrinsic
curve — it's a model-training artifact. The stage-1 baseline stats and intrinsic curve
separately feed the Gordion *formula* (§5 step 4: gordion config scalars + `curve.csv`).

### 2.2 Putting the new score outputs on the wire requires a one-time proto regeneration

`ScoreEvent` on `:7900` is frozen in `services/perf/proto/contention.proto` (today: two
score numbers). Gordion produces four (y50, y90, %ext,50, %ext,90) plus, with
prediction-on, both current y50 and predicted ŷ50. Adding fields means editing the
`.proto` and running `make proto` once on the Linux dev host, then rebuilding. Decision
(confirmed): extend now, **regenerate FIRST** (§5 step 1) so every later step builds green.

## 2.5 Verification of every file in commit `d38b8dd` ("ml model update")

All six files double-checked (2026-07-09):

| File | Verdict |
|---|---|
| `gru_config_run1.json` | **Pre-training input template** (keys `model/training/data`; Furkan's own Go loader panics on it). Post-training version never committed. |
| `gru_model_run1.onnx` | Parsed the protobuf directly: input `"input"` `[batch, 20, 75]`, output `"p50_score"` `[batch]`; GRU(75→64) → mean+max pool → Linear neck → Linear head. **75 input features.** Graph does NOT clip — caller replicates `np.clip(0,1)`. |
| `gru_model_run1.pth` | Same weights, torch format (size math consistent with 75 inputs). |
| `gru_train.py` | Full diff reviewed; matches §3. Header NOTE: `p90_contention_score`/`pct_ext_50`/`pct_ext_90` exist in the data but are deliberately excluded (label leakage). Only `p50_contention_score` predicted. |
| `run_data_iter1_ready.json` | 830 samples, search only, 180 s run, arrival 204–1664 rps. Label `p50_contention_score`: mean 0.26, max 0.89, 667/830 nonzero (good spread). Red flags below. |
| `scenario_onnx_go.go` | Verified 1:1 vs gru_train.py: key orders, file-level `service_name`/`window_interval_ms` injection, unknown-last one-hot, full-vector standardization, client-side clip. **Authoritative Go reference for our extractor.** |

### 🔴 Critical: the model was trained on MORE data than what's committed

`n_features = 72 + len(service_vocab)`. ONNX input is **75** ⇒ vocab size **3** ⇒ at least
two real service names in the training set + `__unknown__`. Committed data contains only
`search` ⇒ vocab 2 ⇒ 74 features. Therefore regenerating scaler/vocab from committed data
**cannot** pair with the committed `.onnx` (74 ≠ 75, and the scaler was fit on more data).
**We need from Furkan:** the post-training `gru_config_run1.json` (its `service_vocab` also
reveals what he trained on), and ideally the full training file set.

### 🟡 Data-quality red flags in the training data (raise with Furkan)

- `pct_ext_50` **0 for all 830 samples**; `pct_ext_90` nonzero in only 8/830 with **max
  22.1** — %ext = (T̃−D)/T̃ is < 1 by construction, so the offline %ext computation looks
  buggy. Excluded from training, but our Go implementation should become the clamped,
  documented reference.
- `p90_contention_score` is 0 for 687/830 samples — a future tail head would train sparse.
- `error_count` present but 0 everywhere (consistent with in-pod constant 0 — fine).
- `offset_from_workload_ms` spans 1.5–85 s → train/serve skew (§3).

## 3. The new model contract (what actually changed)

| Aspect | Old (`gru_v1`, in-pod today) | New (July 2026 retrain) |
|---|---|---|
| Sequence length | 50 | **20** |
| Scaling | log1p only | log1p **then StandardScaler** (from run config) |
| Features | 68 | **75** (= 72 + vocab of 3) |
| New features | — | `error_count`; `offset_ms`, `offset_from_workload_ms`, `window_interval_ms`; service one-hot |
| Config needed | none | post-training `gru_config_run{N}.json` |
| Output | `p50_score` [batch], clip client-side | same |
| Label | y50 of next window | same |

Feature order (byte-for-byte with trainer): 10 perf_counters + 10 perf_deltas +
5 (arrival_count, request_count, error_count, arrival_rps_1s, arrival_rps_3s) + 33 timing
stats (processing/total/blocking × 11) + 6 freq (+turbo) + 3 (offset_ms,
offset_from_workload_ms, window_interval_ms) → all log1p'd (67) → + service one-hot +
5 derived ratios → StandardScaler over the **full** vector.

**Train/serve skew:** `interceptor.WindowTimingStats` has no error_count (feed constant 0 —
matches training). `offset_from_workload_ms` has no online equivalent (feed 0 — genuine
skew). `offset_ms` online = time-since-pod-start (unbounded) vs 70–155 s in training.
Recommend dropping the offset features next retrain.

## 4. Design decisions (confirmed with user)

- Both modes run the Gordion formula in Go every window. Prediction-ON additionally
  publishes ONNX ŷ50. Stream carries both current and predicted p50; y90/%ext always
  formula (model single-head).
- No shortlist format: predictor consumes the trainer-emitted run config directly. Since
  RunConfig has no `feature_extractor` field, the extractor is hardcoded to the single
  `gru_v2` recipe; a future feature-set change requires the trainer to add a discriminator
  field (record in runconfig.go doc comment).
- Gordion inputs via config file + direct CSV read (no offline transformation; Go sorts by
  rate and linearly interpolates at lookup; baseline scalars live in the config file).
  curve.csv's `svc_p50_norm_kcyc`/`svc_p90_norm_kcyc` are already `latency × freq`
  (kilocycles) = Algorithm 1's `T*f` domain. Default `latency_section: processing_time`
  (matches the curve columns; switching to total_time requires re-aggregating the curve).
- **Proto field semantics (pinned):**
  - `p50_trend_pred` (field 4): the *primary* p50 signal — ŷ50 (clipped) when prediction
    ON; formula y50 when OFF. One primary signal regardless of mode.
  - `tail_trend_label` (field 5): always formula y90.
  - `y50_current` (new field 8): always formula y50 (ON mode thus carries both).
  - `ext_pct_50` / `ext_pct_90` (new 9/10); `prediction_on` (new 11, bool).
  - `source_kind` = `"gordion"` always (mode expressed by `prediction_on`);
    `model_version` = run-config id when ON, gordion-config version when OFF. Fields 8–11
    are additive; existing subscribers and min-trend filters unaffected.
- After the refactor **gordion.Source is the only `score.Source`**; the onnx package
  becomes a model-inference helper owned by gordion. `GORDION_SCORE_SOURCE=onnx` stays as
  deprecated alias.
- Scope: core first. External comparators (§8) follow in a later pass on the registry
  built now.

## 5. Implementation (step-ordered)

**Step 0 — Branch sync + long-pole requests (everything depends on this):**
- Merge `origin/master` into `stage3-predictor` (or cherry-pick `de83624` + `d38b8dd`) so
  the retrained model, updated `scenario_onnx_go.go`, and `gru_train.py` are on the working
  branch — otherwise step 3 would port the *old* 68-feature scenario code. Expect trivial
  conflicts in `noisy-neighbors/` and `ims-build-push-rollout.sh`.
- Port `stage1-characterization/` from `batch-perf` (or copy the generated curve.csv +
  baseline stats from the stage-1 data host) — `stage3-predictor` has no curve tooling or
  data. Confirm `curve_stats.py` emits the baseline σ values the gordion config needs; if
  not, compute σ from stage-1 clean-window normalized latencies and document the recipe.
- **Ask Furkan now** for the post-training `gru_config_run1.json` (+ ideally all training
  files). Gates only prediction-ON verification; all code can be written against the known
  `loadRunConfig` format; prediction-OFF fully unblocked.

**Step 1 — Proto first** (additive fields; regenerating *before* writing Go that uses them
keeps every later dev-host build green): edit `contention.proto` fields 8–11 with §4
semantics in comments; on dev host `make proto`; verify diff confined to contention pb
files (don't commit unrelated plugin-version churn); `go build ./...`; commit. Never
hand-edit `.pb.go` on Windows.

**Step 2 — score package:** `event.go` adds `Y50Current`, `ExtPct50`, `ExtPct90`,
`PredictionOn`; `converter.go` maps them; `log_sink.go` logs them. Green against the
regenerated pb.

**Step 3 — ONNX side (`services/perf/score/onnx/`):**
- `runconfig.go` replaces `shortlist.go`: RunConfig mirroring `loadRunConfig`; validation
  returns **errors, never panics** (serving pod): vocab non-empty + `__unknown__` last,
  scaler lengths == n_features == 72+len(vocab), seq > 0.
- `feature_extractor.go`: drop the registry; single `gru_v2` recipe ported from d38b8dd
  `scenario_onnx_go.go::extractFeaturesRaw` — `error_count=0`, `offset_from_workload_ms=0`
  (documented skew), `offset_ms=Sample.OffsetMs`, `window_interval_ms` **plumbed from the
  actual configured interval** (env `WINDOW_INTERVAL_MS`; do NOT hardcode 100). One-hot
  index resolved once at construction; **startup warning if ServiceName not in vocab**
  (silent `__unknown__` fallback would quietly degrade every prediction). Standardize the
  full vector.
- `predictor.go` → `model.go`: demote to `Model` helper — ring (seq from run config) +
  session + extractor; synchronous `Push(sample) (ŷ50, ok)` called from gordion's loop
  goroutine (single-threaded, matches Session's no-concurrency contract); clip [0,1]; keep
  counters + debounced logging; no publisher/Source.
- `session.go`: fixed input `"input"` `[1, seq, n_features]`, output `"p50_score"` shape
  `[1]` (not `[1,1]`). Keep sync.Once ORT init + allocate-once tensors.
- **Golden parity test** (the main guard against silent feature-order/scaler bugs): commit
  a small testdata slice of `run_data_iter1_ready.json` + fake RunConfig; assert the Go
  extractor's raw and standardized vectors match offline-generated expected values from
  the colleague's `extractFeaturesRaw` path. Extend to full-inference parity vs
  `scenario_onnx_go.go` when the real config arrives.

**Step 4 — Gordion source (new `services/perf/score/gordion/`):**
- `config.go` (JSON load + validation):

```json
{
  "k": 1.0, "smooth_window": 30,
  "latency_section": "processing_time",
  "baseline": { "p50_kcyc": 0.0, "p90_kcyc": 0.0,
                "sigma50_kcyc": 0.0, "sigma90_kcyc": 0.0, "freq_mhz": 2400 },
  "curve_csv": "/etc/gordion/curve.csv",
  "curve_columns": { "rate": "target_rps", "p50": "svc_p50_norm_kcyc", "p90": "svc_p90_norm_kcyc" },
  "rate_signal": "arrival_rps_3s",
  "failure": { "slo_p90_ms": 0, "stall_windows": 5 },
  "ablations": { "no_smoothing": false, "no_ext": false,
                 "raw_rate_index": false, "use_current_y50": false }
}
```

- `curve.go`: `encoding/csv` (stdlib — no vendor churn) → sorted slice; piecewise-linear
  D50(λ)/D90(λ), end-clamped; tolerant of extra columns (select by configured names).
- `smooth.go`: causal Gaussian (σ = w/3, partial-kernel renormalization during warm-up);
  reused for the curve-indexing rate signal unless `raw_rate_index`.
- `scorer.go`: kcyc normalize `T = (p_ns/1000) × actual_freq_mhz / 1000`, fallback to
  `baseline.freq_mhz` when `Freq.OK=false`; `y = clamp01(tanh(k·(T̃−p)/σ))`;
  `%ext = clamp01((T̃−D(λ))/T̃)`; failure short-circuit → y=1.0: **raw** window p90
  (ns→ms, wall-clock — NOT kcyc) > `slo_p90_ms` (if set), or ≥ `stall_windows` consecutive
  windows with `ArrivalCount>0 && RequestCount==0`; zero-completion windows otherwise hold
  the previous smoothed latency.
- `source.go`: implements `score.Source` (non-blocking Emit + bounded channel + loop
  goroutine, same pattern as the current Predictor); optionally owns an `onnx.Model`
  (Push inline); publishes per §4 field mapping.
- Unit tests per file: interpolation edges, smoothing warm-up, tanh monotonicity, failure
  short-circuit, zero-completion hold, both-mode event field population.

**Step 5 — `stage3wire/setup.go`:** registry map keyed by `GORDION_SCORE_SOURCE`
(`gordion` default when a gordion config is present, `none`; `onnx` deprecated alias →
gordion+prediction). Env: `GORDION_CONFIG` (default `/etc/gordion/gordion.json`),
`GORDION_MODEL`, `GORDION_MODEL_CONFIG` (replaces `GORDION_SHORTLIST`); keep
`GORDION_LIBONNXRUNTIME`, `GORDION_INFLIGHT_DEPTH`. Preserve degrade-gracefully: any
construction failure logs and continues. Prediction-ON iff `GORDION_MODEL` set and Model
constructs; a broken model **degrades to prediction-OFF** (clear log,
`prediction_on=false`), never disables scoring. Prediction-OFF needs no libonnxruntime at
runtime (ORT init is behind sync.Once, only reached when a Model constructs) — gordion-only
mode runs in any windowed-sampling image with the ConfigMap mounted.

**Step 6 — Artifacts/image/k8s:** `artifacts/search-config.json` + new `search.onnx`
(replace stale blob `e652e28` with `9357ea3`); delete `*-shortlist.json`;
`Dockerfile.online`: COPY rename shortlist→config, env rename, add `GORDION_CONFIG`;
per-service ConfigMap for `gordion.json` + `curve.csv` (baselines differ per service;
updatable without rebuilds); update **both** search and profile deployment yamls (both
hardcode `GORDION_SCORE_SOURCE=onnx` and reference the non-online `panic-fixed-1.3`
image — verification deploys must use the `-online` image); fix ims script usage text.

**Step 7 — Verification harness (new `noisy-neighbors/stage3-eval/score-verify/`):**
`record_scores.sh` (grpcurl :7900 → NDJSON; reflection already registered), `phases.yaml`
+ `verify_score_tracking.py` (per-phase stats, monotonicity baseline<moderate<severe,
rise/decay lag, timeline plot with ŷ50-vs-y50 overlay), `RUNBOOK.md` (5 phases:
none → SN 5200/SS 6100 → SN 5400/SS 6300 → moderate → none; victim search @2400 RPS;
~3 min/phase ≈ 1800 events/phase at 100 ms windows; pass criteria: ordered phase means,
decay to ~0, %ext high under aggressors, no stream gaps). Check the mixed-aggressors
config's sockshop prerequisite (`TODO_SOCKSHOP.md`; confirm `lib/testbed-ss.sh` works,
else comment out SS entries, rescale SN, adjust expected magnitudes). Author scripts with
LF endings (verify .gitattributes covers `*.sh`).

**Step 8 — Docs:** `STAGE3-predictor.md` + `MITIGATION-INTERFACE.md` (field-semantics
table from §4); raise-with-trainer items: offset skew (drop next retrain), buggy offline
pct_ext (§2.5), sparse p90 label, carry window_interval_ms per-sample.

## 6. Verification (remote host — after each Windows authoring batch: `git pull && go build ./... && go vet ./... && go test ./services/perf/score/...`)

1. Step-1 gate: `make proto`; diff confined to contention pb; build green; commit.
2. After steps 2–5: build/vet/test (gordion units + golden parity). If any new module
   slipped in: `go mod tidy && go mod vendor` (forgetting breaks the Docker build).
3. **Prediction-OFF first (unblocked):** deploy via `ims-build-push-rollout.sh
   --mode-online search v2.0` with `GORDION_MODEL` unset (or windowed image + ConfigMap);
   grpcurl smoke — assert `prediction_on=false`, `y50_current` populated, sane idle
   scores; then the 5-phase run + analyzer.
4. **Prediction-ON (gated on Furkan's config):** full-inference parity vs
   `scenario_onnx_go.go` (same JSON window/config/model, match to float tolerance);
   redeploy with model baked; assert `prediction_on=true`; repeat 5-phase run; compare
   ŷ50-vs-y50 lead/lag.
5. Rollback check: `GORDION_SCORE_SOURCE=none` still serves with no score events.

## 7. Risks

- **Furkan's config is a hard external dependency** for prediction-ON — requested in
  step 0; prediction-OFF ships independently.
- **Silent one-hot fallback:** deployment ServiceName not exactly matching a vocab entry
  scores every window as `__unknown__` with no error → startup vocab-membership warning.
- **Feature-order/scaler drift:** any slip in the 75-element recipe produces
  plausible-but-wrong scores → golden parity test is mandatory.
- **Branch drift:** authoring against pre-d38b8dd scenario code targets the wrong
  68-feature contract → step 0 merge; verify blob `9357ea3` lands in `artifacts/`.
- **Stage-1 calibration validity:** baseline kcyc scalars + curve.csv must come from the
  same node/CPU family and latency_section as the deployment target; document provenance
  in gordion.json.
- **Train/serve skew** (offsets): accept this iteration; monitor via ŷ50-vs-y50 overlay;
  fix at next retrain.
- **Windows/Linux split:** nothing compiles locally; keep commits self-contained per step
  gate; watch CRLF on shell scripts; never hand-edit `.pb.go`.

## 8. Explicitly deferred (next pass)

- External comparators, each a Go `score.Source` in the registry, formulas confirmed with
  the user first: FIRM p50/p90 ratio, C-Koordinator CPI signal, slowdown ratio, robust
  z-score (MAD), SLO burn rate. Internal ablations are already covered by §5 step-4 config
  flags.
- Second model head (`tail_trend_label` from the model) — formula y90 fills it meanwhile.
- Wiring stage 3 beyond search/profile.
