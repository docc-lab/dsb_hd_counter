#!/bin/bash
# ===========================================================================
# testbed-hr.sh
#
# Per-testbed deployment + reset helpers for hotelReservation.
#
# In Stage 3 eval, HR is the testbed the victim comes from. It's also
# a valid aggressor testbed: a config can include {testbed:
# hotelReservation, service: geo, role: good} to colocate geo on the
# victim node as a "good" aggressor (or any other HR service as a
# "bad" one).
#
# Functions exposed (sourced by stage3-eval.sh):
#   hr_deploy        <exp_dir>            -> idempotent kubectl apply
#   hr_teardown      <exp_dir>            -> reset deployments to a clean
#                                            ClusterIP / no-nodeSelector state.
#                                            Does NOT delete; HR persistent
#                                            services (consul, jaeger, ...)
#                                            stay running for the next run.
#   hr_frontend_url  <target_node>        -> http://<node-ip>:<nodeport>
#                                            for the HR frontend (wrk2 target)
#   hr_deployment_for_service <svc>       -> deployment name in the cluster
#                                            (handles the "reccomend" /
#                                            "reserve" naming quirks)
# ===========================================================================

set -u

HR_NAMESPACE="${HR_NAMESPACE:-default}"
HR_KUBERNETES_DIR="${HR_KUBERNETES_DIR:-../../kubernetes}"

# Map between human-friendly service names (as written in YAML) and the
# actual k8s deployment names. Most are 1:1; HR uses slightly off-spec
# names for "recommendation" -> "reccomend" and "reservation" -> "reserve".
declare -gA HR_SERVICE_TO_DEPLOYMENT=(
    [frontend]=frontend
    [search]=search
    [profile]=profile
    [geo]=geo
    [rate]=rate
    [recommendation]=reccomend
    [reservation]=reserve
    [user]=user
)

# Service -> kubernetes/ subdir mapping (some HR services live in
# directories whose names match the deployment, not the human name).
declare -gA HR_SERVICE_TO_DIR=(
    [frontend]=frontend
    [search]=search
    [profile]=profile
    [geo]=geo
    [rate]=rate
    [recommendation]=reccomend
    [reservation]=reserve
    [user]=user
)

# ---------------------------------------------------------------------------
# hr_deployment_for_service <human-service-name>
# ---------------------------------------------------------------------------
hr_deployment_for_service() {
    local svc="$1"
    local mapped="${HR_SERVICE_TO_DEPLOYMENT[$svc]:-}"
    if [[ -z "$mapped" ]]; then
        echo "ERROR [testbed-hr]: unknown HR service '$svc'" >&2
        echo "       Known: ${!HR_SERVICE_TO_DEPLOYMENT[*]}" >&2
        return 1
    fi
    echo "$mapped"
}

# ---------------------------------------------------------------------------
# hr_deploy <exp_dir>
#
# Idempotent: applies every YAML under HR_KUBERNETES_DIR/<subdir>/ for
# the services the experiment cares about, plus the always-on shared
# dependencies (consul, jaeger). If a deployment already exists, kubectl
# apply is a no-op (server-side merge). Returns 0 even when some
# manifests fail -- aggressor / victim deployments are individually
# verified later via hr_wait_ready.
# ---------------------------------------------------------------------------
hr_deploy() {
    local exp_dir="$1"
    local log_prefix="[testbed-hr]"

    if [[ ! -d "$HR_KUBERNETES_DIR" ]]; then
        echo "ERROR $log_prefix: HR_KUBERNETES_DIR not found at '$HR_KUBERNETES_DIR'" >&2
        echo "       Set HR_KUBERNETES_DIR in env or invoke from stage3-eval/." >&2
        return 1
    fi

    echo "$log_prefix Applying shared HR services (consul + jaeger) from $HR_KUBERNETES_DIR"
    for shared in consul jaeger; do
        if [[ -d "$HR_KUBERNETES_DIR/$shared" ]]; then
            kubectl apply -f "$HR_KUBERNETES_DIR/$shared/" -n "$HR_NAMESPACE" \
                >> "$exp_dir/logs/testbed-hr.log" 2>&1 || {
                    echo "WARNING $log_prefix: kubectl apply failed for $shared" >&2
                }
        fi
    done

    echo "$log_prefix Applying HR service deployments"
    local svc dir
    for svc in "${!HR_SERVICE_TO_DIR[@]}"; do
        dir="${HR_SERVICE_TO_DIR[$svc]}"
        if [[ -d "$HR_KUBERNETES_DIR/$dir" ]]; then
            kubectl apply -f "$HR_KUBERNETES_DIR/$dir/" -n "$HR_NAMESPACE" \
                >> "$exp_dir/logs/testbed-hr.log" 2>&1 || {
                    echo "WARNING $log_prefix: kubectl apply failed for $svc" >&2
                }
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# hr_wait_ready <deployment-name> [timeout-seconds]
#
# Blocking wait for one HR deployment to become Available. Used after
# hr_deploy + after aggressor placement.
# ---------------------------------------------------------------------------
hr_wait_ready() {
    local deploy="$1"
    local timeout="${2:-180}"
    kubectl -n "$HR_NAMESPACE" rollout status deployment "$deploy" --timeout="${timeout}s"
}

# ---------------------------------------------------------------------------
# hr_teardown <exp_dir>
#
# Resets HR deployments to no-nodeSelector / no-toleration so the next
# experiment can repin them. Does NOT delete deployments; tearing them
# down would orphan the persistent jaeger / consul state and slow down
# the next experiment's startup. The cleanup-trap in stage3-eval.sh
# calls this so a Ctrl-C doesn't leave aggressor pods stuck on the
# wrong node.
# ---------------------------------------------------------------------------
hr_teardown() {
    local exp_dir="$1"
    echo "[testbed-hr] Resetting HR deployments to pre-experiment scheduling state"

    local svc deploy
    for svc in "${!HR_SERVICE_TO_DEPLOYMENT[@]}"; do
        deploy="${HR_SERVICE_TO_DEPLOYMENT[$svc]}"
        kubectl -n "$HR_NAMESPACE" patch deployment "$deploy" --type='merge' -p '{
          "spec": { "template": { "spec": {
            "nodeSelector": null,
            "tolerations":  null
          }}}
        }' >> "$exp_dir/logs/testbed-hr.log" 2>&1 || true
    done
    return 0
}

# ---------------------------------------------------------------------------
# hr_frontend_url <target_node>
#
# Echoes the wrk2 target URL: http://<node-ip>:<frontend-nodeport>.
# Patches the frontend service to NodePort if it isn't already (mirrors
# step1_expose_nodeport's behavior). Cluster-internal use can instead
# read the ClusterIP and skip this.
# ---------------------------------------------------------------------------
hr_frontend_url() {
    local target_node="$1"

    # Promote frontend to NodePort if it isn't already.
    local svc_type
    svc_type=$(kubectl -n "$HR_NAMESPACE" get svc frontend \
        -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
    if [[ "$svc_type" != "NodePort" && "$svc_type" != "LoadBalancer" ]]; then
        kubectl -n "$HR_NAMESPACE" patch svc frontend \
            -p '{"spec":{"type":"NodePort"}}' >/dev/null 2>&1 || true
    fi

    local node_port
    node_port=$(kubectl -n "$HR_NAMESPACE" get svc frontend \
        -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [[ -z "$node_port" ]]; then
        echo "ERROR [testbed-hr]: failed to resolve frontend NodePort" >&2
        return 1
    fi

    local node_ip
    node_ip=$(kubectl get node "$target_node" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    if [[ -z "$node_ip" ]]; then
        node_ip=$(kubectl get node "$target_node" \
            -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
    fi
    if [[ -z "$node_ip" ]]; then
        echo "ERROR [testbed-hr]: failed to resolve IP for node '$target_node'" >&2
        return 1
    fi
    echo "http://${node_ip}:${node_port}"
}

# ---------------------------------------------------------------------------
# hr_pod_for_deployment <deployment-name>
#
# Echoes the first Running pod for the deployment (or empty). Used by
# write-run-manifest.sh.
# ---------------------------------------------------------------------------
hr_pod_for_deployment() {
    local deploy="$1"
    kubectl -n "$HR_NAMESPACE" get pods \
        -l "io.kompose.service=$deploy" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}
