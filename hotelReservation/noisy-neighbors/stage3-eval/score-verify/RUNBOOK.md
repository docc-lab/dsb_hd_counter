# Score-vs-contention verification runbook

Goal: demonstrate that the pod's published score stream (`:7900`) tracks
contention **up and down**, using the known-good mixed-aggressor setup
(`configs/example-mixed-aggressors.yaml`): victim search @ 2400 RPS;
measured E2E at SN 5200 + SS 6100 ≈ p50 14 ms / p90 76 ms ("moderate");
at SN 5400 + SS 6300 ≈ p50 19 ms / p90 1.54 s ("severe").

Run it once in prediction-OFF mode (formula only — no model artifact
needed) and, once the trainer's run config lands, again in
prediction-ON mode to compare ŷ50 against the formula's y50.

## 0. One-time calibration (per victim service, per node type)

```bash
# 1. Stage-1 intrinsic curve: calibration/search/curve.csv (committed;
#    produced by curve_aggregate.py, which lives on the batch-perf
#    branch — 36 levels, 100–3370 RPS, flat ~32/37 kcyc; the 100-RPS
#    point is cache-cold-elevated, which the scorer's ext clamp handles).
# 2. Baseline stats from the NO-STRESSOR run at the operating point,
#    same latency section as the curve. The curve experiment's own raw
#    windowed run data at the level nearest 2400 RPS (e.g.
#    <exp_dir>/raw/windowed/2410/run_data_iter*_raw.json) is exactly
#    that — intrinsic, no aggressors:
python3 make_gordion_config.py <baseline_run_data.json> \
    --curve-csv /etc/gordion-conf/curve.csv --out gordion.json
# 3. Ship both to the pod:
kubectl create configmap gordion-search \
    --from-file=gordion.json \
    --from-file=curve.csv=calibration/search/curve.csv \
    --dry-run=client -o yaml | kubectl apply -f -
```

The baseline stats and curve MUST come from the same node/CPU family as
the verification deployment — the kcyc normalization removes DVFS, not
hardware differences. `gordion.json`'s `_provenance` block records the
source run.

## 1. Deploy the victim

- **Prediction-OFF**: any windowed-sampling image + the ConfigMap. Env:
  `ENABLE_WINDOWED_SAMPLING=true`, `GORDION_SCORE_SOURCE=gordion`,
  `GORDION_CONFIG=/etc/gordion-conf/gordion.json`, `GORDION_MODEL` unset.
- **Prediction-ON**: `./ims-build-push-rollout.sh --mode-online search v2.0`
  (needs `artifacts/search.onnx` + `artifacts/search-config.json`).

Startup log check (`kubectl logs <pod> | grep gordion`): expect
`score_gordion_started` with the right `latency_section` / config
version, and in ON mode `score_onnx_model_loaded` — a
`score_onnx_vocab_miss` warning means the ServiceName isn't in the
model's vocab and predictions are garbage; stop and fix.

## 2. Start the recorder (before any load)

```bash
kubectl port-forward pod/<search-pod> 7900:7900 &
./record_scores.sh localhost:7900 scores.ndjson &
touch phases.yaml && echo "phases:" > phases.yaml
```

## 3. Run the 5-phase schedule

Victim wrk2 stays at **2400 RPS for the whole experiment** (per
`example-mixed-aggressors.yaml` `loadgen: {rps: 2400}`) — only the
aggressor load changes, so any score movement is by construction
extrinsic. ~3 min per phase (≈1800 events/phase at 100 ms windows;
phase-mean stats trim the first 15 s).

Before **each** phase, append a marker (then change the aggressor rates):

```bash
echo "  - {name: <phase>, start: \"$(date -u +%FT%TZ)\", rank: <rank>}" >> phases.yaml
```

| # | phase name    | SN wrk2 rps | SS wrk2 rps | rank |
|---|---------------|------------|------------|------|
| 1 | baseline      | off        | off        | 0 |
| 2 | moderate-up   | 5200       | 6100       | 1 |
| 3 | severe        | 5400       | 6300       | 2 |
| 4 | moderate-down | 5200       | 6100       | 1 |
| 5 | off           | off        | off        | 0 |

After phase 5 ends: `echo "end: \"$(date -u +%FT%TZ)\"" >> phases.yaml`,
stop the recorder and the victim loadgen.

(SN/SS rates are the `co_tenants` wrk2 rates in the mixed-aggressors
config; run the two aggressor wrk2 instances per phase for the phase
duration, or use three pre-made config variants. The sockshop (SS)
testbed must actually be up — `lib/testbed-ss.sh`; if it isn't, drop
the SS column, keep SN-only, and expect smaller phase deltas.)

## 4. Analyze

```bash
python3 verify_score_tracking.py --scores scores.ndjson --phases phases.yaml \
    --plot timeline.png
```

Pass criteria (enforced by the script, non-zero exit on failure):

1. **Monotonicity**: steady-state mean y50 and y90 ordered
   baseline < moderate < severe on the way up AND severe > moderate > off
   on the way down.
2. **Decay**: y50 returns below 0.1 within the final "off" phase
   (gradual, not instant — that's the smoothing working as designed).
3. **Extrinsic attribution**: mean %ext,50/90 higher in aggressor phases
   than baseline phases (victim load never changed).
4. **Stream health**: no event gap > 10× the median interval (~100 ms).
5. **Prediction (ON runs only)**: ŷ50 correlates with y50 (r ≥ 0.3);
   the reported best cross-correlation lag shows whether the model
   leads (positive lag) the formula — the entire point of prediction.

## Troubleshooting

- **No events at all**: `kubectl logs <pod> | grep -E "score_gordion|stage3"`.
  `score_gordion_started` absent → config didn't load (ConfigMap mounted?
  `GORDION_CONFIG` path right?). Present but silent → is windowed
  sampling on and traffic flowing? The scorer skips windows until the
  first completion is observed.
- **Scores pinned at 0 under load**: baseline stats too large (wrong
  latency section, or baseline run taken under contention). Check
  `gordion.json` `_provenance` and regenerate.
- **Scores pinned at 1 at baseline**: baseline stats too small, or the
  curve/baseline came from a different node type / frequency regime.
- **ext ≈ 0 under aggressors**: curve columns mismatched (rate column
  vs actual arrival rates — the curve's `target_rps` domain must cover
  the victim's per-pod arrival rate, which for search @ victim 2400 RPS
  is the *interceptor* arrival rate, not the E2E RPS).
- **`score_onnx_run_error` flood**: model/config pair mismatched
  (n_features vs vocab — see artifacts/README.md).
