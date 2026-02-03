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

# Deploy model server pods
kubectl apply -k "$SCRIPT_DIR" -n "$NAMESPACE"

# Deploy Gateway (separate from shared gateway to avoid conflicts)
echo ""
echo "Deploying Gateway..."
kubectl apply -f "$SCRIPT_DIR/gateway.yaml" -n "$NAMESPACE"

# Deploy InferencePool (uses unique name wide-ep-gb200-infpool for shared namespace)
echo ""
echo "Deploying InferencePool..."
helm upgrade --install wide-ep-gb200-infpool \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
  --version v1.2.0 \
  -f "$SCRIPT_DIR/inferencepool.values.yaml" \
  -n "$NAMESPACE"

# Deploy HTTPRoute to route traffic to this InferencePool
echo ""
echo "Deploying HTTPRoute..."
kubectl apply -f "$SCRIPT_DIR/httproute.yaml" -n "$NAMESPACE"

# Get the gateway service URL
GATEWAY_SVC="wide-ep-gb200-inference-gateway-istio.$NAMESPACE.svc.cluster.local"

echo ""
echo "Deployment submitted. Monitor with:"
echo "  kubectl get pods -n $NAMESPACE -l llm-d.ai/model=DeepSeek-R1-NVFP4 -w"
echo ""
echo "Gateway URL:"
echo "  http://$GATEWAY_SVC"
echo ""
echo "Test endpoint:"
echo "  curl http://$GATEWAY_SVC/v1/models"
echo ""
echo "View prefill logs:"
echo "  kubectl logs -n $NAMESPACE -l llm-d.ai/role=prefill -f"
echo ""
echo "View decode logs:"
echo "  kubectl logs -n $NAMESPACE -l llm-d.ai/role=decode -c vllm -f"
