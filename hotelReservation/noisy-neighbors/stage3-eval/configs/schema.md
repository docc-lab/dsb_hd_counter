# Stage 3 Aggressor Eval — Per-Experiment YAML Schema

This file documents the YAML config consumed by `stage3-eval.sh`. One
YAML file = one experiment = one orchestrator invocation = N runs of
the same fixed configuration repeated back-to-back for noise reduction.

For sweeps (different RPS, different aggressor mix, different load
shape), write one YAML per sweep point and invoke the orchestrator once
per file. Keeps the orchestrator simple and lets results live in
side-by-side `data/<experiment_id>/` directories.

## Top-level structure

```yaml
experiment:    { ... }   # run-level knobs
testbeds:      { ... }   # per-testbed wrk2 driver (one wrk2 per testbed in scope)
victim:        { ... }   # the service whose ContentionStream we are evaluating
aggressors:    [ ... ]   # heterogeneous list of co-tenants
```

## Loadgen model

There is exactly **one wrk2 driver per testbed** in scope. A testbed is
"in scope" if either (a) the victim lives in it or (b) at least one
aggressor entry references it. The wrk2 driver hits that testbed's
native frontend (e.g. HR's `frontend` service, SN's `nginx-thrift`
service) with its native end-to-end mixed workload, so the victim's
load is whatever flows through the call chain when that wrk2 runs.

This matches the slide deck's "Each testbed handling its native e2e
workload separately, from different wrk2". Consequences:

- **No ghz on the victim.** The pipeline doesn't expose the victim's
  gRPC port via NodePort; it doesn't generate per-method payloads; it
  doesn't talk to the victim directly. All load is e2e via the
  testbed frontend.
- **No per-aggressor `loadgen` block.** Inside a single testbed,
  every colocated aggressor service gets traffic as part of the same
  end-to-end call chain driven by that testbed's wrk2 -- adding a
  separate wrk2 per aggressor would just inflate the testbed's total
  RPS.
- **Cross-testbed setups get N wrk2 drivers in parallel** (HR victim +
  SN aggressor -> 2 wrk2 instances, one per frontend, started together
  at run-start and stopped together at run-end).

## `experiment` block

| Key            | Type   | Default | Notes                                                                                                                  |
|----------------|--------|---------|------------------------------------------------------------------------------------------------------------------------|
| `name`         | string | --      | Human-readable. Surfaced in `per_run.json` for analysis.                                                               |
| `duration_s`   | int    | 300     | Length of one run's measurement window (drivers active).                                                               |
| `warmup_s`     | int    | 30      | After all deployments are ready, sleep this long before run 1 begins. NOT included in any `per_run.json` timestamp.    |
| `cooldown_s`   | int    | 30      | Sleep between consecutive runs. NOT included in timestamps.                                                            |
| `runs`         | int    | 3       | Number of identical runs back-to-back. Each gets its own `runs/run_<n>/` dir.                                          |
| `target_node`  | string | --      | Kubernetes node name. Victim + every aggressor pins here via `nodeSelector`.                                           |

## `testbeds` block (per-testbed wrk2 driver)

A map keyed by testbed name. Every testbed referenced by `victim.testbed`
or any aggressor's `testbed` field MUST appear here.

```yaml
testbeds:
  hotelReservation:
    loadgen: { rps: 200, shape: fixed }
  socialNetwork:
    loadgen:
      rps: 300
      shape: { burst_s: 15, idle_s: 30, peak_rps: 600, base_rps: 100 }
```

| Key                          | Type      | Notes                                                                                                |
|------------------------------|-----------|------------------------------------------------------------------------------------------------------|
| `<testbed>.loadgen.rps`      | int       | Target RPS for the wrk2 driver against this testbed's frontend. `0` = deploy-only: the testbed's pods are deployed and placed, but no driver runs (not allowed for the victim's testbed). |
| `<testbed>.loadgen.shape`    | enum/obj  | `fixed`/`exp`/`norm`/`zipf`, or `{burst_s, idle_s, peak_rps, base_rps}`. See "loadgen.shape" below.   |
| `<testbed>.loadgen.start_offset_s` | int | Optional (default 0). Delay before the driver's first request; it then runs `duration_s - start_offset_s`, so every driver ends together. Must be < `duration_s`. |
| `<testbed>.loadgen.extra`    | obj       | Optional second driver against the same frontend: `{rps, shape, start_offset_s}`. Total rate is base + extra from the offset on (how the phased configs express intrinsic overload). |
| `<testbed>.replicas`         | int       | Optional (default 1). Scale this testbed's **compute** services to N replicas (datastores untouched) so co-located aggressors generate more CPU. **Ignored for `hotelReservation`** (victim testbed left at manifest replicas). |

The orchestrator skips testbeds that aren't in scope (saves cluster
resources). A YAML can keep a testbed config even when no current
aggressor references it -- it'll just be dormant for that experiment.

## `victim` block

| Key                  | Type   | Default | Notes                                                                                                                                          |
|----------------------|--------|---------|------------------------------------------------------------------------------------------------------------------------------------------------|
| `testbed`            | string | --      | Must be `hotelReservation` today (only testbed with `stage3wire.Setup` wired). Must also appear in `testbeds:`.                                |
| `service`            | string | --      | Service name; must match a deployment in `hotelReservation/kubernetes/<service>/`. Today: `search` or `profile`.                               |
| `image`              | string | --      | Full image ref (e.g. `docclabgroup/search-online:v1.2.1`). Built via `ims-build-push-rollout.sh --mode-online`.                                |
| `score_log`          | bool   | false   | Sets `GORDION_SCORE_LOG` in pod env. `false` is recommended for measurement runs (avoids ~10 zerolog lines/sec to stderr).                     |
| `cpu_set`            | string | ""      | CPU list (e.g. `"2,3,4"`) the victim is pinned to with `taskset` inside its container, and that the windowed sampler counts on. Empty = unpinned, counted on every CPU. |

No `loadgen` here: the victim's load is whatever flows through the call
chain when `testbeds.<victim.testbed>.loadgen` runs.

## `aggressors` list

A heterogeneous list -- a single experiment can mix aggressors from
hotelReservation, socialNetwork, and sockshop in any combination, and
every aggressor's `testbed` MUST appear in the `testbeds:` block above.
Each entry is `{testbed, service, role}`:

```yaml
- testbed: hotelReservation         # hotelReservation | socialNetwork | sockshop
  service: geo                      # service-deployment name in the testbed
  role:    good                     # good | bad -- purely informational metadata
```

Semantics:

- The named **service** is pinned to `experiment.target_node` via
  `nodeSelector`. The rest of that testbed runs wherever k8s
  schedules it.
- The service's **load** is whatever flows through it as part of
  `testbeds.<this-testbed>.loadgen`'s end-to-end traffic. We don't
  drive the aggressor service directly.
- The **role** label is informational only -- the pipeline copies it
  verbatim into `per_run.json`. The experimenter sets which
  aggressors are "bad" candidates in the config; the pipeline does
  NOT derive bottleneck service automatically.

There is no synthetic / stress-ng aggressor type -- every aggressor
is a real co-tenant from one of the configured testbeds.

### Mixed-testbed example

```yaml
testbeds:
  hotelReservation: { loadgen: { rps: 200, shape: fixed } }
  socialNetwork:    { loadgen: { rps: 150, shape: fixed } }
  sockshop:         { loadgen: { rps: 100, shape: fixed } }

aggressors:
  - { testbed: hotelReservation, service: profile,      role: bad  }
  - { testbed: hotelReservation, service: geo,          role: good }
  - { testbed: socialNetwork,    service: compose-post, role: bad  }
  - { testbed: sockshop,         service: carts,        role: bad  }
```

The orchestrator deploys all three testbeds, pins the four named
services to the victim's node, and starts three independent wrk2
drivers (one per testbed) for the run window. See
`configs/example-mixed-aggressors.yaml` for a complete working file.

## `loadgen.shape` -- fixed vs bursty

```yaml
loadgen:
  rps: 200
  shape: fixed                      # constant RPS for the whole run

# or:

loadgen:
  rps: 200                          # ignored when shape is the object form
  shape:
    burst_s:  15                    # how long each high-RPS burst lasts
    idle_s:   30                    # gap between bursts (low-RPS mode)
    peak_rps: 600                   # RPS during burst_s
    base_rps: 100                   # RPS during idle_s
```

`lib/wrk2-driver.sh` implements `bursty` as a loop alternating two
`wrk` invocations (simple, gapless within a few ms).

## Integration with mitigation side

After every run, the orchestrator writes `runs/run_<n>/per_run.json`
and at experiment end builds `experiment_manifest.json`. The mitigation
project's eval-report fetcher reads these files; the contract is in
the repo's `README.md` "Integration with mitigation side" section. The
pipeline guarantees that `started_epoch_ns` and `ended_epoch_ns`
bracket only the active driver window (warmup and cooldown excluded),
so a simple `>= started AND <= ended` filter is sufficient.
