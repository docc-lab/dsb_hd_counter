#!/bin/bash
# ===========================================================================
# aggressor-place.sh
#
# Patches `nodeSelector: { kubernetes.io/hostname: <target_node> }` plus
# the standard `dedicated=special:NoSchedule` toleration onto a chosen
# aggressor deployment so it lands on the victim's node. Idempotent.
#
# Why we don't reuse ../node-taint.sh:
#   - node-taint.sh adds a node taint + rolls out the deployment.
#   - We don't want to taint the aggressor's node (the victim's
#     existing pinning already establishes the taint).
#   - We don't want each aggressor placement to trigger an immediate
#     rollout restart -- the testbed-*.sh modules handle waiting once,
#     after all aggressor placements are queued.
#   - node-taint.sh is namespace-unaware; SN ships into 'aggressor-sn'.
#
# The patches here mirror node-taint.sh's manifest exactly so the same
# taint/toleration semantics apply -- no cluster-side surprises.
# ===========================================================================

set -u

# Mirror node-taint.sh constants so tolerations align with any existing
# tainted nodes the cluster might have.
PLACE_TAINT_KEY="${PLACE_TAINT_KEY:-dedicated}"
PLACE_TAINT_VALUE="${PLACE_TAINT_VALUE:-special}"
PLACE_TAINT_EFFECT="${PLACE_TAINT_EFFECT:-NoSchedule}"

# Aggressor "boost" config: aggressors run with no CPU/memory limits
# (unlimited burst) and a high scheduling priority so they win placement
# under contention. preemptionPolicy is Never so a high-priority aggressor
# can still schedule ahead of other pods but never EVICTS the already-pinned
# victim out from under the experiment.
PLACE_PRIORITY_CLASS="${PLACE_PRIORITY_CLASS:-aggressor-high-priority}"
PLACE_PRIORITY_VALUE="${PLACE_PRIORITY_VALUE:-1000000}"
# Annotation where boost_aggressor stashes the container's original
# resources block so unboost_aggressor can restore it verbatim.
PLACE_BOOST_ANNOTATION="stage3-eval.gordion/pre-boost-resources"

# ---------------------------------------------------------------------------
# place_aggressor <namespace> <deployment> <target_node>
#
# Adds nodeSelector + toleration to the deployment template spec.
# Does NOT trigger a rollout restart -- caller is responsible for
# kubectl rollout restart + kubectl rollout status if needed.
# Returns 0 on success.
# ---------------------------------------------------------------------------
place_aggressor() {
    local ns="$1"
    local deploy="$2"
    local node="$3"

    if ! kubectl -n "$ns" get deployment "$deploy" >/dev/null 2>&1; then
        echo "ERROR [aggressor-place]: deployment '$deploy' not found in namespace '$ns'" >&2
        return 1
    fi

    # Merge-patch is fine here because nodeSelector + tolerations are
    # top-level pod template fields that don't need positional ops.
    kubectl -n "$ns" patch deployment "$deploy" --type='merge' -p "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"nodeSelector\": { \"kubernetes.io/hostname\": \"$node\" },
            \"tolerations\": [
              {
                \"key\":      \"$PLACE_TAINT_KEY\",
                \"operator\": \"Equal\",
                \"value\":    \"$PLACE_TAINT_VALUE\",
                \"effect\":   \"$PLACE_TAINT_EFFECT\"
              }
            ]
          }
        }
      }
    }" >/dev/null 2>&1 || {
        echo "ERROR [aggressor-place]: failed to patch $ns/$deploy" >&2
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# unplace_aggressor <namespace> <deployment>
#
# Removes nodeSelector + tolerations from the deployment template spec.
# Idempotent. Used by stage3-eval.sh's cleanup trap so the cluster
# returns to the same shape it had pre-experiment.
# ---------------------------------------------------------------------------
unplace_aggressor() {
    local ns="$1"
    local deploy="$2"

    if ! kubectl -n "$ns" get deployment "$deploy" >/dev/null 2>&1; then
        return 0  # nothing to undo
    fi

    # Restore resources / priority before clearing scheduling fields so a
    # boosted aggressor returns fully to its base manifest shape.
    unboost_aggressor "$ns" "$deploy"

    # Setting fields to null via merge patch deletes them.
    kubectl -n "$ns" patch deployment "$deploy" --type='merge' -p '{
      "spec": {
        "template": {
          "spec": {
            "nodeSelector": null,
            "tolerations":  null
          }
        }
      }
    }' >/dev/null 2>&1 || true
    return 0
}

# ---------------------------------------------------------------------------
# ensure_aggressor_priority_class
#
# Idempotently creates the high-priority PriorityClass referenced by
# boost_aggressor. preemptionPolicy=Never: the class jumps the scheduling
# queue but never preempts running pods, so it cannot evict the pinned
# victim mid-experiment. Safe to call repeatedly.
# ---------------------------------------------------------------------------
ensure_aggressor_priority_class() {
    kubectl get priorityclass "$PLACE_PRIORITY_CLASS" >/dev/null 2>&1 && return 0
    kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: $PLACE_PRIORITY_CLASS
value: $PLACE_PRIORITY_VALUE
globalDefault: false
preemptionPolicy: Never
description: "Stage3 aggressors: high scheduling priority, never preempts the victim."
EOF
    if [[ $? -ne 0 ]]; then
        echo "ERROR [aggressor-place]: failed to create PriorityClass $PLACE_PRIORITY_CLASS" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# boost_aggressor <namespace> <deployment>
#
# Makes a placed aggressor "loud": removes its CPU+memory limits (unlimited
# burst) and assigns the high-priority PriorityClass. Requests are kept as-is
# so the pod stays Burstable (not first to be OOM-killed). The original
# resources block is stashed in an annotation so unboost_aggressor can restore
# it. Idempotent: re-running won't clobber an existing stash. Does NOT trigger
# a rollout -- the caller's wait_aggressor_ready restart picks it up.
# ---------------------------------------------------------------------------
boost_aggressor() {
    local ns="$1"
    local deploy="$2"

    ensure_aggressor_priority_class || return 1

    # The aggressor service runs in container[0] of these single-app
    # deployments (geo/profile/compose-post/...). Resolve its name so the
    # strategic-merge patch targets the right container.
    local cname
    cname=$(kubectl -n "$ns" get deployment "$deploy" \
        -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null)
    if [[ -z "$cname" ]]; then
        echo "ERROR [aggressor-place]: cannot resolve container for $ns/$deploy" >&2
        return 1
    fi

    # Stash original resources ONCE (don't overwrite if a prior placement in
    # this run already did) so unboost restores the true manifest values.
    local existing_stash
    existing_stash=$(kubectl -n "$ns" get deployment "$deploy" -o json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata'].get('annotations',{}).get('$PLACE_BOOST_ANNOTATION',''))" 2>/dev/null)
    if [[ -z "$existing_stash" ]]; then
        local orig
        orig=$(kubectl -n "$ns" get deployment "$deploy" -o json 2>/dev/null \
            | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['spec']['template']['spec']['containers'][0].get('resources',{})))" 2>/dev/null)
        [[ -z "$orig" ]] && orig='{}'
        kubectl -n "$ns" annotate deployment "$deploy" \
            "$PLACE_BOOST_ANNOTATION=$orig" --overwrite >/dev/null 2>&1 || true
    fi

    # Drop limits (null deletes the key in a strategic merge) -> unlimited
    # cpu+mem; set the high-priority class. containers merge by name, so the
    # rest of the container spec is untouched.
    kubectl -n "$ns" patch deployment "$deploy" --type='strategic' -p "{
      \"spec\": { \"template\": { \"spec\": {
        \"priorityClassName\": \"$PLACE_PRIORITY_CLASS\",
        \"containers\": [ { \"name\": \"$cname\", \"resources\": { \"limits\": null } } ]
      }}}
    }" >/dev/null 2>&1 || {
        echo "ERROR [aggressor-place]: failed to boost $ns/$deploy" >&2
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# unboost_aggressor <namespace> <deployment>
#
# Reverses boost_aggressor: restores the stashed original resources block and
# strips priorityClassName, returning the deployment to its base shape.
# Idempotent and safe to call on a never-boosted deployment (no-op).
# ---------------------------------------------------------------------------
unboost_aggressor() {
    local ns="$1"
    local deploy="$2"

    kubectl -n "$ns" get deployment "$deploy" >/dev/null 2>&1 || return 0

    local stash
    stash=$(kubectl -n "$ns" get deployment "$deploy" -o json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['metadata'].get('annotations',{}).get('$PLACE_BOOST_ANNOTATION',''))" 2>/dev/null)

    if [[ -n "$stash" ]]; then
        local cname
        cname=$(kubectl -n "$ns" get deployment "$deploy" \
            -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null)
        if [[ -n "$cname" ]]; then
            # Replace the whole resources block so any limits we removed are
            # re-added exactly as the manifest had them.
            kubectl -n "$ns" patch deployment "$deploy" --type='strategic' -p "{
              \"spec\": { \"template\": { \"spec\": {
                \"containers\": [ { \"name\": \"$cname\", \"resources\": $stash } ]
              }}}
            }" >/dev/null 2>&1 || true
        fi
        kubectl -n "$ns" annotate deployment "$deploy" \
            "$PLACE_BOOST_ANNOTATION-" >/dev/null 2>&1 || true
    fi

    # null via merge patch deletes priorityClassName.
    kubectl -n "$ns" patch deployment "$deploy" --type='merge' -p '{
      "spec": { "template": { "spec": { "priorityClassName": null } } }
    }' >/dev/null 2>&1 || true
    return 0
}

# ---------------------------------------------------------------------------
# wait_aggressor_ready <namespace> <deployment> [timeout-seconds]
#
# Triggers a rollout restart so the new nodeSelector takes effect, then
# waits for the deployment to be Ready on the new node. Separated from
# place_aggressor so the caller can place all aggressors first (cheap
# patches) and then wait for them in parallel.
# ---------------------------------------------------------------------------
wait_aggressor_ready() {
    local ns="$1"
    local deploy="$2"
    local timeout="${3:-180}"

    kubectl -n "$ns" rollout restart deployment "$deploy" >/dev/null 2>&1 || true
    kubectl -n "$ns" rollout status  deployment "$deploy" --timeout="${timeout}s"
}

# ---------------------------------------------------------------------------
# aggressor_pod_name <namespace> <deployment-label-selector>
#
# Echoes the first matching pod name (or empty if none). Used by
# write-run-manifest.sh to record live pod identity at run time so the
# mitigation side can resolve which container produced a given counter.
# ---------------------------------------------------------------------------
aggressor_pod_name() {
    local ns="$1"
    local selector="$2"
    kubectl -n "$ns" get pods -l "$selector" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}
