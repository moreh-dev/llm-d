#!/bin/bash
set -e

# GB200 P/D cleanup script
#
# Required environment variables:
# - NAMESPACE: Kubernetes namespace (default: vllm)

NAMESPACE="${NAMESPACE:-vllm}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Removing GB200 P/D model server from namespace: $NAMESPACE"

# Remove model server pods
kubectl delete -k "$SCRIPT_DIR" -n "$NAMESPACE" --ignore-not-found

# Remove HTTPRoute
echo "Removing HTTPRoute..."
kubectl delete -f "$SCRIPT_DIR/httproute.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

# Remove InferencePool
echo "Removing InferencePool..."
helm uninstall wide-ep-gb200-infpool -n "$NAMESPACE" 2>/dev/null || true

# Remove Gateway
echo "Removing Gateway..."
kubectl delete -f "$SCRIPT_DIR/gateway.yaml" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "Cleanup complete."
