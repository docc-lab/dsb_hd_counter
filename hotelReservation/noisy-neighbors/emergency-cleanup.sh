#!/bin/bash
# Emergency cleanup script to fix current messy state
# Run this before running data-collector.sh again

echo "=== Emergency Cleanup ==="
echo "Cleaning up current messy state..."

echo "1. Cleaning up completed/failed stress pods..."
kubectl get pods --all-namespaces --field-selector=status.phase!=Running -o name 2>/dev/null | grep -E "(stress|cpu-stress|mem-stress|io-stress)" | while read -r pod; do
    if [[ -n "$pod" ]]; then
        echo "  Deleting: $pod"
        kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
    fi
done

echo "2. Cleaning up running stress pods..."
kubectl get pods --all-namespaces --field-selector=status.phase=Running -o name 2>/dev/null | grep -E "(stress|cpu-stress|mem-stress|io-stress)" | while read -r pod; do
    if [[ -n "$pod" ]]; then
        echo "  Deleting: $pod"
        kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
    fi
done

echo "3. Cleaning up pending pods..."
kubectl get pods -n default --field-selector=status.phase=Pending -o name 2>/dev/null | while read -r pod; do
    if [[ -n "$pod" ]]; then
        echo "  Deleting: $pod"
        kubectl delete "$pod" --ignore-not-found=true 2>/dev/null || true
    fi
done

echo "4. Removing anti-affinity rules from all deployments..."
kubectl get deployments -n default -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read -r deployment; do
    if [[ -n "$deployment" ]]; then
        echo "  Removing anti-affinity from: $deployment"
        kubectl patch deployment "$deployment" -n default --type='merge' -p '{
          "spec": {
            "template": {
              "spec": {
                "affinity": null
              }
            }
          }
        }' 2>/dev/null || echo "    Warning: Failed to remove anti-affinity from $deployment"
    fi
done

echo "5. Removing any taints from all nodes..."
kubectl get nodes -o name | while read -r node; do
    node_name=$(echo "$node" | cut -d'/' -f2)
    echo "  Checking node: $node_name"
    kubectl taint nodes "$node_name" dedicated- 2>/dev/null || echo "    No taint to remove from $node_name"
done

echo "6. Waiting for changes to take effect..."
sleep 15

echo "7. Current pod status:"
kubectl get pods -o wide

echo ""
echo "=== Cleanup Complete ==="
echo "You can now run data-collector.sh again"
