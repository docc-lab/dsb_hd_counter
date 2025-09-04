#!/bin/bash

set -e

# Check if correct number of arguments provided
if [ $# -ne 2 ]; then
    echo "Usage: $0 <node-name> <service-name>"
    echo "Example: $0 node-1 frontend"
    exit 1
fi

NODE_NAME="$1"
SERVICE_NAME="$2"

# Default taint configuration
TAINT_KEY="dedicated"
TAINT_VALUE="special"
TAINT_EFFECT="NoSchedule"

echo "=== Tainting node and adding toleration ==="
echo "Node: $NODE_NAME"
echo "Service: $SERVICE_NAME"
echo "Taint: $TAINT_KEY=$TAINT_VALUE:$TAINT_EFFECT"
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

# Taint the node
echo "1. Tainting node '$NODE_NAME'..."
kubectl taint nodes "$NODE_NAME" "$TAINT_KEY=$TAINT_VALUE:$TAINT_EFFECT" --overwrite
echo "✓ Node tainted successfully"

# Add toleration to the service
echo "2. Adding toleration to deployment '$SERVICE_NAME'..."
kubectl patch deployment "$SERVICE_NAME" -p '{
  "spec": {
    "template": {
      "spec": {
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
echo "✓ Toleration added successfully"

echo
echo "=== Operation completed ==="
echo "The deployment '$SERVICE_NAME' can now be scheduled on the tainted node '$NODE_NAME'"
echo
echo "Verify with:"
echo "  kubectl describe node $NODE_NAME | grep -A5 Taints"
echo "  kubectl get deployment $SERVICE_NAME -o yaml | grep -A10 tolerations"