# Mitigation Interface — Quick Reference

The hotelReservation gRPC services expose a **ContentionStream** server on TCP port **`:7900`** per pod. Any process anywhere can subscribe to receive a stream of `ScoreEvent` messages — one per ~100 ms window — and decide what to do about contention. The interface is fully decoupled from the predictor: a mitigation system only sees the score, never the raw counters or the model.

## Wire contract

Defined in [`services/perf/proto/contention.proto`](services/perf/proto/contention.proto):

```proto
service ContentionStream {
  rpc Subscribe(ScoreSubscribeReq) returns (stream ScoreEvent);
}

message ScoreSubscribeReq {
  repeated string only_methods = 1;
  float min_p50_trend  = 2;   // suppress events below this threshold
  float min_tail_trend = 3;
}

message ScoreEvent {
  int64  sample_id        = 1;
  int64  timestamp_ns     = 2;
  string service          = 3;   // e.g. "search"
  float  p50_trend_pred   = 4;   // [0, 1] — PRIMARY p50 signal (see below)
  float  tail_trend_label = 5;   // [0, 1] — formula y90 (tail-side)
  string model_version    = 6;   // model / calibration identifier
  string source_kind      = 7;   // "gordion" | future comparator tags
  float  y50_current      = 8;   // [0, 1] — formula's CURRENT y50, always set
  float  ext_pct_50       = 9;   // [0, 1] — extrinsic share of the p50 shift
  float  ext_pct_90       = 10;  // [0, 1] — extrinsic share of the p90 shift
  bool   prediction_on    = 11;  // p50_trend_pred came from the in-pod model
}
```

All score outputs are continuous values in `[0, 1]`; higher = more
contention. A mitigation thresholds whichever it cares about.

> **Field allocation (cross-repo contract).** Consumers keep their own
> copy of this proto — field numbers 1–11 are frozen as above, and 12–14
> are allocated to the mitigation repo's multi-horizon arrays
> (`p50_horizons`/`tail_horizons`/`horizon_ms`). A 2026-07-13 incident
> had a consumer copy with horizon arrays on 8–10: scalar
> `y50_current`/`ext_pct_*` then parse as one-element repeated fields on
> the consumer side, silently dropping the extrinsic signal (and any
> `has_spatial` logic reads garbage). If the two protos ever disagree
> again, that failure mode is the first thing to check.

> **prediction_on gotcha (same incident).** `p50_trend_pred` is the
> MODEL's output whenever the pod runs with `GORDION_SCORE_SOURCE=onnx`
> — a controller that wants Algorithm 1's formula must read
> `y50_current` (field 8), or the deployment must set
> `GORDION_SCORE_SOURCE=gordion`. The label_51-trained model saturates
> under any co-located load (steep k50=2.0/raw-σ label convention), so
> driving thresholds from `p50_trend_pred` with that model produces a
> load-presence detector, not a magnitude signal.

**Field semantics.** The in-pod producer is the Gordion scorer
(Algorithm 1), which every window computes the current scores
(`y50_current`, `tail_trend_label`) and the extrinsic decomposition
(`ext_pct_*`: how much of the shift deviates from the service's own
stage-1 arrival-rate→latency curve, i.e. is attributable to co-located
neighbors rather than own load). When the pod also runs the ONNX
predictor (**prediction-ON**), `p50_trend_pred` carries the model's
predicted **next-window** y50 and `prediction_on=true`; otherwise
`p50_trend_pred = y50_current`. Consumers that only threshold
`p50_trend_pred` work identically in both modes; consumers that care
about lead time check `prediction_on`.

## How to subscribe

Any language with a gRPC client works. The server has reflection registered, so no proto file needed at the client end.

**Python** (research notebooks, Python-side controllers):

```python
import grpc
channel = grpc.insecure_channel("victim-pod:7900")
stub = ContentionStreamStub(channel)
for ev in stub.Subscribe(ScoreSubscribeReq(min_tail_trend=0.5)):
    if ev.tail_trend_label > 0.7:
        ...act on ev...
```

**Go** (in-cluster operators, k8s controllers):

```go
conn, _ := grpc.NewClient("victim-pod:7900",
    grpc.WithTransportCredentials(insecure.NewCredentials()))
stream, _ := pb.NewContentionStreamClient(conn).Subscribe(
    ctx, &pb.ScoreSubscribeReq{MinTailTrend: 0.5})
for {
    ev, err := stream.Recv()
    if err != nil { break }
    // act on ev
}
```

**`grpcurl`** (smoke testing):

```bash
grpcurl -plaintext -d '{"min_tail_trend": 0.5}' \
    victim-pod:7900 \
    gordion.contention.ContentionStream/Subscribe
```

## Semantics worth knowing

- **Multi-subscriber**: any number of clients can connect to the same pod's `:7900`; they don't see each other. A research notebook + a real mitigation controller + a Grafana exporter can coexist without coordination.
- **Per-subscriber filters**: `min_p50_trend` and `min_tail_trend` skip events below the threshold *before they're sent over the wire*, so a mitigation only triggered on tail degradation pays for nothing else.
- **Per-subscriber drop-on-overflow**: each subscriber has its own bounded buffer (default 64 events). If a subscriber falls behind, only its events drop — fast subscribers are unaffected. Drop counts are surfaced via server-side log + (eventually) a Prometheus metric.
- **Latency**: end-to-end Sample → ScoreEvent → subscriber receive is ~1–2 ms typical, ~5–10 ms p99. Dominated by ONNX inference; no batching anywhere.
- **Model version stamp**: when the predictor swaps to a new model (image rolling restart), the `model_version` field changes. A defensive mitigation can refuse to act on events with an unknown version.
- **No back-pressure on the producer**: the predictor never blocks on the publisher; whatever subscribers do (or don't do) doesn't slow the gRPC service.

## What a mitigation typically does

The interface is mitigation-agnostic by design — pick whichever shape fits:

| Shape | What it does | Threshold that triggers |
|---|---|---|
| **Aggressor throttle** | Lower CPU shares / memory bandwidth budget on co-located pods | `tail_trend_label > 0.6` |
| **Replica scale-out** | Add a search replica to absorb load | `tail_trend_label > 0.4` sustained |
| **Node taint** | Move noisy neighbors elsewhere | `tail_trend_label > 0.7` for >5 windows |
| **Per-request shedding** | Drop low-priority requests at the gRPC interceptor | `p50_trend_pred > 0.5` |
| **Observability only** | Just record / plot for offline analysis | None (subscribe with empty filter) |

Different mitigations can subscribe at the same time and act on the same stream. The score side has no opinion on which one is "right."

## Where the score comes from

Inside each victim pod:

```
windowedSampler.takeSample (every 100 ms)
   ↓ Sample
gordion.Source  — Gordion formula always; + onnx.Model when prediction-ON
   ↓ ScoreEvent
score.Publisher
   ↓
ContentionStream :7900   ← mitigation subscribes here
```

The score source is the Gordion scorer
([`services/perf/score/gordion/`](services/perf/score/gordion/)),
calibrated from stage-1 outputs via a mounted ConfigMap; the ONNX
predictor ([`services/perf/score/onnx/`](services/perf/score/onnx/)) is
an optional component inside it (prediction-ON). Comparator scoring
algorithms (FIRM p50/p90 ratio, CPI-based, slowdown ratio, MAD z-score,
SLO burn rate) slot in as alternative `score.Source` implementations
selected by `GORDION_SCORE_SOURCE`; `source_kind` on the wire tells a
consumer which produced any given event if multiple are wired up.

## Operational notes

- `:7900` is exposed in `kubernetes/<svc>/<svc>-deployment.yaml` (`name: score`) and the matching Service. Cluster-internal subscribers use `<svc>.<namespace>:7900`.
- For external subscribers: `kubectl port-forward pod/<svc>-... 7900:7900` for dev, or expose via a NodePort / LoadBalancer for production.
- The interface lives only on services where `cmd/<svc>/main.go` calls `stage3wire.Setup(...)`. Currently wired: **search**, **profile**. Other services need the same ~10-line edit.
- See [`STAGE3.md`](STAGE3.md) for build/deploy/smoke-test instructions; design doc is `.cursor/plans/stage_3_online_predictor_*.plan.md`.
