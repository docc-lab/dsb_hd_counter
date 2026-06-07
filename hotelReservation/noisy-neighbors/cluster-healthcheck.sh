#!/bin/bash
# ===========================================================================
# cluster-healthcheck.sh
#
# Read-only pre-flight check for the hotelReservation noisy-neighbors testbed.
# Run before a batch of experiments to confirm the cluster is in a state where
# data-collector.sh can actually succeed.
#
# Checks (each is independent; a failure in one does NOT skip the rest):
#   1. kubectl reachable + all nodes Ready
#   2. /dev/cpu exists on the target node (required for in-pod MSR reader)
#   3. All baseline microservice deployments are Available with desired==ready
#   4. No pods stuck off-Running (Pending, ContainerCreating, CrashLoopBackOff,
#      ImagePullBackOff, etc.)
#   5. No orphan ReplicaSets (deployments with multiple RSes whose .spec.replicas > 0)
#   6. search deployment affinity is sane (NOT 'NotIn $TARGET_NODE')
#   7. Consul is reachable and has no stale srv-* entries (Address not in current pod IPs)
#   8. End-to-end hotels endpoint probe via frontend returns HTTP 200
#   9. No leftover stress pods from a previous run
#
# Usage:
#   ./cluster-healthcheck.sh [TARGET_NODE]
#
#   TARGET_NODE defaults to node-3 (matches your current configs).
#
# Env vars:
#   VICTIM_SERVICES="search frontend"   # whitespace-sep list of victim services
#                                       # used by your configs. Orphan ReplicaSets
#                                       # / stale Consul entries for THESE are
#                                       # auto-healed by data-collector.sh and
#                                       # demoted from FAIL to WARN here.
#
# Exit codes:
#   0 = all checks passed (warnings are OK)
#   1 = one or more checks failed (see PASS/FAIL summary at the end)
# ===========================================================================

set -u

TARGET_NODE="${1:-node-3}"
VICTIM_SERVICES="${VICTIM_SERVICES:-search}"

# Color helpers; degrade gracefully when not a TTY.
if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_RESET=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

PASS=()
FAIL=()
WARN=()

pass() { PASS+=("$1"); printf '  %s[PASS]%s %s\n'         "$C_GREEN"  "$C_RESET" "$1"; }
fail() { FAIL+=("$1"); printf '  %s[FAIL]%s %s\n'         "$C_RED"    "$C_RESET" "$1"; }
warn() { WARN+=("$1"); printf '  %s[WARN]%s %s\n'         "$C_YELLOW" "$C_RESET" "$1"; }
hdr()  { printf '\n%s=== %s ===%s\n' "$C_BLUE" "$1" "$C_RESET"; }

# Baseline microservice set the testbed expects to be Running.
EXPECTED_DEPLOYMENTS=(
    consul frontend search geo profile rate recommendation reservation user
    jaeger
    memcached-profile memcached-rate memcached-reserve
    mongodb-geo mongodb-profile mongodb-rate mongodb-recommendation
    mongodb-reservation mongodb-user
)

# Services Consul should know about (used by frontend).
EXPECTED_CONSUL_SERVICES=(srv-search srv-geo srv-profile srv-rate srv-recommendation srv-reservation srv-user)

# ---------------------------------------------------------------------------
hdr "1. kubectl + node status"
if ! kubectl version --client >/dev/null 2>&1; then
    fail "kubectl not available"
    echo
    echo "Cannot proceed without kubectl. Fix this first."
    exit 1
fi
if ! kubectl get nodes >/dev/null 2>&1; then
    fail "kubectl cannot reach the cluster"
    exit 1
fi

NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null \
    | awk '$2 != "Ready" {print $1 " ("$2")"}')
if [[ -n "$NOT_READY" ]]; then
    fail "Nodes not Ready: $(echo "$NOT_READY" | tr '\n' ',' | sed 's/,$//')"
else
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    pass "All $NODE_COUNT nodes are Ready"
fi

if ! kubectl get node "$TARGET_NODE" >/dev/null 2>&1; then
    fail "TARGET_NODE '$TARGET_NODE' does not exist"
fi

# ---------------------------------------------------------------------------
hdr "2. /dev/cpu on $TARGET_NODE (required for MSR reader)"
# We can't directly ssh into the node, but we CAN run a debug pod pinned to
# it with a hostPath check. Use kubectl debug if available; otherwise launch
# a one-shot pod with the right toleration/affinity.
if kubectl get pods -l io.kompose.service=search -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null \
   | tr ' ' '\n' | grep -qx "$TARGET_NODE"; then
    # If the live search pod is running on $TARGET_NODE, we know /dev/cpu is
    # mountable there - kubelet only lets it run if the hostPath check passes.
    pass "/dev/cpu hostPath is mountable on $TARGET_NODE (live search pod confirms it)"
else
    warn "No live search pod on $TARGET_NODE; cannot directly confirm /dev/cpu exists"
    echo "       To verify manually:  ssh $TARGET_NODE 'ls /dev/cpu && lsmod | grep msr'"
fi

# ---------------------------------------------------------------------------
hdr "3. Baseline deployments Available (ready == desired)"
for dep in "${EXPECTED_DEPLOYMENTS[@]}"; do
    if ! kubectl get deployment "$dep" >/dev/null 2>&1; then
        fail "deployment '$dep' missing"
        continue
    fi
    READY=$(kubectl get deployment "$dep" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    DESIRED=$(kubectl get deployment "$dep" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    READY=${READY:-0}; DESIRED=${DESIRED:-0}
    if [[ "$READY" == "$DESIRED" && "$READY" != "0" ]]; then
        pass "$dep: $READY/$DESIRED"
    else
        fail "$dep: $READY/$DESIRED (not Available)"
    fi
done

# ---------------------------------------------------------------------------
hdr "4. No pods stuck off-Running"
STUCK=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null \
    | awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {print $1"/"$2" "$4" "$6}')
if [[ -z "$STUCK" ]]; then
    pass "No off-Running pods"
else
    fail "Pods stuck off-Running:"
    echo "$STUCK" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
hdr "5. No orphan ReplicaSets"
# For each deployment in default ns, count RSes whose spec.replicas > 0.
# A healthy deployment has exactly 1. Orphans for victim services (search,
# frontend, ...) are auto-healed by reap_orphan_replicasets at the top of
# every data-collector.sh run, so demote those to WARN. Orphans for any
# OTHER deployment indicate a real cluster-controller issue that won't
# self-heal -- keep those as FAIL.
ORPHAN_REPORT_FAIL=()
ORPHAN_REPORT_WARN=()
is_victim() {
    local name="$1"
    for v in $VICTIM_SERVICES; do
        [[ "$name" == "$v" ]] && return 0
    done
    return 1
}
while read -r dep; do
    [[ -z "$dep" ]] && continue
    ACTIVE_RS=$(kubectl get rs -n default -l io.kompose.service="$dep" \
        -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name} {end}' 2>/dev/null)
    # Fallback to app= label
    if [[ -z "$ACTIVE_RS" ]]; then
        ACTIVE_RS=$(kubectl get rs -n default -l app="$dep" \
            -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name} {end}' 2>/dev/null)
    fi
    RS_COUNT=$(echo "$ACTIVE_RS" | wc -w)
    if (( RS_COUNT > 1 )); then
        if is_victim "$dep"; then
            ORPHAN_REPORT_WARN+=("$dep has $RS_COUNT active ReplicaSets: $ACTIVE_RS")
        else
            ORPHAN_REPORT_FAIL+=("$dep has $RS_COUNT active ReplicaSets: $ACTIVE_RS")
        fi
    fi
done < <(kubectl get deployments -n default -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
if [[ ${#ORPHAN_REPORT_FAIL[@]} -eq 0 && ${#ORPHAN_REPORT_WARN[@]} -eq 0 ]]; then
    pass "Every deployment has exactly one active ReplicaSet"
else
    for line in "${ORPHAN_REPORT_WARN[@]}"; do
        warn "$line (auto-healed by data-collector.sh::reap_orphan_replicasets)"
    done
    for line in "${ORPHAN_REPORT_FAIL[@]}"; do
        fail "$line (non-victim deployment; the reaper does NOT touch this)"
    done
fi

# ---------------------------------------------------------------------------
hdr "6. search deployment affinity sanity"
SEARCH_AFFINITY=$(kubectl get deployment search \
    -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0]}' \
    2>/dev/null)
if [[ -z "$SEARCH_AFFINITY" ]]; then
    warn "search deployment has no nodeAffinity (will be set by deploy_victim_services at run time)"
elif echo "$SEARCH_AFFINITY" | grep -q '"operator":"NotIn"' && \
     echo "$SEARCH_AFFINITY" | grep -q "\"$TARGET_NODE\""; then
    fail "search has NotIn $TARGET_NODE affinity (BUG STATE - pods will be scheduled off-target)"
    echo "         Recover with: kubectl patch deployment search --type='merge' -p '{\"spec\":{\"template\":{\"spec\":{\"affinity\":{\"nodeAffinity\":{\"requiredDuringSchedulingIgnoredDuringExecution\":{\"nodeSelectorTerms\":[{\"matchExpressions\":[{\"key\":\"kubernetes.io/hostname\",\"operator\":\"In\",\"values\":[\"$TARGET_NODE\"]}]}]}}}}}}}'"
elif echo "$SEARCH_AFFINITY" | grep -q '"operator":"In"' && \
     echo "$SEARCH_AFFINITY" | grep -q "\"$TARGET_NODE\""; then
    pass "search pinned In $TARGET_NODE"
else
    warn "search affinity is unexpected: $SEARCH_AFFINITY"
fi

# ---------------------------------------------------------------------------
hdr "7. Consul registry"
CONSUL_POD=$(kubectl get pods -l io.kompose.service=consul \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$CONSUL_POD" ]]; then
    fail "No Consul pod found"
else
    CONSUL_SVCS=$(kubectl exec "$CONSUL_POD" -- consul catalog services 2>/dev/null | tr -d '\r' || true)
    MISSING=()
    for s in "${EXPECTED_CONSUL_SERVICES[@]}"; do
        echo "$CONSUL_SVCS" | grep -qx "$s" || MISSING+=("$s")
    done
    if [[ ${#MISSING[@]} -eq 0 ]]; then
        pass "All expected services registered: ${EXPECTED_CONSUL_SERVICES[*]}"
    else
        fail "Missing from Consul: ${MISSING[*]}"
    fi

    # Stale registrations: srv-* whose Address is not in the current pod-IP set.
    CURRENT_IPS=$(kubectl get pods -o wide --no-headers 2>/dev/null | awk '{print $6}' | tr '\n' ' ')
    STALE_COUNT=$(kubectl exec "$CONSUL_POD" -- curl -s http://localhost:8500/v1/agent/services 2>/dev/null \
        | python3 -c "
import sys, json
current = set('''$CURRENT_IPS'''.split())
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit(0)
n = sum(1 for s in d.values()
        if str(s.get('Service','')).startswith('srv-') and s.get('Address','') not in current)
print(n)
" 2>/dev/null || echo 0)
    if [[ "$STALE_COUNT" -eq 0 ]]; then
        pass "No stale srv-* registrations"
    else
        # Self-healing: data-collector.sh::clean_stale_consul_services runs
        # inside validate_system_readiness on every experiment. Surface this
        # as a WARN so the operator can see it accumulated, but don't block
        # the batch.
        warn "$STALE_COUNT stale srv-* registrations in Consul (will be purged by next experiment's validation step)"
    fi
fi

# ---------------------------------------------------------------------------
hdr "8. End-to-end frontend probes"
REC_HTTP=$(kubectl exec deployment/frontend -- curl -s -o /dev/null -w '%{http_code}' \
    "http://frontend:5000/recommendations?require=price&lat=37.7749&lon=-122.4194" 2>/dev/null || echo "000")
if [[ "$REC_HTTP" == "200" ]]; then
    pass "recommendations endpoint: HTTP 200"
else
    fail "recommendations endpoint: HTTP $REC_HTTP"
fi

HOTEL_HTTP=$(kubectl exec deployment/frontend -- curl -s -o /dev/null -w '%{http_code}' \
    "http://frontend:5000/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194" 2>/dev/null || echo "000")
if [[ "$HOTEL_HTTP" == "200" ]]; then
    pass "hotels endpoint (frontend->search via Consul): HTTP 200"
else
    fail "hotels endpoint: HTTP $HOTEL_HTTP (frontend->search via Consul broken)"
fi

# ---------------------------------------------------------------------------
hdr "9. No leftover stress pods"
STRESS_LEFTOVER=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null \
    | grep -E '\b(cpu-stress|mem-stress|io-stress|stress-ng)' || true)
if [[ -z "$STRESS_LEFTOVER" ]]; then
    pass "No leftover stress pods"
else
    fail "Leftover stress pods present:"
    echo "$STRESS_LEFTOVER" | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
echo
printf '%s================================================================%s\n' "$C_BLUE" "$C_RESET"
printf '  PASS=%s%d%s  FAIL=%s%d%s  WARN=%s%d%s   (target_node=%s)\n' \
    "$C_GREEN" "${#PASS[@]}" "$C_RESET" \
    "$C_RED"   "${#FAIL[@]}" "$C_RESET" \
    "$C_YELLOW" "${#WARN[@]}" "$C_RESET" \
    "$TARGET_NODE"
printf '%s================================================================%s\n' "$C_BLUE" "$C_RESET"

if [[ ${#FAIL[@]} -gt 0 ]]; then
    echo
    echo "${C_RED}Cluster is NOT ready.${C_RESET} Failed checks:"
    for f in "${FAIL[@]}"; do echo "  - $f"; done
    exit 1
fi
echo
echo "${C_GREEN}Cluster looks good. Safe to launch experiments.${C_RESET}"
exit 0
