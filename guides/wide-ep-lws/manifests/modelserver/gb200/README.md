# GB200 NVL72 Simplified Wide-EP Deployment

Simplified deployment for GB200 NVL72 racks. Designed for debugging and initial bring-up.

**Key simplifications:**
- Single LeaderWorkerSet (no prefill/decode disaggregation)
- No NIXL connector (no KV cache transfer)
- No routing sidecar
- Uses `deepep_high_throughput` backend (more stable than `low_latency`)
- MNNVL-specific environment variables included

## Prerequisites

1. **Shared namespace**: This deployment uses the `vllm` namespace. The InferencePool
   has a unique name (`wide-ep-gb200-infpool`) to coexist with other deployments.

2. **LeaderWorkerSet controller**: Must be installed cluster-wide.
   ```bash
   kubectl apply --server-side -f \
     https://github.com/kubernetes-sigs/lws/releases/download/v0.6.2/manifests.yaml
   ```

3. **HuggingFace token**: Required to download the DeepSeek-V3 model.
   Ensure the secret exists:
   ```bash
   kubectl get secret hf-secret -n vllm
   # Create if needed:
   kubectl create secret generic hf-secret -n vllm --from-literal=HF_TOKEN=<your-token>
   ```

4. **DRA ResourceClaimTemplate**: GB200 uses Dynamic Resource Allocation.
   Ensure this exists:
   ```bash
   kubectl get resourceclaimtemplate llm-d-dev-claim -n vllm
   ```

## Quick Start

```bash
# Deploy
NAMESPACE=vllm ./deploy.sh

# Watch pods
kubectl get pods -n vllm -l llm-d.ai/model=DeepSeek-V3 -w

# View logs
kubectl logs -n vllm -l llm-d.ai/model=DeepSeek-V3 -f --tail=100

# Undeploy
NAMESPACE=vllm ./undeploy.sh
```

## Debugging Checklist

### Pod not scheduling

```bash
# Check events
kubectl describe pod -n vllm -l llm-d.ai/model=DeepSeek-V3

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

The deployment has debug logging enabled. Look for:
```bash
kubectl logs -n vllm <pod-name> -c vllm 2>&1 | grep -E "(NCCL|NVSHMEM|ERROR)"
```

Key MNNVL settings in this deployment:
- `VLLM_DEEPEP_LOW_LATENCY_USE_MNNVL=1` - Enables multi-node NVLink
- `VLLM_DEEPEP_LOW_LATENCY_ALLOW_NVLINK=1` - Allows NVLink path
- `VLLM_DEEPEP_HIGH_THROUGHPUT_FORCE_INTRA_NODE=1` - Forces intra-node for EP

### Health check failing

```bash
# Direct health check from another pod
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl -v http://<pod-ip>:8000/health
```

## Scaling Up

Once debugging is complete, you can scale by editing `modelserver.yaml`:

```yaml
spec:
  replicas: 1  # Number of LWS replicas
  leaderWorkerTemplate:
    size: 2    # Pods per replica (increase for multi-node)
```

For multi-node, also update `DP_SIZE_LOCAL` if using different GPU counts per pod.

## Enabling P/D Disaggregation

After basic deployment works, to add prefill/decode disaggregation:

1. Add `--kv_transfer_config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}'`
   to the vLLM args
2. Add the routing sidecar init container (see `../base/decode.yaml`)
3. Switch decode to use `VLLM_ALL2ALL_BACKEND=deepep_low_latency`
4. Update InferencePool to use P/D-aware scheduling plugins

## Files

- `modelserver.yaml` - LeaderWorkerSet definition
- `serviceAccount.yaml` - Kubernetes ServiceAccount
- `kustomization.yaml` - Kustomize configuration
- `inferencepool.values.yaml` - Helm values for InferencePool (if using inference gateway)
- `deploy.sh` / `undeploy.sh` - Deployment scripts

## Comparison with Elvir's Original

| Aspect | Elvir's decode.yaml | This deployment |
|--------|---------------------|-----------------|
| P/D disagg | Yes | No |
| NIXL | Yes (nixlv2) | No |
| Routing sidecar | Yes | No |
| LWS size | 2 pods | 1 pod |
| All2All backend | low_latency | high_throughput |

The `low_latency` backend with MNNVL is more complex and may have issues on
new hardware. Start with `high_throughput` to verify basic GPU/networking
setup, then transition to `low_latency` for production.
