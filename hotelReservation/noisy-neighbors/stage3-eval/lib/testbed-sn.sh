#!/bin/bash
# ===========================================================================
# testbed-sn.sh
#
# Helm-based deploy / reset / target-URL helpers for socialNetwork as
# a Stage 3 aggressor testbed. SN runs in its own namespace
# ('aggressor-sn' by default) so it cannot collide with HR's 'default'
# namespace where the victim lives.
#
# Functions exposed (sourced by stage3-eval.sh):
#   sn_deploy           <exp_dir>       -> helm upgrade --install (idempotent)
#   sn_teardown         <exp_dir>       -> resets nodeSelector/tolerations; no uninstall
#   sn_uninstall        <exp_dir>       -> full helm uninstall (only used by user-requested clean)
#   sn_frontend_url     <target_node>   -> http://<node-ip>:<nodeport>
#   sn_deployment_for_service <svc>     -> human service name -> helm deployment name
# ===========================================================================

set -u

SN_NAMESPACE="${SN_NAMESPACE:-aggressor-sn}"
SN_RELEASE="${SN_RELEASE:-sn-aggressor}"
SN_CHART_DIR="${SN_CHART_DIR:-../../../socialNetwork/helm-chart/socialnetwork}"
# Override for the SN nginx `resolver` directive. The chart defaults to the
# hostname 'kube-dns.kube-system.svc.cluster.local', which the old
# yg397/openresty-thrift:xenial nginx resolves at config-parse time -- if the
# cluster's DNS Service isn't literally named 'kube-dns' that lookup fails with
# `[emerg] host not found in resolver` and nginx-thrift/media-frontend
# CrashLoopBackOff. Setting SN_DNS_RESOLVER to the DNS ClusterIP (an IP literal,
# which is what nginx's resolver actually wants) sidesteps the name lookup.
# Empty -> sn_deploy auto-detects the ClusterIP at deploy time.
SN_DNS_RESOLVER="${SN_DNS_RESOLVER:-}"

# ---------------------------------------------------------------------------
# sn_dns_resolver
#   Echo the cluster DNS ClusterIP to use for nginx's resolver directive.
#   Honors an explicit SN_DNS_RESOLVER override; otherwise looks up the
#   kube-system DNS Service by its standard k8s-app=kube-dns label (works for
#   both kube-dns and CoreDNS, which keep that label for compatibility).
#   Echoes nothing on failure so the caller can fall back to the chart default.
# ---------------------------------------------------------------------------
sn_dns_resolver() {
    if [[ -n "$SN_DNS_RESOLVER" ]]; then
        echo "$SN_DNS_RESOLVER"
        return 0
    fi
    kubectl get svc -n kube-system -l k8s-app=kube-dns \
        -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null
}

# Human-friendly service name -> deployment name as the helm chart
# renders it. Most are `<chart>-<release>` or `<release>-<chart>` depending
# on the chart template; we use the human name directly when the chart
# emits a deployment with that exact name (true for most charts via
# `.Chart.Name`).
declare -gA SN_SERVICE_TO_DEPLOYMENT=(
    [nginx-thrift]=nginx-thrift
    [compose-post]=compose-post-service
    [user-timeline]=user-timeline-service
    [home-timeline]=home-timeline-service
    [post-storage]=post-storage-service
    [social-graph]=social-graph-service
    [text]=text-service
    [unique-id]=unique-id-service
    [url-shorten]=url-shorten-service
    [user-mention]=user-mention-service
    [media]=media-service
    [user]=user-service
)

# ---------------------------------------------------------------------------
# sn_deployment_for_service <human-service-name>
# ---------------------------------------------------------------------------
sn_deployment_for_service() {
    local svc="$1"
    local mapped="${SN_SERVICE_TO_DEPLOYMENT[$svc]:-}"
    if [[ -z "$mapped" ]]; then
        echo "ERROR [testbed-sn]: unknown SN service '$svc'" >&2
        echo "       Known: ${!SN_SERVICE_TO_DEPLOYMENT[*]}" >&2
        return 1
    fi
    echo "$mapped"
}

# ---------------------------------------------------------------------------
# sn_deploy <exp_dir>
#
# Idempotent: `helm upgrade --install` so a re-run against an existing
# release simply no-ops. Creates the namespace if it doesn't exist.
# ---------------------------------------------------------------------------
sn_deploy() {
    local exp_dir="$1"
    local log_prefix="[testbed-sn]"

    if ! command -v helm >/dev/null 2>&1; then
        echo "ERROR $log_prefix: helm is required for socialNetwork aggressor" >&2
        return 1
    fi
    if [[ ! -d "$SN_CHART_DIR" ]]; then
        echo "ERROR $log_prefix: chart dir not found at '$SN_CHART_DIR'" >&2
        echo "       Set SN_CHART_DIR in env or run from stage3-eval/." >&2
        return 1
    fi

    echo "$log_prefix Resolving chart dependencies (helm dep update)"
    helm dependency update "$SN_CHART_DIR" \
        >> "$exp_dir/logs/testbed-sn.log" 2>&1 || {
            echo "WARNING $log_prefix: helm dep update failed; proceeding with whatever's already in charts/" >&2
        }

    # Resolve the cluster DNS ClusterIP so the SN nginx `resolver` directive
    # gets an IP literal instead of the chart's hardcoded hostname (see
    # SN_DNS_RESOLVER note above). Fall back to the chart default if lookup fails.
    local dns_resolver helm_dns_args=()
    dns_resolver="$(sn_dns_resolver)"
    if [[ -n "$dns_resolver" ]]; then
        echo "$log_prefix Using DNS resolver ClusterIP '$dns_resolver' for nginx"
        helm_dns_args=(--set "global.nginx.resolverName=$dns_resolver")
    else
        echo "WARNING $log_prefix: could not detect kube-dns ClusterIP; using chart default resolverName (nginx may CrashLoop if it isn't named 'kube-dns')" >&2
    fi

    echo "$log_prefix Deploying release '$SN_RELEASE' into namespace '$SN_NAMESPACE'"
    helm upgrade --install "$SN_RELEASE" "$SN_CHART_DIR" \
        --namespace "$SN_NAMESPACE" --create-namespace \
        "${helm_dns_args[@]}" \
        --wait --timeout 5m \
        >> "$exp_dir/logs/testbed-sn.log" 2>&1 || {
            echo "ERROR $log_prefix: helm upgrade --install failed; see $exp_dir/logs/testbed-sn.log" >&2
            return 1
        }

    return 0
}

# ---------------------------------------------------------------------------
# sn_teardown <exp_dir>
#
# Soft reset: removes nodeSelector + tolerations from every SN deployment
# so a subsequent experiment starts from clean scheduling state. Leaves
# the helm release in place; sn_uninstall is the heavy hammer for that.
# ---------------------------------------------------------------------------
sn_teardown() {
    local exp_dir="$1"
    echo "[testbed-sn] Resetting SN deployments to pre-experiment scheduling state"

    local svc deploy
    for svc in "${!SN_SERVICE_TO_DEPLOYMENT[@]}"; do
        deploy="${SN_SERVICE_TO_DEPLOYMENT[$svc]}"
        # Skip silently if the deployment doesn't exist (chart didn't emit it
        # or it was already cleaned up).
        if ! kubectl -n "$SN_NAMESPACE" get deployment "$deploy" >/dev/null 2>&1; then
            continue
        fi
        kubectl -n "$SN_NAMESPACE" patch deployment "$deploy" --type='merge' -p '{
          "spec": { "template": { "spec": {
            "nodeSelector": null,
            "tolerations":  null
          }}}
        }' >> "$exp_dir/logs/testbed-sn.log" 2>&1 || true
    done
    return 0
}

# ---------------------------------------------------------------------------
# sn_uninstall <exp_dir>
#
# Full helm uninstall + namespace delete. Only called when the user
# explicitly passes --uninstall to stage3-eval.sh; default teardown is
# the soft sn_teardown above so back-to-back experiments are fast.
# ---------------------------------------------------------------------------
sn_uninstall() {
    local exp_dir="$1"
    echo "[testbed-sn] Uninstalling helm release '$SN_RELEASE' and namespace '$SN_NAMESPACE'"
    helm uninstall "$SN_RELEASE" --namespace "$SN_NAMESPACE" \
        >> "$exp_dir/logs/testbed-sn.log" 2>&1 || true
    kubectl delete namespace "$SN_NAMESPACE" --ignore-not-found \
        >> "$exp_dir/logs/testbed-sn.log" 2>&1 || true
}

# ---------------------------------------------------------------------------
# sn_frontend_url <target_node>
#
# Echoes the wrk2 target URL for the SN nginx-thrift frontend. Promotes
# the service to NodePort if it isn't already.
# ---------------------------------------------------------------------------
sn_frontend_url() {
    local target_node="$1"

    local svc_type
    svc_type=$(kubectl -n "$SN_NAMESPACE" get svc nginx-thrift \
        -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
    if [[ "$svc_type" != "NodePort" && "$svc_type" != "LoadBalancer" ]]; then
        kubectl -n "$SN_NAMESPACE" patch svc nginx-thrift \
            -p '{"spec":{"type":"NodePort"}}' >/dev/null 2>&1 || true
    fi

    local node_port
    node_port=$(kubectl -n "$SN_NAMESPACE" get svc nginx-thrift \
        -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [[ -z "$node_port" ]]; then
        echo "ERROR [testbed-sn]: failed to resolve nginx-thrift NodePort" >&2
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
        echo "ERROR [testbed-sn]: failed to resolve IP for node '$target_node'" >&2
        return 1
    fi
    echo "http://${node_ip}:${node_port}"
}

# ---------------------------------------------------------------------------
# sn_pod_for_deployment <deployment-name>
# ---------------------------------------------------------------------------
sn_pod_for_deployment() {
    local deploy="$1"
    kubectl -n "$SN_NAMESPACE" get pods \
        -l "app=$deploy" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}
