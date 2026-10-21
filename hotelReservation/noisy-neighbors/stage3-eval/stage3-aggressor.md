# Stage 3 Aggressor + Evaluation Pipeline

This pipeline is the aggressor-side of the Stage 3 evaluation. It
deploys configurable co-tenant aggressors next to a Stage-3-wired
victim, drives **each in-scope testbed with one wrk2 instance hitting
its native frontend** (the same end-to-end mixed workload the testbed
ships with — `mixed-workload_type_1.lua` for HR, `mixed-workload.lua`
for SN), and writes one tiny per-run metadata JSON per run. Stream
capture and any analysis live in the mitigation-side project (see
"Integration with mitigation side" below).

> **Branch:** `stage3-predictor` — the in-pod publishers + ONNX
> predictor this pipeline targets are only present on that branch.

## Quick start

```bash
# From hotelReservation/noisy-neighbors/stage3-eval/
./stage3-eval.sh configs/example-default.yaml
```

Output lands in `data/<experiment_id>/`. Each run gets its own
`runs/run_<n>/` directory; the experiment ends by writing
`experiment_manifest.json` (one JSON array listing every per-run
manifest).

Throughout this doc, **"the orchestrator"** refers to the
`stage3-eval.sh` script -- the single entrypoint that parses the
YAML, deploys testbeds, places aggressors, runs the per-run loop,
and writes manifests.

## Prerequisites

- Linux dev/controller host with `kubectl` configured against the target
cluster (`kubectl get nodes` should work).
- The `stage3-predictor` branch is the active branch and the victim
image (`docclabgroup/<svc>-online:<tag>`) has been built and pushed
via `../../ims-build-push-rollout.sh --mode-online`.
- Tools on PATH: `yq` (mikefarah v4+), `jq`, `wrk` (the wrk2 build at
`../../../wrk2/wrk`), `helm` (only if SN aggressors used), and an
SSH route to the worker node for the one-time `modprobe msr` inside
`ensure_msr_module_on_node`. `**ghz` is no longer required.**
- A worker node identified by `experiment.target_node` in the YAML —
this is where the victim and any colocated aggressors will run.

## Loadgen model

There is **one wrk2 driver per in-scope testbed**, hitting that
testbed's frontend with its native mixed end-to-end workload. A testbed
is "in scope" if (a) the victim lives in it, or (b) at least one
aggressor entry references it.


| Scenario                                  | wrk2 instances                    | What each does                                              |
| ----------------------------------------- | --------------------------------- | ----------------------------------------------------------- |
| HR victim + HR aggressors only            | 1 (against HR frontend)           | Drives the victim AND its HR co-tenants via the call chain. |
| HR victim + SN aggressors                 | 2 (HR frontend + SN nginx-thrift) | HR wrk2 drives victim; SN wrk2 drives SN aggressor.         |
| HR victim + HR + SN + sockshop aggressors | 3 (one per testbed)               | One independent wrk2 per testbed, all running in parallel.  |


Consequences vs the earlier ghz-on-victim design:

- **No ghz, no NodePort on victim, no per-method payload generators.**
The pipeline never talks to the victim's gRPC port directly.
- `**loadgen` lives only under `testbeds:`** in the YAML. There is no
per-aggressor or per-victim `loadgen` block — they'd just inflate
the testbed's total RPS.
- **HDR-style latency for the victim** comes from the wrk2 output of
the victim's testbed (the same file every other co-tenant in that
testbed shares). It's not a victim-only signal; it's the end-to-end
user-visible latency of the testbed under the configured aggressor
load.

See `[configs/schema.md](configs/schema.md)` "Loadgen model" for the
canonical version of this rationale.

## What the pipeline does (and doesn't) do

In scope:

- deploy testbeds in scope (HR is always deployed if the victim lives
there; other testbeds only when their aggressor count > 0);
- swap the victim image to the configured stage3-predictor build; set
`GORDION_SCORE_LOG` per YAML; patch MSR pod capabilities; pin to
`target_node` via nodeSelector + toleration; trigger a rollout;
- place each aggressor on the victim's node via the same nodeSelector
  - toleration patch. Aggressor entries from different testbeds
  (HR + SN + sockshop) can be mixed freely in a single `aggressors:`
  list;
- start one wrk2 driver per in-scope testbed (`fixed` or `bursty`
shape) -- each driver runs in its own background process on the
controller, hitting that testbed's frontend in parallel with the
others. The orchestrator then sleeps for `duration_s` while
drivers run, and SIGTERMs them all when the window ends;
- write `runs/run_<n>/per_run.json` and `experiment_manifest.json`.

Explicitly NOT in scope (mitigation-side codebase's job):

- subscribing to `:7900` (ContentionStream) or `:7901`
(InstrumentationStream);
- persisting captured `ScoreEvent` / `Sample` streams;
- joining streams with this pipeline's metadata or producing an
analysis report.

The pipeline is deliberately narrow because the eval research
questions are not finalized — locking analysis in here would force
re-implementing the pipeline every time the questions shift. The
manifest contract below is the integration point.

## Integration with mitigation side

After every run, the orchestrator writes:

```
data/<experiment_id>/runs/run_<n>/per_run.json
```

and at experiment end:

```
data/<experiment_id>/experiment_manifest.json     # JSON array of per_run.json
```

`per_run.json` schema (v1):


| Field              | Type   | Notes                                                                                                        |
| ------------------ | ------ | ------------------------------------------------------------------------------------------------------------ |
| `schema_version`   | int    | Currently `1`. Bump when the schema changes incompatibly.                                                    |
| `run_id`           | int    | 1-based index within the experiment.                                                                         |
| `experiment_id`    | string | Same as the parent directory name (e.g. `stage3eval_20260616_181230_a4f9`).                                  |
| `experiment_name`  | string | From `experiment.name` in the input YAML.                                                                    |
| `config_snapshot`  | object | Full input YAML inlined as JSON; self-contained provenance.                                                  |
| `started_epoch_ns` | int64  | Host wall-clock when wrk2 drivers go (warmup excluded).                                                      |
| `ended_epoch_ns`   | int64  | Host wall-clock when wrk2 drivers stop (cooldown excluded).                                                  |
| `target_node`      | string | Kubernetes node name; victim + colocated aggressors are pinned here.                                         |
| `victim`           | object | `{service, image, pod, node, testbed, score_log_enabled}`. No `nodeport` (the pipeline doesn't expose one).  |
| `aggressors`       | array  | One element per aggressor entry. No `loadgen` field per entry — see `testbed_loadgens` instead.              |
| `testbed_loadgens` | object | Per-testbed wrk2 config in effect during this run, e.g. `{"hotelReservation": {"rps":200,"shape":"fixed"}}`. |
| `artifacts`        | object | `{wrk2_outputs: {<testbed>: <relpath>}}`. Paths are relative to `data/<experiment_id>/`.                     |


Each `aggressors[i]`:

```json
{
  "testbed":    "hotelReservation",
  "service":    "geo",
  "role":       "good",
  "namespace":  "default",
  "deployment": "geo",
  "pod":        "geo-7c9f-abc",
  "node":       "node-3"
}
```

`service` is the service that gets pinned to the victim's node; the
rest of that testbed schedules wherever k8s puts it. `deployment` is
the resolved k8s deployment name in `namespace` (some testbeds have
mappings that differ from the human-friendly service name, e.g. HR
`recommendation` → deployment `reccomend`).

### Fetcher contract

Whatever the mitigation-side eval-report fetcher is, its job is:

1. Walk `data/<experiment_id>/experiment_manifest.json` (or each
  `runs/run_<n>/per_run.json` directly).
2. For each run, slice the mitigation side's own captured
  `scores.jsonl` / `samples.jsonl` (grabbed live via gRPC subscribe
   on `:7900` / `:7901`) by `[started_epoch_ns, ended_epoch_ns]`.
3. Optionally pull in `artifacts.wrk2_outputs.<victim.testbed>` for
  end-to-end HDR latency of the victim's testbed.
4. Use `testbed_loadgens` and `aggressors[]` to know the active
  experimental condition for the time window.
5. Produce whatever analysis the finalized research questions call for.

The pipeline guarantees `started_epoch_ns` and `ended_epoch_ns`
bracket only the active wrk2 driver window — warmup before run 1
and cooldown between runs are excluded. So a simple `>= started AND <= ended` filter is sufficient; the mitigation side never has to
re-derive run boundaries from log timestamps.

## YAML config schema

See `[configs/schema.md](configs/schema.md)` for the canonical schema.

- `[configs/example-default.yaml](configs/example-default.yaml)` —
starter template: HR-only experiment with `search` victim plus one
good (`geo`) and one bad (`profile`) HR aggressor, all three sharing
a single HR wrk2 driver. Copy + edit this for your own experiments;
it is not intended as a baseline comparison point.
- `[configs/example-mixed-aggressors.yaml](configs/example-mixed-aggressors.yaml)` —
Cross-testbed experiment: `search` victim with aggressors drawn from
HR + socialNetwork (+ sockshop once that testbed lands), demonstrating
the heterogeneous aggressor list and one-wrk2-per-testbed model.

For sweeps, write one YAML per sweep point and invoke the orchestrator
once per file. This keeps the orchestrator simple and lets results
live in side-by-side `data/<experiment_id>/` dirs.

## Score logging recommendation

For measurement-cleanliness runs, set `victim.score_log: false` in
the YAML (the default in `example-default.yaml`). This pins
`GORDION_SCORE_LOG=false` in the victim pod env so the in-binary
`score.LogSink` stops writing one zerolog line per ScoreEvent
(~10 lines/sec). The mitigation gRPC subscriber on `:7900` still
gets the full stream — the LogSink is only valuable for
ad-hoc `kubectl logs` smoke checks when nothing is subscribed.

Leave it `true` for dev / sanity-check runs where you don't have a
subscriber attached.

## Layout produced per experiment

```
data/<experiment_id>/
├── experiment_manifest.json     # built at experiment end (JSON array of per_run.json)
├── input.yaml                   # copy of the input config
├── metadata/
│   ├── aggressors.json          # full aggressors[] from the input YAML
│   └── testbeds.json            # full testbeds{} from the input YAML
├── logs/
│   ├── stage3-eval.log          # orchestrator timeline
│   ├── testbed-hr.log
│   ├── testbed-sn.log           # only if SN used
│   ├── collector.log            # from sourced ../data-collector.sh
│   └── step1.log                # from sourced ../stage1-characterization/step1-characterize.sh
└── runs/
    └── run_<n>/
        ├── per_run.json         # THE integration point for the mitigation side
        ├── started_epoch_ns.txt # plain text mirror for shell pipelines
        ├── ended_epoch_ns.txt
        ├── orchestrator.log     # per-run pipeline log
        └── wrk2/
            ├── <testbed>.txt    # one per in-scope testbed (e.g. hotelReservation.txt)
            └── <testbed>.pid    # ephemeral; cleaned up after run
```

## Adding a testbed

If you ever wire up a fourth testbed (sockshop will be the third when
its Blueprint info lands), follow the same shape as
`lib/testbed-hr.sh` / `lib/testbed-sn.sh`:


| Function                           | Contract                                                                                                                                 |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `<x>_deploy <exp_dir>`             | Idempotent deploy of the testbed into `$<X>_NAMESPACE`. Logs to `$exp_dir/logs/testbed-<x>.log`.                                         |
| `<x>_teardown <exp_dir>`           | Soft reset: strip `nodeSelector` / `tolerations` from every deployment. Leave the testbed deployed so subsequent experiments start fast. |
| `<x>_uninstall <exp_dir>`          | Full uninstall + namespace delete. Only invoked when the user passes `--uninstall-<x>` to `stage3-eval.sh`.                              |
| `<x>_frontend_url <target_node>`   | Promote frontend svc to NodePort, echo `http://<node-ip>:<nodeport>` (wrk2 hits this).                                                   |
| `<x>_deployment_for_service <svc>` | Map a human service name (used in YAML) to the actual deployment name.                                                                   |
| `<x>_pod_for_deployment <deploy>`  | Echo the first Running pod for the deployment (for live identity in `per_run.json`).                                                     |


Then add an entry to `WRK2_TESTBED_SCRIPT` in `lib/wrk2-driver.sh`
pointing at the testbed's wrk2 lua script, and register the testbed
in `stage3-eval.sh`'s `_resolve_ns` / `_resolve_deploy` / `_resolve_pod`
/ `_resolve_frontend_url` dispatch functions plus the `deploy_testbeds`
`case`.

## Cleanup behavior

The orchestrator installs an `EXIT/INT/TERM` trap that:

1. Kills any leftover wrk2 driver process groups;
2. Reverts every `nodeSelector` / `toleration` it placed on aggressors;
3. Runs `<testbed>_teardown` (soft reset) for each in-scope testbed
  (or `sn_uninstall` if `--uninstall-sn` was passed).

So Ctrl-C mid-experiment leaves no stuck workloads on the wrong node;
the worst it does is leave one partially-written `per_run.json` (the
last run's directory still has its raw wrk2 output and timestamps).

## Troubleshooting

- `**yq` validation errors at startup:** ensure you have mikefarah's
Go yq v4+ (not the Python wrapper).
- **wrk2 can't reach HR/SN frontend:** check `kubectl get svc -A`
for the NodePort assigned to `frontend` (HR, default ns) or
`nginx-thrift` (SN, `aggressor-sn` ns). On RHEL/OpenShift the
cluster firewall typically only opens 30000-32767 — auto-allocated
NodePorts in that range work; outside it, traffic silently drops.
- `**freq.ok == false` in every Sample:** MSR module not loaded on
the worker. The orchestrator runs `modprobe msr` over SSH at
startup, but if SSH access isn't configured the in-pod sampler
silently produces `freq.ok=false` for every window. Fix:
`ssh <target_node> 'sudo modprobe msr'` and re-run.
- **socialNetwork helm install hangs:** the chart's `--wait` will
block until every pod is Ready (5 min default). If SN is genuinely
failing to come up, `kubectl -n aggressor-sn get pods` shows
per-pod failures.
- **Stuck aggressor pods after Ctrl-C:** the trap usually catches
these. If not, `kubectl -n <ns> patch deployment <d> --type='merge' -p '{"spec":{"template":{"spec":{"nodeSelector":null,"tolerations":null}}}}'`
per stuck deployment, then `kubectl rollout restart deployment <d>`.

## Follow-ups

- **Mitigation-side eval-report fetcher (separate codebase):**
implement the fetcher described in "Integration with mitigation
side" against `experiment_manifest.json`. The pipeline's
guarantees on the time-window contract are documented above.
- **Sockshop testbed:** `lib/testbed-ss.sh` is a stub; see
`[TODO_SOCKSHOP.md](TODO_SOCKSHOP.md)`.
- **Additional victim services beyond `search` and `profile`:** the
pipeline assumes `lib/testbed-hr.sh`'s `HR_SERVICE_TO_DEPLOYMENT`
contains the victim, and the service has `stage3wire.Setup(...)` in
its `cmd/<svc>/main.go` (currently only `search` and `profile` are
wired — see `STAGE3.md`). No payload-generator setup is needed
anymore since the pipeline drives wrk2 against the testbed frontend,
not ghz against the service's gRPC port.

