# GB200 NVL72 Wide-EP Deployment with P/D Disaggregation

Deployment for GB200 NVL72 racks with prefill/decode disaggregation and NIXL KV cache transfer.

**Features:**
- Prefill/decode disaggregation with separate LeaderWorkerSets
- NIXL connector for KV cache transfer between prefill and decode
- Routing sidecar on decode pods
- Prefill uses `deepep_high_throughput` backend
- Decode uses `deepep_low_latency` backend with CUDA graphs
- MNNVL-specific environment variables for multi-node NVLink

## Prerequisites

1. **Shared namespace**: This deployment uses the `vllm` namespace. The InferencePool
   and HTTPRoute have unique names (`wide-ep-gb200-*`) to coexist with other deployments.

2. **Gateway**: An Istio inference gateway must be deployed. The HTTPRoute references
   `llm-d-inference-gateway` by default.

3. **LeaderWorkerSet controller**: Must be installed cluster-wide.
   ```bash
   kubectl apply --server-side -f \
     https://github.com/kubernetes-sigs/lws/releases/download/v0.6.2/manifests.yaml
   ```

4. **HuggingFace token**: Required to download the DeepSeek-R1-NVFP4 model.
   ```bash
   kubectl get secret hf-secret -n vllm
   # Create if needed:
   kubectl create secret generic hf-secret -n vllm --from-literal=HF_TOKEN=<your-token>
   ```

5. **Lustre PVC**: The deployment mounts a Lustre filesystem for model cache.
   ```bash
   kubectl get pvc lustre-pvc-vllm -n vllm
   ```

6. **DRA ResourceClaimTemplate**: GB200 uses Dynamic Resource Allocation.
   ```bash
   kubectl get resourceclaimtemplate llm-d-dev-claim -n vllm
   ```

## Quick Start

```bash
# Deploy (creates pods, InferencePool, and HTTPRoute)
NAMESPACE=vllm ./deploy.sh

# Watch pods
kubectl get pods -n vllm -l llm-d.ai/model=DeepSeek-R1-NVFP4 -w

# View prefill logs
kubectl logs -n vllm -l llm-d.ai/role=prefill -f --tail=100

# View decode logs
kubectl logs -n vllm -l llm-d.ai/role=decode -c vllm -f --tail=100

# Test the endpoint (requires x-model header for routing)
curl -H "x-model: gb200" http://llm-d-inference-gateway-istio.vllm.svc.cluster.local/v1/models

# Undeploy (removes pods, InferencePool, and HTTPRoute)
NAMESPACE=vllm ./undeploy.sh
```

## Architecture

```
                    ┌─────────────────────┐
                    │   Istio Gateway     │
                    │ (llm-d-inference-   │
                    │      gateway)       │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │     HTTPRoute       │
                    │ (wide-ep-gb200-     │
                    │      route)         │
                    └─────────┬───────────┘
                              │
                    ┌─────────▼───────────┐
                    │   InferencePool     │
                    │ (wide-ep-gb200-     │
                    │     infpool)        │
                    └─────────┬───────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
    ┌─────────▼─────────┐           ┌─────────▼─────────┐
    │   Prefill Pods    │           │   Decode Pods     │
    │ (high_throughput) │──NIXL────▶│  (low_latency)    │
    │    port 8000      │  KV xfer  │ sidecar:8000      │
    └───────────────────┘           │ vllm:8200         │
                                    └───────────────────┘
```

## Debugging Checklist

### Gateway returns "no pods available"

The InferencePool's label selector doesn't match any pods.

```bash
# Check what the InferencePool service is selecting
kubectl get svc -n vllm | grep gb200-infpool

# Check pod labels
kubectl get pods -n vllm -l llm-d.ai/model=DeepSeek-R1-NVFP4 --show-labels

# Check EPP logs
kubectl logs -n vllm -l app.kubernetes.io/name=wide-ep-gb200-infpool-epp --tail=50
```

### Pod not scheduling

```bash
# Check events
kubectl describe pod -n vllm -l llm-d.ai/model=DeepSeek-R1-NVFP4

# Check DRA claims
kubectl get resourceclaim -n vllm

# Check GPU availability
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable."nvidia\.com/gpu"
```

### Pod crashes on startup

```bash
# Get full logs including previous crash
kubectl logs -n vllm <pod-name> -c vllm --previous

# Common issues:
# 1. CUDA/driver mismatch - check NCCL_DEBUG output
# 2. Model download failure - check HF_TOKEN secret
# 3. Memory OOM - reduce DP_SIZE_LOCAL or check /dev/shm size
```

### NCCL/NVSHMEM errors

The deployment has debug logging enabled:

```bash
kubectl logs -n vllm <pod-name> -c vllm 2>&1 | grep -E "(NCCL|NVSHMEM|ERROR)"
```

Key MNNVL settings:
- `VLLM_DEEPEP_LOW_LATENCY_USE_MNNVL=1` - Enables multi-node NVLink
- `VLLM_DEEPEP_LOW_LATENCY_ALLOW_NVLINK=1` - Allows NVLink path
- `VLLM_DEEPEP_HIGH_THROUGHPUT_FORCE_INTRA_NODE=1` - Forces intra-node for EP

### NIXL connection issues

```bash
# Check NIXL side channel
kubectl logs -n vllm -l llm-d.ai/role=prefill -c vllm 2>&1 | grep -i nixl
kubectl logs -n vllm -l llm-d.ai/role=decode -c vllm 2>&1 | grep -i nixl

# Check routing sidecar on decode pods
kubectl logs -n vllm -l llm-d.ai/role=decode -c routing-proxy
```

## Scaling

Edit `prefill.yaml` and `decode.yaml`:

```yaml
spec:
  replicas: 1           # Number of LWS replicas (DP groups)
  leaderWorkerTemplate:
    size: 2             # Pods per replica (for multi-node EP)
```

For different GPU counts per pod, also update `DP_SIZE_LOCAL` environment variable.

## Switching to Unified Mode (No P/D)

For simpler debugging without prefill/decode disaggregation:

1. Edit `kustomization.yaml`:
   ```yaml
   resources:
     # Comment out P/D mode
     # - prefill.yaml
     # - decode.yaml
     # Uncomment unified mode
     - modelserver.yaml
     - serviceAccount.yaml
   ```

2. Update `inferencepool.values.yaml` to remove P/D scheduling plugins.

## Files

| File | Description |
|------|-------------|
| `prefill.yaml` | Prefill LeaderWorkerSet (high_throughput backend) |
| `decode.yaml` | Decode LeaderWorkerSet (low_latency backend + routing sidecar) |
| `modelserver.yaml` | Unified LeaderWorkerSet (no P/D, for debugging) |
| `serviceAccount.yaml` | Kubernetes ServiceAccount |
| `kustomization.yaml` | Kustomize configuration |
| `inferencepool.values.yaml` | Helm values for InferencePool with P/D scheduling |
| `httproute.yaml` | Gateway API HTTPRoute to this InferencePool |
| `deploy.sh` | Deploys pods, InferencePool, and HTTPRoute |
| `undeploy.sh` | Removes all resources |
