#!/bin/bash

set -e

# Check if correct number of arguments provided
if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    echo "Usage: $0 <node-name> <service-name> [--untolerate] [--restart-all]"
    echo "Examples:"
    echo "  $0 node-1 frontend                    # Add taint and toleration"
    echo "  $0 node-1 frontend --untolerate       # Remove taint and toleration"
    echo "  $0 node-1 frontend --restart-all      # Add taint, toleration, and restart all deployments"
    echo "  $0 node-1 frontend --untolerate --restart-all  # Remove taint/toleration and restart all"
    exit 1
fi

NODE_NAME="$1"
SERVICE_NAME="$2"
UNTOLERATE_MODE=false
RESTART_ALL=false

# Parse optional flags
for arg in "${@:3}"; do
    if [ "$arg" == "--untolerate" ]; then
        UNTOLERATE_MODE=true
    elif [ "$arg" == "--restart-all" ]; then
        RESTART_ALL=true
    else
        echo "Error: Unknown flag '$arg'"
        exit 1
    fi
done

# Default taint configuration
TAINT_KEY="dedicated"
TAINT_VALUE="special"
TAINT_EFFECT="NoSchedule"

if [ "$UNTOLERATE_MODE" == "true" ]; then
    echo "=== Removing taint and toleration ==="
else
    echo "=== Adding taint and toleration ==="
fi
echo "Node: $NODE_NAME"
echo "Service: $SERVICE_NAME"
echo "Taint: $TAINT_KEY=$TAINT_VALUE:$TAINT_EFFECT"
if [ "$RESTART_ALL" == "true" ]; then
    echo "Restart all deployments: YES"
fi
echo

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed"
    exit 1
fi

# Check if node exists
if ! kubectl get node "$NODE_NAME" &> /dev/null; then
    echo "Error: Node '$NODE_NAME' does not exist"
    exit 1
fi

# Check if service (deployment) exists
if ! kubectl get deployment "$SERVICE_NAME" &> /dev/null; then
    echo "Error: Deployment '$SERVICE_NAME' does not exist"
    exit 1
fi

if [ "$UNTOLERATE_MODE" == "true" ]; then
    # Remove taint from node
    echo "1. Removing taint from node '$NODE_NAME'..."
    kubectl taint nodes "$NODE_NAME" "$TAINT_KEY-" || echo "Note: Taint may not exist or already removed"
    echo " Taint removal attempted"

    # Remove toleration and nodeSelector from deployment
    echo "2. Removing toleration and nodeSelector from deployment '$SERVICE_NAME'..."
    # Get current deployment spec and remove tolerations and nodeSelector
    kubectl patch deployment "$SERVICE_NAME" --type='merge' -p '{
      "spec": {
        "template": {
          "spec": {
            "tolerations": null,
            "nodeSelector": null
          }
        }
      }
    }'
    echo " Tolerations and nodeSelector removed successfully"

    # Trigger rollout to apply changes
    echo "3. Rolling out deployment to apply changes..."
    kubectl rollout restart deployment "$SERVICE_NAME"
    echo " Rollout triggered"

    echo "4. Waiting for rollout to complete..."
    kubectl rollout status deployment "$SERVICE_NAME" --timeout=60s
    echo " Rollout completed successfully"
    
    # Restart all deployments if requested
    if [ "$RESTART_ALL" == "true" ]; then
        echo "5. Restarting all other deployments to respect taint..."
        deployments=$(kubectl get deployments -o name --no-headers)
        deployment_count=$(echo "$deployments" | wc -l)
        echo "Found $deployment_count deployments total"
        
        echo "$deployments" | while read -r deployment; do
            deployment_name=$(echo "$deployment" | cut -d'/' -f2)
            if [ "$deployment_name" != "$SERVICE_NAME" ]; then  # Skip the one we already restarted
                echo "  Restarting $deployment_name..."
                kubectl rollout restart "$deployment"
            fi
        done
        
        echo " All other deployments restart triggered"
        echo "6. Waiting for all deployments to stabilize..."
        echo "$deployments" | while read -r deployment; do
            deployment_name=$(echo "$deployment" | cut -d'/' -f2)
            echo "  Waiting for $deployment_name..."
            kubectl rollout status "$deployment" --timeout=30s
        done
        echo " All deployments stabilized"
    fi

else
    # Original taint and tolerate logic
    # Taint the node
    echo "1. Tainting node '$NODE_NAME'..."
    kubectl taint nodes "$NODE_NAME" "$TAINT_KEY=$TAINT_VALUE:$TAINT_EFFECT" --overwrite
    echo " Node tainted successfully"

    # Add toleration and nodeSelector to the service
    echo "2. Adding toleration and nodeSelector to deployment '$SERVICE_NAME'..."
    kubectl patch deployment "$SERVICE_NAME" -p '{
      "spec": {
        "template": {
          "spec": {
            "nodeSelector": {
              "kubernetes.io/hostname": "'$NODE_NAME'"
            },
            "tolerations": [
              {
                "key": "'$TAINT_KEY'",
                "operator": "Equal",
                "value": "'$TAINT_VALUE'",
                "effect": "'$TAINT_EFFECT'"
              }
            ]
          }
        }
      }
    }'
    echo " Toleration and nodeSelector added successfully"

    # Trigger rollout to apply tolerations to running pods
    echo "3. Rolling out deployment to apply tolerations..."
    kubectl rollout restart deployment "$SERVICE_NAME"
    echo " Rollout triggered"

    echo "4. Waiting for rollout to complete..."
    kubectl rollout status deployment "$SERVICE_NAME" --timeout=60s
    echo " Rollout completed successfully"

    # Restart all deployments if requested
    if [ "$RESTART_ALL" == "true" ]; then
        echo "5. Restarting all deployments to respect taint..."
        deployments=$(kubectl get deployments -o name --no-headers)
        deployment_count=$(echo "$deployments" | wc -l)
        echo "Found $deployment_count deployments to restart"
        
        echo "$deployments" | while read -r deployment; do
            deployment_name=$(echo "$deployment" | cut -d'/' -f2)
            if [ "$deployment_name" != "$SERVICE_NAME" ]; then  # Skip the one we already restarted
                echo "  Restarting $deployment_name..."
                kubectl rollout restart "$deployment"
            fi
        done
        
        echo " All deployments restart triggered"
        echo "6. Waiting for all deployments to stabilize..."
        echo "$deployments" | while read -r deployment; do
            echo "  Waiting for $deployment..."
            kubectl rollout status "$deployment" --timeout=30s
        done
        echo " All deployments completed"
    fi
fi

echo
echo "=== Operation completed ==="
if [ "$UNTOLERATE_MODE" == "true" ]; then
    echo "The taint has been removed from node '$NODE_NAME' and tolerations/nodeSelector removed from deployment '$SERVICE_NAME'"
    if [ "$RESTART_ALL" == "true" ]; then
        echo "All deployments have been restarted and can now be scheduled on any available node"
    fi
else
    echo "The deployment '$SERVICE_NAME' is now pinned to node '$NODE_NAME' (via nodeSelector and toleration)"
    if [ "$RESTART_ALL" == "true" ]; then
        echo "All other deployments have been restarted and will avoid the tainted node (unless they have tolerations)"
    fi
fi
echo
echo "Verify with:"
echo "  kubectl describe node $NODE_NAME | grep -A5 Taints"
echo "  kubectl get deployment $SERVICE_NAME -o yaml | grep -A10 tolerations"
echo "  kubectl get deployment $SERVICE_NAME -o yaml | grep -A5 nodeSelector"
echo "  kubectl get pods -o wide  # Check pod distribution across nodes"