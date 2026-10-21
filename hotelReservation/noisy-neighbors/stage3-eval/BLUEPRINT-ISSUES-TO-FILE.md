# Blueprint issues — ready to file

Four remaining bugs from `BLUEPRINT-BUGS.md`, polished into standalone
GitHub-issue form (Bug 2 / hard tabs is already filed). Each block below is
one issue: the **Title** goes in the GitHub title field, everything under it
is the body. Repo: <https://github.com/Blueprint-uServices/blueprint> (branch
`kubernetes`).

---

# Issue A (Bug 1)

**Title:** `kubernetes` deploygen omits inter-service client `*_DIAL_ADDR` env vars — every non-leaf pod crashloops

## Summary

The Kubernetes deployment generator emits each service's *own* server bind
address (`<svc>_..._BIND_ADDR`) but **not** the `*_DIAL_ADDR` env vars for the
clients the process instantiates (peer services, databases, zipkin). Each
generated `main.go` hard-requires those args, so every non-leaf service aborts
at startup and the application never becomes healthy:

```
Running frontend_ctr
Required environment variables:
  CART_SERVICE_GRPC_DIAL_ADDR (missing)
  CATALOGUE_SERVICE_GRPC_DIAL_ADDR (missing)
  FRONTEND_HTTP_BIND_ADDR=0.0.0.0:2000
  ORDER_SERVICE_GRPC_DIAL_ADDR (missing)
  USER_SERVICE_GRPC_DIAL_ADDR (missing)
  ZIPKIN_DIAL_ADDR (missing)
Aborting due to missing environment variables
```

The Docker-compose generator wires these dial addresses correctly, so this looks
like a parity gap specific to the kubernetes plugin.

## Reproduce Bug

Branch: `kubernetes`.

1. Compile sockshop with the kubernetes wiring spec and apply it:
   ```bash
   go run wiring/main.go -o build -w kubernetes
   kubectl create namespace ss
   kubectl apply -R -f build/ -n ss
   ```
2. Only the leaf pods (DBs + zipkin) come up; every application pod crashloops:
   ```
   $ kubectl get pods -n ss
   NAME                               READY   STATUS             RESTARTS
   cart-db-pod-...                    1/1     Running            0
   cart-pod-...                       0/1     CrashLoopBackOff   15
   catalogue-db-pod-...               1/1     Running            0
   catalogue-pod-...                  0/1     CrashLoopBackOff   17
   frontend-pod-...                   0/1     CrashLoopBackOff   17
   order-pod-...                      0/1     CrashLoopBackOff   17
   payment-pod-...                    0/1     CrashLoopBackOff   17
   shipping-pod-...                   0/1     CrashLoopBackOff   17
   user-pod-...                       0/1     CrashLoopBackOff   17
   zipkin-pod-...                     1/1     Running            0
   ```
3. Because the frontend never goes Ready, its Service has **no endpoints**, and
   any client gets a hard refusal rather than a routed response:
   ```
   $ kubectl get endpoints frontend-pod -n ss
   NAME           ENDPOINTS   AGE
   frontend-pod               65m          # <-- empty

   $ curl http://<node>:<nodeport>/...
   unable to connect to <node>:<nodeport> Connection refused
   ```
4. `kubectl logs deploy/frontend-pod -n ss` shows the missing-env abort above.
   The generated `deployment.yaml` only contains the pod's own bind addr:
   ```yaml
   env:
     - name: FRONTEND_HTTP_BIND_ADDR
       value: "0.0.0.0:2000"
   # no CART_/CATALOGUE_/ORDER_/USER_SERVICE_GRPC_DIAL_ADDR, no ZIPKIN_DIAL_ADDR
   ```

## Suggested fix

For each container, emit an env var for **every** `--<dep>.<proto>.dial_addr`
argument the generated `main.go` requires, set to the dependency's in-cluster
address `<peer-service>:<port>`. The generator already applies the
`a.grpc.dial_addr → A_GRPC_DIAL_ADDR` naming rule for the bind addr, and the peer
pods' Service names + ports are known at generation time, so the value can be
emitted directly (mirroring the Docker generator). Looks like a one-file change
to the container `env:` emission in
`plugins/kubernetes/kubepod/deploygen/deployfile.go`.

## Workaround (verified locally)

Hand-added the missing `*_DIAL_ADDR` env vars to all 7 app deployments, pointing
at `<peer-service>:<port>` (DB creds are compiled into the proc, so only the
address is needed). After that, all 13 pods reach `Running` and the gateway
serves a real call chain end-to-end:

```
$ kubectl get pods -n ss            # 13/13 Running
$ curl -sS -o /dev/null -w "%{http_code}\n" \
       "http://<node>:<nodeport>/ListItems?pageSize=10&pageNum=1"
200
```

## Environment

- Branch: `kubernetes`
- Example: `examples/sockshop`, compiled `-w kubernetes`, deployed to a vanilla
  Kubernetes cluster (ClusterIP services, single namespace)

---

# Issue B (Bug 3)

**Title:** Generated resource names violate RFC 1123 / DNS-1035 — admission rejects the manifests

## Summary

Generated Kubernetes resource names use the raw Blueprint node names, which
contain `_` and `.`. Both characters are forbidden in `metadata.name`,
`containers[].name`, and `hostname` (RFC 1123 label/subdomain) and in Service
names (DNS-1035), so admission rejects the manifests:

```
The Deployment "cart_service" is invalid: metadata.name: Invalid value:
"cart_service": a lowercase RFC 1123 subdomain must consist of lower case
alphanumeric characters, '-' or '.', and must start and end with an
alphanumeric character
```

(Service names are stricter still — DNS-1035 forbids the leading-digit and `_`
forms that some node names produce.)

## Reproduce Bug

Branch: `kubernetes`.

Compile any app whose Blueprint node names contain `_` or `.` (sockshop has
`cart_service`, `catalogue_service`, the shared `zipkin.ctr`, etc.), then:

```bash
kubectl apply --dry-run=server -f build/<pod-name>/<pod-name>-deployment.yaml
kubectl apply --dry-run=server -f build/<pod-name>/<pod-name>-service.yaml
```

Admission rejects the name as not a valid DNS label/subdomain (error above);
the unsanitized identifier also appears in `containers[].name` and `hostname`.

## Suggested fix

Sanitize identifiers used as k8s object / container / host / service names to
valid DNS labels: lowercase, replace `[^a-z0-9-]` with `-`, trim
leading/trailing hyphens. Leave env-var names alone (they *do* permit `_`).
Implemented locally as a `K8sName` template helper in
`plugins/kubernetes/kubetemplate/template.go`, wrapped around identifier usages
in `plugins/kubernetes/kubepod/deploygen/deployfile.go` (deployment + service
templates).

## Environment

- Branch: `kubernetes`
- Example: `examples/sockshop` (13 pods); all 26 manifests pass
  `kubectl apply --dry-run=server` after the helper is applied
- kubectl: any recent version

---

# Issue C (Bug 4)

**Title:** `AddContainerToApplication` reuses the container name as the pod name, redefining shared resource nodes

## Summary

`kubernetes.AddContainerToApplication(spec, app, reg, ctr)` calls
`kubepod.NewKubePod(spec, ctr, reg, ctr)`, using the **container name as both the
pod name and the container child**. `NewKubePod`'s `spec.Define(podName, ...)`
then overwrites any existing node already registered under that name. Shared
resources (e.g. `zipkin.ctr`, referenced by every sockshop service) get
redefined and their server side never instantiates:

```
Attempted to instantiate the server-side of address zipkin.addr ...
server failed to instantiate
```

## Reproduce Bug

Branch: `kubernetes`.

Wire an app where two or more services share a resource node (sockshop: all
services reference a single `zipkin`), then compile:

```bash
go run wiring/main.go -o build -w kubernetes
# -> compile aborts with the "server failed to instantiate" error above
```

## Suggested fix

Adding a container should not redefine an existing node with the same name.
Options (would want maintainer input): (a) generate a distinct pod name
internally (e.g. append `_pod`), (b) detect an existing node and refuse to
redefine, or (c) take an explicit pod-name argument.

Workaround in the wiring spec: call `kubepod.NewKubePod` directly with a distinct
`<ctr>_pod` pod name and attach via
`namespaceutil.AddNodeTo[kubernetes.Application]`.

## Environment

- Branch: `kubernetes`
- Example: `examples/sockshop` (fails as soon as a node is shared across pods)

---

# Issue D (Bug 5)

**Title:** Generated build pins Go 1.24 but generated modules require Go ≥ 1.25 — image build fails

## Summary

The generated container build pins Go 1.24 in two places, but the generated
modules require Go ≥ 1.25, so the image build / `go mod download` refuses with a
version error. The codegen is internally inconsistent:

```
go: go.work requires go >= 1.25.0 (running go 1.24.x; GOTOOLCHAIN=local)
```

## Reproduce Bug

Branch: `kubernetes` (goproc codegen).

Generate any app and build one of the generated service images:

```bash
go run wiring/main.go -o build -w kubernetes
docker build build/<svc>_pod/<svc>_ctr      # or -w docker
```

The build fails because:

- `Dockerfile` has `FROM golang:1.24-bookworm` (too old), and
- `go.work` declares `go 1.24.0` (and possibly `toolchain go1.24.0`), while the
  generated child modules require `go >= 1.25.0`.

## Suggested fix

Make the generated `Dockerfile` base image and `go.work` `go`/`toolchain`
directives consistent with (≥) the Go version the generated modules require
(derive from the module requirements rather than a hard-coded literal).

Workaround — post-process after generation:

```bash
find build -name Dockerfile -exec sed -i 's|FROM golang:1.24-bookworm|FROM golang:1.25-bookworm|g' {} \;
find build -name go.work   -exec sed -i 's/^go 1\.24\.0$/go 1.25.0/' {} \;
find build -name go.work   -exec sed -i 's/^toolchain go1\.24\.0$/toolchain go1.25.0/' {} \;
```

## Environment

- Branch: `kubernetes` (goproc / container codegen templates)
- Go: toolchain ≥ 1.25 required by the generated modules; templates emit 1.24
- Docker: any recent version
