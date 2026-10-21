# Stage 3 End-to-End Smoke Test

How to validate the full Stage 3 system from scratch on a real
cluster. Use this whenever a major piece changes (in-pod predictor
image, the aggressor pipeline orchestrator, sockshop manifests, etc.)
and you want a confidence check before running any experiment whose
results matter.

The five phases build on each other; each adds one layer of moving
parts and has explicit verify steps so you know precisely where to
stop and debug if something breaks.

Throughout: `node-3` is the default victim node (matches `target_node`
in `configs/example-*.yaml`). If your cluster's victim is on a different
node, substitute it everywhere the doc mentions `node-3` and override
`experiment.target_node` in the example yamls. Likewise substitute your
registry / image tag references where appropriate.

## What this exercises

| Phase | Layer added | What it proves |
|-------|-------------|----------------|
| 0 | -- | All prerequisites + manifests are in place on the controller |
| 1 | victim only (stage3-predictor branch image) | The in-pod predictor + gRPC publishers work in isolation -- proves the `stage3-predictor` half |
| 2 | aggressor orchestrator (HR-only) | The Stage 3 eval pipeline lifecycle: deploy -> place -> drive -> manifest -- proves the aggressor half |
| 3 | combined: live stream subscribe during a run | Integration contract -- per_run.json's time bracket aligns with the mitigation side's captured streams |
| 4 | cross-testbed (HR + SN + sockshop) | All three testbeds drive in parallel; sockshop integration works |
| 5 | -- | Clean teardown |

## Phase 0 -- Pre-flight (one-time)

Run from a fresh shell on the controller node where the dsb_hd_counter
clone lives.

```bash
cd /path/to/dsb_hd_counter   # adjust to your checkout
git status                   # confirm you're on stage3-predictor
chmod +x hotelReservation/noisy-neighbors/stage3-eval/stage3-eval.sh

# Tools on PATH:
which kubectl yq jq grpcurl helm    # all should resolve

# wrk2 binary built? The orchestrator + this smoke test invoke
# <repo>/wrk2/wrk (matching WRK2_BIN in lib/wrk2-driver.sh).
# hotelReservation/wrk2/ contains only lua scripts -- there is no `wrk`
# there. Build the upstream wrk2 submodule at the repo root:
ls wrk2/wrk 2>/dev/null || (cd wrk2 && make)
ls wrk2/wrk                                              # must exist after this point

# Sockshop manifests landed? (Generated offline via Blueprint; see TODO_SOCKSHOP.md):
ls hotelReservation/noisy-neighbors/stage3-eval/sockshop-manifests/
# Expect 13 dirs: cart_pod, cart_db_pod, ..., zipkin_pod

# Sockshop images pushed to registry?
docker pull docclabgroup/sockshop_frontend_ctr:latest    # should succeed

# Stage 3 victim image pushed to registry?
# (Tag is the source of truth in configs/example-default.yaml under
# victim.image. Phase 1 reads it from there too, so we stay in sync.)
VICTIM_IMAGE=$(yq -r '.victim.image' \
    hotelReservation/noisy-neighbors/stage3-eval/configs/example-default.yaml)
docker pull "$VICTIM_IMAGE"                              # should succeed

# HR + SN testbed source paths reachable (testbed-hr.sh + testbed-sn.sh read them):
ls hotelReservation/kubernetes/                          # HR manifests
ls socialNetwork/helm-chart/socialnetwork/               # SN helm chart
```

If any check fails, fix it before continuing.

## Phase 1 -- In-pod stream wiring sanity (victim only)

Confirms the `stage3-predictor` branch's in-pod gRPC publishers +
ONNX predictor produce events end-to-end. Run this whenever the
victim image changes.

```bash
# 1.1 Deploy a baseline HR cluster with the stage3-predictor search image.
#     If HR's already deployed, just swap the search image. We read the
#     tag from configs/example-default.yaml's victim.image so Phase 1
#     and Phase 2's orchestrator always agree:
VICTIM_IMAGE=$(yq -r '.victim.image' \
    /local/dsb_hd_counter/hotelReservation/noisy-neighbors/stage3-eval/configs/example-default.yaml)
echo "Using victim image: $VICTIM_IMAGE"

kubectl set image deployment/search "hotel-reserv-search=$VICTIM_IMAGE"
kubectl set env  deployment/search ENABLE_WINDOWED_SAMPLING=true GORDION_SCORE_LOG=true
kubectl rollout restart deployment/search
kubectl rollout status  deployment/search --timeout=180s

# 1.2 Confirm the in-pod gRPC publishers came up:
kubectl logs deployment/search | grep -E '(stage3_wired|grpc_serve|score_onnx_started)'
# Expect (in order):
#   "ContentionStream gRPC server listening"   (port 7900)
#   "InstrumentationStream gRPC server listening"  (port 7901)
#   "ONNX score source started"
#   "Stage 3 publishers wired"

# 1.3 Drive a brief workload so the sampler has windows to emit:
TARGET_NODE_IP=$(kubectl get node node-3 -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

# HR's frontend Service ships as ClusterIP; the controller can't hit it
# directly without a NodePort. The Phase 2+ orchestrator promotes it
# automatically (lib/testbed-hr.sh::hr_frontend_url); for this manual
# Phase 1 dry-run we patch it ourselves. Idempotent: no-op if already
# NodePort. Phase 5 has the optional revert.
if [[ "$(kubectl get svc frontend -o jsonpath='{.spec.type}')" != "NodePort" ]]; then
    kubectl patch svc frontend -p '{"spec":{"type":"NodePort"}}'
fi
FRONT_NODEPORT=$(kubectl get svc frontend -o jsonpath='{.spec.ports[0].nodePort}')
[[ -n "$FRONT_NODEPORT" ]] || { echo "ERROR: frontend NodePort not assigned" >&2; return 1 2>/dev/null || exit 1; }
echo "wrk2 target: http://${TARGET_NODE_IP}:${FRONT_NODEPORT}"

# wrk binary lives at <repo>/wrk2/wrk (built in Phase 0); the lua scripts
# live under hotelReservation/wrk2/scripts/. We cd into the scripts dir
# so the relative -s path stays short and matches lib/wrk2-driver.sh.
# 180s gives enough wall-clock for the manual port-forward + grpcurl
# subscribes + log inspection in steps 1.4 / 1.5 below.
cd hotelReservation/wrk2
../../wrk2/wrk -t4 -c20 -d180s -L -R 100 \
      -s scripts/hotel-reservation/mixed-workload_type_1.lua \
      "http://${TARGET_NODE_IP}:${FRONT_NODEPORT}" > /tmp/wrk-phase1.out 2>&1 &
WRK_PID=$!
cd -

# 1.4 In another terminal (or the same one -- wrk is in the background):
#     subscribe to both streams. `kubectl port-forward &` returns before
#     it's actually bound, so wait for the listener before running grpcurl
#     (otherwise you get `connection refused`).
SEARCH_POD=$(kubectl get pods -l io.kompose.service=search -o jsonpath='{.items[0].metadata.name}')

kubectl port-forward "$SEARCH_POD" 7900:7900 > /tmp/pf_score.log 2>&1 &
PF_SCORE=$!
until ss -ltn 'sport = :7900' 2>/dev/null | grep -q LISTEN; do sleep 0.2; done
grpcurl -plaintext -d '{}' localhost:7900 \
        gordion.contention.ContentionStream/Subscribe | head -5
# Expect: 5 ScoreEvent JSON objects with sample_id, timestamp_ns,
# service="search", p50_trend_pred, tail_trend_label, model_version,
# source_kind="onnx".
kill $PF_SCORE 2>/dev/null

kubectl port-forward "$SEARCH_POD" 7901:7901 > /tmp/pf_sample.log 2>&1 &
PF_SAMPLE=$!
until ss -ltn 'sport = :7901' 2>/dev/null | grep -q LISTEN; do sleep 0.2; done
grpcurl -plaintext -d '{}' localhost:7901 \
        gordion.instrumentation.InstrumentationStream/Subscribe | head -3
# Expect: 3 Sample JSON objects with sample_id, perf_counters{...},
# freq{actual_freq_mhz, freq_util_pct, ...}, timing_window{...}.
kill $PF_SAMPLE 2>/dev/null

# 1.5 Also confirm scores are in kubectl logs (GORDION_SCORE_LOG=true).
#     HR services log via zerolog.ConsoleWriter (human-readable, NOT JSON --
#     see cmd/search/main.go), so grep, don't jq. The unique message body
#     for ScoreEvent emissions is "score_event" (distinct from
#     "score_grpc_serve" / "score_onnx_started" / "score_subscribe" / etc.):
kubectl logs "$SEARCH_POD" --since=2m | grep 'score_event' | head -5
# Expect: 5 lines like
#   ... INF ... > score_event event=score service=search sample_id=... \
#       p50_trend_pred=... tail_trend_label=... model_version=... source_kind=onnx

kill $WRK_PID 2>/dev/null
wait $WRK_PID 2>/dev/null || true
```

Stop here if any check fails. Common failures:

- `score_onnx_run_error` in logs -> ONNX runtime issue; check `GORDION_MODEL` path resolved inside the pod.
- `freq.ok=false` in every Sample -> MSR module not loaded on `node-3`; `ssh node-3 'sudo modprobe msr'`.
- No streams at all -> image didn't get `stage3wire.Setup` wired; `kubectl describe deployment/search` and check env vars (`ENABLE_WINDOWED_SAMPLING=true`, `GORDION_SCORE_SOURCE=onnx` or `GORDION_MODEL` set).

## Phase 2 -- Aggressor pipeline dry-run (HR-only, no stream subscribe)

Validates the orchestrator's lifecycle without sockshop or SN.

```bash
cd /path/to/dsb_hd_counter/hotelReservation/noisy-neighbors/stage3-eval

# 2.1 Shrink the run for a fast smoke (60s/run, 1 run), keep score_log on
# for kubectl-logs cross-check. The example yaml ships with
# target_node: node-3 (same node Phase 1 used); only edit it if your
# cluster's victim node is different:
#   yq -i '.experiment.target_node = "<your-node>"' configs/example-default.yaml
yq -i '.experiment.duration_s = 60 |
       .experiment.warmup_s   = 10 |
       .experiment.cooldown_s = 10 |
       .experiment.runs       = 1 |
       .victim.score_log      = true' configs/example-default.yaml

# 2.2 Run:
./stage3-eval.sh configs/example-default.yaml 2>&1 | tee /tmp/stage3-eval-phase2.log

# Expected output sequence: parse config -> preflight -> determine testbeds
# (HR only) -> prep msr -> deploy testbeds -> deploy victim -> place aggressors
# (geo + profile) -> Consul recovery (clean stale srv-* + bounce frontend)
# -> warmup -> run 1/1 -> write manifest -> cleanup trap.
```

After it finishes:

```bash
# 2.3 Inspect the experiment dir:
EXP_DIR=$(ls -td data/stage3eval_* | head -1)
ls "$EXP_DIR/"
# Expect: experiment_manifest.json, input.yaml, metadata/, logs/, runs/

# 2.4 Inspect per_run.json:
cat "$EXP_DIR/runs/run_1/per_run.json" | jq
# Verify:
#   - victim.pod is a non-empty pod name (live resolution worked)
#   - aggressors[] has 2 entries with .pod populated
#   - ended_epoch_ns - started_epoch_ns is approximately duration_s * 1e9
#   - testbed_loadgens.hotelReservation = {rps: 200, shape: "fixed"}
#   - artifacts.wrk2_outputs.hotelReservation points at a real file

# 2.5 Verify wrk2 output looks healthy:
cat "$EXP_DIR/runs/run_1/wrk2/hotelReservation.txt" | tail -15
# Expect: latency distribution, requests/sec near target rps.

# CRITICAL assertion: the Consul recovery step (clean stale srv-* +
# bounce frontend) is supposed to keep error rate at 0. If "Non-2xx or
# 3xx responses: <high count>" is present, recovery didn't take and you
# almost certainly have stale Consul registrations or a stuck grpc
# resolver. See troubleshooting row "all wrk2 responses Non-2xx".
NON2XX=$(grep -oE 'Non-2xx or 3xx responses: *[0-9]+' \
    "$EXP_DIR/runs/run_1/wrk2/hotelReservation.txt" \
    | grep -oE '[0-9]+$' || echo 0)
TOTAL=$(grep -oE '[0-9]+ requests in' \
    "$EXP_DIR/runs/run_1/wrk2/hotelReservation.txt" \
    | grep -oE '^[0-9]+' || echo 0)
echo "wrk2: $NON2XX non-2xx out of $TOTAL"
# Expect: 0 or a tiny single-digit count. If >1% of total, stop and
# debug Consul state before continuing to Phase 3.

# 2.6 Confirm aggressors actually colocated on target_node:
kubectl get pods -o wide | grep -E '(search|geo|profile)'
# All three should be on the same node as TARGET_NODE.
```

Common failures:

- `step1_expose_nodeport not found` -> orchestrator's source of `../stage1-characterization/step1-characterize.sh` failed; check the script exists.
- `place_aggressor failed` -> service doesn't exist; `kubectl get deployment geo profile`.
- `wrk2 binary not found` -> ensure `../../../wrk2/wrk` is built and executable.

## Phase 3 -- Stream + aggressor combined (HR-only)

Correlate: while the orchestrator runs aggressors, manually subscribe to
ContentionStream to confirm score events flow during the configured
time window. This simulates the mitigation side's eval-report fetcher
contract.

```bash
# 3.1 Lengthen duration so you have time to subscribe + observe trends:
yq -i '.experiment.duration_s = 180 | .experiment.runs = 1' configs/example-default.yaml

# 3.2 Start the orchestrator in the background:
./stage3-eval.sh configs/example-default.yaml > /tmp/stage3-phase3.log 2>&1 &
ORCH_PID=$!

# 3.3 Wait through warmup before subscribing:
sleep 60
SEARCH_POD=$(kubectl get pods -l io.kompose.service=search -o jsonpath='{.items[0].metadata.name}')

# 3.4 Subscribe to ContentionStream and tee to file. NOTE: keep
# timestampNs as a STRING here (don't tonumber it) -- jq's doubles can't
# hold a 19-digit ns value exactly. We convert only at compare time in
# 3.5.
kubectl port-forward "$SEARCH_POD" 7900:7900 > /dev/null 2>&1 &
PF_SCORE=$!
grpcurl -plaintext -d '{}' localhost:7900 \
        gordion.contention.ContentionStream/Subscribe \
  | jq -c '{t: .timestampNs, p50: .p50TrendPred, tail: .tailTrendLabel}' \
  | tee /tmp/stage3-scores.jsonl
# Ctrl-C this once the orchestrator finishes. Ctrl-C usually truncates
# the final line mid-write; that's harmless -- jq processes the complete
# lines and just prints a "parse error ... at EOF" for the last one.

kill $PF_SCORE 2>/dev/null
wait $ORCH_PID
tail -30 /tmp/stage3-phase3.log

# 3.5 Verify time bracket alignment (mitigation-side fetcher contract).
# .t is a JSON string ("1781..."), so we must (.t|tonumber) before
# comparing -- otherwise jq orders string > number unconditionally and
# the bracket select silently returns 0. 2>/dev/null swallows the EOF
# parse error from the Ctrl-C-truncated last line.
EXP_DIR=$(ls -td data/stage3eval_* | head -1)
START_NS=$(jq -r '.started_epoch_ns' "$EXP_DIR/runs/run_1/per_run.json")
END_NS=$(jq -r '.ended_epoch_ns'     "$EXP_DIR/runs/run_1/per_run.json")
echo "Run window: $START_NS .. $END_NS"

jq -c "select((.t|tonumber) >= $START_NS and (.t|tonumber) <= $END_NS)" \
   /tmp/stage3-scores.jsonl 2>/dev/null | wc -l
# Expect: a healthy fraction of your captured events fall inside the
# bracket. Score events arrive roughly once per closed sampling window,
# so the exact count depends on WINDOW_INTERVAL_MS and how much of the
# run you captured -- the point is that the count is non-zero and most
# of your tee'd events land within [START_NS, END_NS].

# 3.6 Score distribution sanity:
jq -r '"\(.p50)\t\(.tail)"' /tmp/stage3-scores.jsonl 2>/dev/null \
  | awk 'BEGIN{p50_sum=0; tail_sum=0; n=0}
         {p50_sum+=$1; tail_sum+=$2; n++}
         END{printf "n=%d p50_mean=%.3f tail_mean=%.3f\n", n, p50_sum/n, tail_sum/n}'
# Numbers in [0, 1]; higher = more predicted contention. If both are ~0.0
# across the whole run, either aggressors aren't causing real contention
# (raise rps) or the model isn't trained for this scenario (expected for
# the bootstrap GRU prototype).
```

## Phase 4 -- Cross-testbed end-to-end (HR + SN + sockshop)

The full payload: all three testbeds drive traffic in parallel, sockshop
included.

```bash
# 4.1 Shorten duration for the smoke. example-mixed-aggressors.yaml also
# ships with target_node: node-3; override only if needed:
#   yq -i '.experiment.target_node = "<your-node>"' configs/example-mixed-aggressors.yaml
yq -i '.experiment.duration_s = 120 | .experiment.runs = 1' configs/example-mixed-aggressors.yaml

# 4.2 Run:
./stage3-eval.sh configs/example-mixed-aggressors.yaml 2>&1 | tee /tmp/stage3-phase4.log

# Watch for these orchestrator log lines (in order):
#   "Driven testbeds: hotelReservation socialNetwork sockshop"
#   "Deploying 3 testbed(s)"
#   "Placing 4 aggressor(s) on <node>"   (HR profile + HR geo + SN compose-post + SS carts)
#   "Warmup..."
#   "driver: hotelReservation rps=200 ..."
#   "driver: socialNetwork rps=150 ..."
#   "driver: sockshop rps=100 ..."
#   "Drivers active; sleeping 120s ..."
#   "Run 1 complete (...ms)"
```

After it finishes:

```bash
# 4.3 Inspect the manifest:
EXP_DIR=$(ls -td data/stage3eval_* | head -1)

jq '.testbed_loadgens' "$EXP_DIR/runs/run_1/per_run.json"
# Expect 3 keys (hotelReservation, socialNetwork, sockshop), each with rps + shape.

jq '.aggressors | length' "$EXP_DIR/runs/run_1/per_run.json"
# Expect: 4

jq '.aggressors[] | {testbed, service, pod, node}' "$EXP_DIR/runs/run_1/per_run.json"
# Verify all four aggressors got their pod resolved and node == target_node.

# 4.4 Each wrk2 driver actually produced output:
ls "$EXP_DIR/runs/run_1/wrk2/"
# Expect: hotelReservation.txt, socialNetwork.txt, sockshop.txt

for tb in hotelReservation socialNetwork sockshop; do
    echo "=== $tb wrk2 summary ==="
    grep -E '(Requests/sec|Latency Distribution|errors)' \
         "$EXP_DIR/runs/run_1/wrk2/$tb.txt" | head -10
done
# Each should show ~the configured RPS achieved with few/no errors.

# 4.5 If you also subscribed to streams (Phase 3 method) during this phase,
# you should see *higher* contention scores than in Phase 3 due to
# cross-testbed pressure on the victim's node.
```

## Phase 5 -- Cleanup

```bash
# Revert YAML edits if you want a clean git diff:
cd /path/to/dsb_hd_counter
git checkout hotelReservation/noisy-neighbors/stage3-eval/configs/

# The orchestrator's cleanup trap (stage3-eval.sh::cleanup_trap ->
# hr_teardown / sn_teardown / ss_teardown) resets HR deployment
# nodeSelector + tolerations to a clean scheduling state, stops wrk2
# drivers, and unplaces aggressors. It deliberately does NOT:
#   - revert the search Deployment's image (kubectl set image from
#     Phase 1.1) -- next run overrides it again.
#   - revert frontend Service NodePort -> ClusterIP (patched in
#     Phase 1.3 / by hr_frontend_url) -- patch is idempotent.
#   - delete aggressor namespaces (aggressor-sn, aggressor-ss) -- next
#     run reuses them so startup is faster.
#
# If you want a fully clean cluster (rare; only do this when fully
# done with this checkout):
#
#   # Restore search image to whatever your HR baseline uses:
#   kubectl set image deployment/search \
#       hotel-reserv-search=docclabgroup/search:<baseline-tag>
#
#   # Revert frontend Service to ClusterIP:
#   kubectl patch svc frontend --type=json \
#       -p='[{"op":"replace","path":"/spec/type","value":"ClusterIP"}]'
#
#   # Tear down aggressor namespaces (will re-deploy on next run):
#   kubectl delete namespace aggressor-ss   # sockshop
#   kubectl delete namespace aggressor-sn   # socialNetwork

# Periodically prune accumulated experiment data:
#   rm -rf hotelReservation/noisy-neighbors/stage3-eval/data/stage3eval_2026*
```

## Troubleshooting cheat sheet

| Symptom | Most likely cause | Fix |
|---------|-------------------|-----|
| `score_onnx_run_error` repeatedly in victim logs | ONNX model path wrong / missing | `kubectl exec <victim-pod> -- ls /etc/gordion/` to verify model present; check `GORDION_MODEL` env |
| `freq.ok=false` on every Sample | `msr` kernel module not loaded on target node | `ssh node-3 'sudo modprobe msr'` |
| `place_aggressor failed for <ns>/<deploy>` | Aggressor service not deployed yet | Confirm `kubectl get deployment` lists it in the right namespace |
| Sockshop pods in `ImagePullBackOff` | Image not pushed or wrong registry path | `docker pull docclabgroup/sockshop_<svc>_ctr:latest` from controller; if fails, re-push |
| `search` pod `ImagePullBackOff` / `manifest unknown` for victim tag | `victim.image` tag in yaml doesn't exist on the registry | `docker manifest inspect "$(yq -r '.victim.image' configs/example-default.yaml)"`; if it fails, edit the yaml to a tag that exists (`docker search` / Docker Hub) and re-run |
| Sockshop pods `CrashLoopBackOff` | Bad config / dependency unavailable | `kubectl -n aggressor-ss logs <pod>` |
| `helm install` hangs at SN deploy | SN chart's `--wait` timeout reached | `kubectl -n aggressor-sn get pods` to find the stuck one |
| Orchestrator hangs at "Waiting for placed aggressors to be Ready" | One aggressor stuck Pending (no resources, no node match) | `kubectl describe pod <stuck>` |
| `kubectl logs` returns nothing for scores | `GORDION_SCORE_LOG` not true OR no LogSink configured | `kubectl set env deployment/<victim> GORDION_SCORE_LOG=true && kubectl rollout restart deployment/<victim>` |
| `grpcurl` returns nothing | Streams not running OR port-forward not active | Check victim logs for `grpc_serve` startup messages; verify port-forward PID alive |
| `grpcurl: connection refused` immediately after `kubectl port-forward &` | Port-forward race: listener not bound yet | `until ss -ltn 'sport = :7900' \| grep -q LISTEN; do sleep 0.2; done` (or `nc -z localhost 7900`) before `grpcurl` |
| `wrk: invalid URL: http://<ip>:` (Phase 1) | `frontend` Service is ClusterIP; `.spec.ports[0].nodePort` is empty | `kubectl patch svc frontend -p '{"spec":{"type":"NodePort"}}'`, then re-resolve `FRONT_NODEPORT` |
| `./wrk: No such file or directory` from `hotelReservation/wrk2` | `wrk` binary not built (or built in the wrong wrk2 dir) | `cd <repo>/wrk2 && make`; invoke as `<repo>/wrk2/wrk` (or `../../wrk2/wrk` from `hotelReservation/wrk2`) |
| `jq: parse error: Invalid numeric literal at line 1, column 2` on `kubectl logs` | HR services log via `zerolog.ConsoleWriter` (human-readable, not JSON) | Use `grep 'score_event'` instead of `jq -c 'select(.event=="score")'` |
| All wrk2 responses Non-2xx (Phase 2+); frontend logs `[Consul resolver] bad resolver state` | Stale `srv-*` registrations from prior rolls; grpc-consul resolver in frontend hasn't re-resolved | Orchestrator now runs `recover_consul_state` (clean stale + bounce frontend) before warmup. If you still see this: `kubectl logs deployment/frontend \| grep 'Consul resolver'`, then manually `clean_stale_consul_services "$EXP_DIR" && kubectl rollout restart deployment/frontend` and re-run |
| `wait $ORCH_PID` returns 150; `tail -1 /tmp/stage3-phase3.log` is stuck on a `kubectl exec` line | Background orchestrator hit `SIGTTOU` (`128+22=150`) because a helper used `kubectl exec -it`; the `-t` requires a TTY which `&` removes | `kill -9 $ORCH_PID`, manually unpin (`kubectl patch deployment {search,geo,profile} --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":null,"tolerations":null}}}}'`), then re-run. The orchestrator's own recovery is now TTY-safe; if a 3rd-party helper is involved, drop the `-t` flag |
| Phase 3.5 bracket count is 0 but events clearly streamed | `.t` (`timestampNs`) is a JSON string; jq orders string > number unconditionally, so a bare `.t >= START_NS` filter excludes everything | Convert at compare time: `select((.t\|tonumber) >= $START_NS and (.t\|tonumber) <= $END_NS)` |
| `jq: parse error: Invalid literal at EOF` on `/tmp/stage3-scores.jsonl` | Ctrl-C truncated the last streamed line mid-write | Harmless -- complete lines still process. Append `2>/dev/null`, or drop the last line: `head -n -1 /tmp/stage3-scores.jsonl` |
| Empty `experiment_manifest.json` | All runs failed before reaching `write_run_manifest` | Check `logs/stage3-eval.log` for the actual failure |

## What this does NOT validate

- **Mitigation side's eval-report fetcher** -- a separate codebase. This
  smoke test only manually simulates the contract via grpcurl + jq.
- **Per-run reproducibility / cross-run statistical significance** --
  these phases use `runs: 1` for speed. Run with `runs: 3` minimum
  before drawing any quantitative conclusions.
- **Bursty shape correctness** -- the example configs use `shape: fixed`.
  Test `shape: { burst_s, idle_s, peak_rps, base_rps }` separately by
  editing one of the example YAMLs.
- **Score quality vs ground truth** -- whether the model's predictions
  are *meaningful* under the configured aggressor pressure. That's an
  eval research question, not a smoke test.
