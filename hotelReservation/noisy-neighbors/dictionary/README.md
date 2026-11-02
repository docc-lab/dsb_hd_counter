# Per-endpoint dictionary on HotelReservation (Phase B)

Phase B of the per-endpoint dictionary validation (`PHASEB-HANDOFF.md`, repo root). The
BigSvc/Blueprint half lives in `blueprint/examples/bigsvc`; this directory holds the
HotelReservation side.

## Pieces

| Path | What |
|---|---|
| `../../gordion/` | the recorder (ported from `blueprint/runtime/plugins/gordion`): per-window per-endpoint latency percentiles and raw samples, caller send stamp (`gordion-sent` gRPC metadata / HTTP header), blocked-time accounting, per-window process CPU and core MHz; `grpc.go` = server/client interceptors, `http.go` = frontend middleware |
| `../../services/*/server.go`, `../../dialer/dialer.go` | one-line wiring: `gordion.ServerOptions(...)` before `grpc.NewServer`, `gordion.ClientInterceptor()` on every dial, `gordion.HTTPHandler` on the frontend mux; pass-through unless `GORDION_OUT` is set |
| `../../services/perf/perf_api.c` | `PERF_HOOKS=0` disables the per-request perf counters |
| `../../cmd/hrgen` | open-loop HTTP load generator with the wrk2 script's request parameters, per-endpoint mixes, Dirichlet resampling and linear mix ramps; writes the same JSON lines as BigSvc's wlgen |
| `hr.sh` | node-0 driver: build/push the image, place the databases, deploy every service with the recorder (SUT pinned on `NODE`/`CPUSET`, optional `AGGR` co-tenants pinned on the same cores), run `hrgen` pinned on the service node, collect every service's streams + `meta.json` |
| `queue-*.sh`, `knee.py` | the experiment queues (B0 … B5) and the knee heuristic |
| `RESULTS-B.md` | the running results record behind the report doc |

## Run layout (`/local/results/hr/<ts>-<name>/`, fetched to `blueprint/examples/bigsvc/results/hr/`)

`<svc>.jsonl` (recorder of each service), `<svc>-client.jsonl` (that service's caller-side view of
its callees), `callers-client.jsonl` (all of them concatenated), `gordion.jsonl` (= the SUT's file,
what the analysis scripts read), `wlgen.jsonl` (hrgen), `meta.json` (placement, governor, MHz,
stressor label).

## Analysis (laptop, never on node-0 while a generator runs)

```
A=../../../../blueprint/examples/bigsvc/analysis
python $A/analyze.py --idle-costs <r1-idle-*> --svc reservation --out-costs costs-reservation.json   # B1
GORDION_FREQ_NORM=1 python $A/analyze.py <sweep> --svc reservation --costs costs-reservation.json   # B2 server side
GORDION_FREQ_NORM=1 python $A/client_view.py <sweep> --costs ...                                    # caller view (frontend)
python $A/analyze.py <sweep> --svc reservation --caller callers --costs ...                          # caller view (downstream SUT)
python $A/e1_compare.py --uniform <b2> --long <b3> --fit --costs ...                                  # B3 mix dependence
python $A/b6_compare.py <sweep> [--svc reservation --caller callers]                                  # B6
python $A/b4_compare.py <ramp> --dict <b2> [--dict <b3>] --costs ... [--truth <stressed sweep>]      # B4/B5
python $A/a5_compare.py <ramp-stress> --a2 <b2> --truth <stressed sweep> --control <ramp>            # B5 attribution
```

`GORDION_FREQ_NORM=1` divides each window's offered work by its actual clock (c_e are expressed at
2.1 GHz); without it ρ assumes the nominal clock.
