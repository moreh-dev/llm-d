#!/bin/bash
set -e

# GB200 Wide-EP deployment script with P/D disaggregation
#
# Deploys:
#   - Prefill pods: deepep_high_throughput backend, port 8000
#   - Decode pods: deepep_low_latency backend + routing sidecar, port 8000 (proxy) -> 8200 (vLLM)
#   - NIXL connector for KV cache transfer between prefill and decode
#
# Required environment variables:
# - NAMESPACE: Kubernetes namespace (default: vllm)

NAMESPACE="${NAMESPACE:-vllm}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Deploying GB200 P/D disaggregated model server to namespace: $NAMESPACE"

# Deploy model server
kubectl apply -k "$SCRIPT_DIR" -n "$NAMESPACE"

echo ""
echo "Deployment submitted. Monitor with:"
echo "  kubectl get pods -n $NAMESPACE -l llm-d.ai/model=DeepSeek-V3 -w"
echo ""
echo "View prefill logs:"
echo "  kubectl logs -n $NAMESPACE -l llm-d.ai/role=prefill -f"
echo ""
echo "View decode logs:"
echo "  kubectl logs -n $NAMESPACE -l llm-d.ai/role=decode -c vllm -f"
