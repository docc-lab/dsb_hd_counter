# TODO: Sockshop integration

`lib/testbed-ss.sh` is currently a stub. Every entrypoint exits with a
loud error referencing this file, so any experiment YAML that includes
`{testbed: sockshop}` fails fast rather than silently succeeding
without actually deploying sockshop.

## Status (2026-06): smoke test passed, **Path 1 chosen**

We smoke-tested upstream Blueprint's `plugins/kubernetes/` against
sockshop and confirmed it produces deployment-ready Kubernetes
manifests. End-to-end result:

- ✓ `examples/sockshop/wiring/specs/kubernetes.go` authored, uses the
  plugin via `kubepod.NewKubePod` directly (workaround for an upstream
  API bug; see "Upstream gaps" below).
- ✓ All 13 pods (7 services + 5 DBs + zipkin) emit `deployment.yaml`
  + `service.yaml` with correct images, ports, env vars, hostname,
  and namespace stamping.
- ✓ All 26 manifests pass `kubectl apply --dry-run=server` against a
  real cluster, in a configurable namespace via
  `BLUEPRINT_K8S_NAMESPACE` env var.

**Decision: Path 1 (upstream Blueprint `plugins/kubernetes/`) is the
sockshop integration path.** Paths 2 and 3 (docc-lab `d2k8s` and
archived `microservices-demo` respectively) are dropped.

## Canonical "regenerate sockshop manifests" workflow

Every time you bump the Blueprint sockshop version (or the docc-lab
fork's plugin changes), repeat this exact sequence. Every step has a
known wrinkle worth documenting so the next person doesn't re-discover
them.

### 0. Prerequisites

- Blueprint clone with the docc-lab fork's three k8s patches applied
  (the `prod/sockshop-k8s` branch from `docc-lab/blueprint-docc-mod`,
  or upstream `kubernetes` branch + the three local patches: tab fix,
  namespace support, K8sName sanitization).
- `protoc` + `protoc-gen-go` + `protoc-gen-go-grpc` on PATH.
- Docker daemon + `docker login` to `docclabgroup`. User in the
  `docker` group, or use `sudo`.

### 1. Compile sockshop with the kubernetes wiring spec

```bash
cd "$BLUEPRINT_ROOT/examples/sockshop/wiring"
rm -rf build
go run main.go -o build -w kubernetes
# Note: don't set BLUEPRINT_K8S_NAMESPACE -- we strip namespaces in
# step 4 anyway, so leaving it unset keeps the manifests portable.
```

### 2. Patch the generated Dockerfiles + go.work files

Two upstream codegen bugs need post-process workarounds (until docc-lab
PR #3 lands on the `kubernetes` branch):

```bash
# 2a. Dockerfile bases golang:1.24-bookworm but go.work needs >= 1.25.
#     Bump the FROM line to 1.25:
find build -name Dockerfile -exec \
    sed -i 's|FROM golang:1.24-bookworm|FROM golang:1.25-bookworm|g' {} \;

# 2b. go.work files declare "go 1.24.0" but their child modules require
#     "go >= 1.25.0", causing `go mod download` to refuse. Bump:
find build -name 'go.work' -type f -exec \
    sed -i 's/^go 1\.24\.0$/go 1.25.0/' {} \;
# If there's also a `toolchain go1.24.0` directive, bump it too:
find build -name 'go.work' -type f -exec \
    sed -i 's/^toolchain go1\.24\.0$/toolchain go1.25.0/' {} \;
```

### 3. Build + push the seven service images under the sockshop_ prefix

The Blueprint kubernetes plugin emits `image: docclabgroup/<svc>_ctr`
references (no tag, no prefix). But `docclabgroup` already has
`<svc>-ctr` repos (hyphenated, prior sockshop attempt) + plain `<svc>`
repos (HR services). To avoid confusion, push our sockshop images
under the `sockshop_` prefix, then rewrite the manifests in step 4 to
match.

```bash
sudo docker login    # or `docker login` if you're in the docker group
fail=0
while IFS= read -r dfile; do
    dir=$(dirname "$dfile")
    ctr=$(basename "$dir")                     # e.g. "frontend_ctr"
    img="docclabgroup/sockshop_${ctr}:latest"
    echo "=== Building $img from $dir ==="
    if sudo docker build -t "$img" "$dir"; then
        echo "=== Pushing $img ==="
        sudo docker push "$img" || { echo "PUSH FAILED: $img"; fail=$((fail+1)); }
    else
        echo "BUILD FAILED: $img"
        fail=$((fail+1))
    fi
done < <(find build -name Dockerfile -type f)
[[ "$fail" -eq 0 ]] && echo "ALL IMAGES PUSHED under docclabgroup/sockshop_*_ctr:latest"
```

### 4. Stash the manifests + post-process

Copy the generated `*_pod/` subdirs into this repo, then apply two
post-process seds in a single pass:

- **Rename image refs** to match the `sockshop_` prefix pushed in step 3.
- **Strip `namespace:` lines** so `lib/testbed-ss.sh`'s
  `kubectl apply -n $SS_NAMESPACE` becomes the source of truth (the
  default `aggressor-ss`; configurable via env). Without this step,
  any namespace mismatch between manifest and `-n` flag is a hard
  kubectl error.

```bash
SS_STASH=/local/dsb_hd_counter/hotelReservation/noisy-neighbors/stage3-eval/sockshop-manifests
mkdir -p "$SS_STASH"
rm -rf "$SS_STASH"/*_pod
cp -r build/*_pod "$SS_STASH/"

# Combined post-process: image-name prefix + namespace strip.
find "$SS_STASH" -name '*.yaml' -exec sed -i \
    -e 's|image: docclabgroup/\([a-z]*_ctr\)|image: docclabgroup/sockshop_\1|g' \
    -e '/^  namespace: /d' \
    {} \;

# Verify (1): all 7 docclabgroup refs are sockshop_-prefixed.
grep -rh '^[[:space:]]*image:' "$SS_STASH" | grep docclabgroup | sort -u
# Expect 7 lines: docclabgroup/sockshop_{cart,catalogue,frontend,order,payment,shipping,user}_ctr

# Verify (2): no namespace: lines remain.
grep -rh '^  namespace:' "$SS_STASH"
# Expect: no output.

# Verify (3): dry-run all manifests against a throwaway namespace.
kubectl create namespace ss-stash-verify --dry-run=client -o yaml | kubectl apply -f -
FAIL=0
for f in "$SS_STASH"/*_pod/*.yaml; do
    out=$(kubectl apply --dry-run=server -f "$f" -n ss-stash-verify 2>&1)
    if ! echo "$out" | grep -qE '(created|configured|unchanged)'; then
        echo "FAIL: $f"; echo "$out" | tail -3; FAIL=$((FAIL+1))
    fi
done
[[ "$FAIL" -eq 0 ]] && echo "ALL 26 MANIFESTS PASS DRY-RUN"
kubectl delete namespace ss-stash-verify --wait=false
```

### 5. Commit the new manifests

```bash
cd /local/dsb_hd_counter
git add hotelReservation/noisy-neighbors/stage3-eval/sockshop-manifests/
git commit -m "stage3-eval: refresh sockshop manifests (Blueprint <commit-or-version>)"
```

### 3. Implement `lib/testbed-ss.sh`

Now that we know the exact manifest layout, the contract from the
"What's needed regardless of path" section below is concrete:

```bash
SS_NAMESPACE="${SS_NAMESPACE:-aggressor-ss}"
SS_MANIFESTS_DIR="${SS_MANIFESTS_DIR:-$STAGE3_EVAL_DIR/sockshop-manifests}"

ss_deploy() {
    local exp_dir="$1"
    kubectl create namespace "$SS_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -

    # The Blueprint kubernetes plugin emits each pod into its own
    # <pod-name>/ dir with -deployment.yaml + -service.yaml. -R
    # recurses so a single apply picks up everything.
    BLUEPRINT_K8S_NAMESPACE="$SS_NAMESPACE" \
        kubectl apply -R -f "$SS_MANIFESTS_DIR/" -n "$SS_NAMESPACE" \
        >> "$exp_dir/logs/testbed-ss.log" 2>&1
}

ss_teardown() {
    # Soft reset: strip nodeSelector/tolerations from each deployment.
    for d in $(kubectl -n "$SS_NAMESPACE" get deployments \
                -l 'blueprint.service' \
                -o jsonpath='{.items[*].metadata.name}'); do
        kubectl -n "$SS_NAMESPACE" patch deployment "$d" --type='merge' -p \
            '{"spec":{"template":{"spec":{"nodeSelector":null,"tolerations":null}}}}' \
            >/dev/null 2>&1 || true
    done
}

ss_uninstall() {
    kubectl delete namespace "$SS_NAMESPACE" --ignore-not-found
}

ss_frontend_url() {
    local target_node="$1"
    # The Blueprint plugin emits ClusterIP services by default.
    # Promote frontend-pod to NodePort.
    kubectl -n "$SS_NAMESPACE" patch svc frontend-pod \
        -p '{"spec":{"type":"NodePort"}}' >/dev/null 2>&1 || true
    local node_port
    node_port=$(kubectl -n "$SS_NAMESPACE" get svc frontend-pod \
        -o jsonpath='{.spec.ports[0].nodePort}')
    local node_ip
    node_ip=$(kubectl get node "$target_node" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    echo "http://${node_ip}:${node_port}"
}

declare -gA SS_SERVICE_TO_DEPLOYMENT=(
    [frontend]=frontend-pod
    [user]=user-pod
    [cart]=cart-pod
    [order]=order-pod
    [payment]=payment-pod
    [shipping]=shipping-pod
    [catalogue]=catalogue-pod
    # DBs are kept addressable as separate aggressors if needed:
    [user-db]=user-db-pod
    [cart-db]=cart-db-pod
    [order-db]=order-db-pod
    [shipping-db]=shipping-db-pod
    [catalogue-db]=catalogue-db-pod
)

ss_deployment_for_service() {
    local svc="$1"
    local mapped="${SS_SERVICE_TO_DEPLOYMENT[$svc]:-}"
    if [[ -z "$mapped" ]]; then
        echo "ERROR [testbed-ss]: unknown SS service '$svc'" >&2
        echo "       Known: ${!SS_SERVICE_TO_DEPLOYMENT[*]}" >&2
        return 1
    fi
    echo "$mapped"
}

ss_pod_for_deployment() {
    local deploy="$1"
    kubectl -n "$SS_NAMESPACE" get pods \
        -l "blueprint.service=$deploy" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}
```

Plus a wrk2 lua script for the sockshop e2e workload (place at
`hotelReservation/wrk2/scripts/sockshop/mixed-workload.lua`):
60/30/8/2 mix over `/customers`, `/catalogue`, `/cart`, `/orders` is
a reasonable starting point matching the upstream sockshop wlgen.

The orchestrator's `lib/wrk2-driver.sh` then needs:

```bash
WRK2_TESTBED_SCRIPT[sockshop]="$STAGE3_EVAL_DIR/../../wrk2/scripts/sockshop/mixed-workload.lua"
```

## Upstream gaps + PR plan

The smoke test found **four** issues with the upstream
`plugins/kubernetes/` plugin. Three are fixed locally; one is
documented with a workaround.

| # | Issue | Status | Files touched |
|---|-------|--------|---------------|
| 1 | Hard tabs in YAML templates (3 lines: 160, 173, 191) cause `kubectl` to reject manifests with "found a tab character that violates indentation". | **Fixed locally.** | `plugins/kubernetes/kubepod/deploygen/deployfile.go` |
| 2 | No namespace support -- all manifests go into `default`. | **Fixed locally.** Added `BLUEPRINT_K8S_NAMESPACE` env var that stamps `metadata.namespace:` into every emitted manifest. | `plugins/kubernetes/kubepod/deploygen/deployfile.go` |
| 3 | Resource names use raw Blueprint node names with `_` and `.`, both forbidden by RFC 1123 / DNS-1035. | **Fixed locally.** Added `K8sName` template helper in `kubetemplate/template.go` and wrapped identifier usages in deployment + service templates. | `plugins/kubernetes/kubetemplate/template.go`, `plugins/kubernetes/kubepod/deploygen/deployfile.go` |
| 4 | `kubernetes.AddContainerToApplication(spec, app, reg, ctr)` calls `kubepod.NewKubePod(spec, ctr, reg, ctr)` -- using the container name as both pod name AND container child. `NewKubePod`'s `spec.Define(podName, ...)` then overwrites any existing node with that name, breaking shared resources like `zipkin.ctr` ("Attempted to instantiate the server-side of address zipkin.addr ... server failed to instantiate"). | **Workaround documented in spec.** Call `kubepod.NewKubePod` directly with a distinct `<ctr>_pod` pod name and attach via `namespaceutil.AddNodeTo[kubernetes.Application]`. | `examples/sockshop/wiring/specs/kubernetes.go` (workaround), upstream fix would need to either rename the pod or detect collision. |

### Upstream PR plan

PR #1 (small, low-risk, mergeable as-is):
- **kubepod: fix tab indents + add namespace support + sanitize resource names**
- Two files (`deployfile.go`, `template.go`). All three fixes are self-contained template / template-helper changes.
- Branch: `feat/kubepod-namespace-and-name-fix` in your fork.
- Suggested commit message at the bottom of this file.

PR #2 (or issue first; API discussion):
- **kubernetes: AddContainerToApplication should not shadow the input container name.**
- Possible fixes: (a) generate a distinct pod name internally (e.g. append `_pod`), (b) detect existing nodes and refuse to redefine, (c) take an explicit pod-name arg. Wants maintainer input.
- File as an issue first with a minimal repro from `examples/sockshop`; if maintainers agree on the fix, follow up with a PR.

PR #3 (optional, contribution back):
- **examples/sockshop/wiring/specs/kubernetes.go**
- The wiring spec we authored. Includes a header comment explaining the
  `kubernetes.AddContainerToApplication` workaround so other users
  hitting it can self-serve.

### Suggested commit message for PR #1

```
kubepod: fix tab indents, add namespace support, sanitize names

Three issues in the generated YAML templates that block deployment:

1. Hard \t characters at lines 160 (imagePullPolicy), 173 (closing
   {{- end}}), and 191 (port:) produce manifests that fail kubectl
   with "found a tab character that violates indentation".

2. No way to target a non-default namespace. Added BLUEPRINT_K8S_NAMESPACE
   env var that, when set, stamps metadata.namespace into every
   generated deployment.yaml and service.yaml. Default unset
   preserves existing behavior.

3. Generated resource names use raw Blueprint node names that
   contain '_' and '.', both forbidden by RFC 1123 (metadata.name,
   containers[].name, hostname) and DNS-1035 (service names).
   Added a K8sName template helper that lowercases + replaces
   non-[a-z0-9-] with '-' + trims leading/trailing hyphens. Wrapped
   identifier usages in the deployment + service templates; left
   env var names alone (which DO allow underscores).

Verified end-to-end against the sockshop example: all 26 manifests
(13 pods x deployment.yaml + service.yaml) pass
kubectl apply --dry-run=server.
```

## Open follow-ups (not blockers)

- **Image tag pinning**: the plugin currently emits
  `image: docclabgroup/<ctr>` with no `:tag`. K8s defaults this to
  `:latest` with `imagePullPolicy: Always`, which works but isn't
  reproducible. Worth a minor plugin enhancement to accept a tag.
- **StatefulSets for DBs**: mongo/mysql pods are `Deployment`s with
  no `PersistentVolumeClaim`, so data is ephemeral. Fine for
  research (we want fresh state per run) but worth a follow-up if
  anyone needs persistence.
- **NodePort vs Ingress**: plugin only emits `Service` (ClusterIP by
  default). `lib/testbed-ss.sh` patches frontend to NodePort for
  wrk2 reach; an `--expose-frontend` plugin option would be cleaner.
- **Service port name length cap**: RFC 6335 says ≤15 chars for
  IANA_SVC_NAME. Some of our sanitized names (e.g.
  `catalogue-service-grpc-addr` = 27 chars) exceed this in
  principle; in practice the cluster's `kubectl --dry-run=server`
  accepted them. May or may not be a real issue depending on the
  cluster's validation strictness.

## Path 2 + Path 3 (no longer recommended, kept for posterity)

Earlier iterations considered:
- **Path 2: docc-lab's `d2k8s` / `k8s-convert`** -- post-hoc Kompose
  conversion of docker-compose output. Battle-tested but architecturally
  a dead end (Python scripts, not plugin-shaped).
- **Path 3: archived `microservices-demo/microservices-demo`** --
  standalone manifests, not Blueprint-built.

Both are now obsolete because Path 1 (upstream Blueprint plugin)
works after the three local fixes. Keeping references here only for
historical context.

## References

- Upstream Blueprint kubernetes branch:
  <https://github.com/Blueprint-uServices/blueprint/tree/kubernetes>
- Upstream `plugins/kubernetes/`:
  <https://github.com/Blueprint-uServices/blueprint/tree/kubernetes/plugins/kubernetes>
- Upstream sockshop example (no kubernetes.go spec yet -- our PR #3
  would add it): <https://github.com/Blueprint-uServices/blueprint/tree/kubernetes/examples/sockshop>
- Related WIP branch (also has plugins/kubernetes/, AI-assisted):
  <https://github.com/Blueprint-uServices/blueprint/tree/jonathanmace/vibecoding_kubernetes>
- docc-lab fork: <https://github.com/docc-lab/blueprint-docc-mod>
