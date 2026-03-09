# Runtime-Loaded LoRA Adapters with Persistent Volume

This overlay configures vLLM to load LoRA adapters at runtime from a persistent volume, allowing you to dynamically add and update adapters without redeploying pods.

## Features

- **Persistent Storage**: 100Gi PersistentVolumeClaim for storing LoRA adapters
- **Runtime Loading**: Adapters can be added/updated without pod restarts
- **Shared Access**: ReadWriteMany access mode allows multiple pods to share adapters
- **Cache Directory**: `/lora-adapters` mounted from persistent volume

## Prerequisites

- A storage class that supports `ReadWriteMany` access mode (e.g., NFS, CephFS, Azure Files, GCP Filestore)
- Sufficient storage quota for 100Gi (adjust in [`pvc.yaml`](pvc.yaml) if needed)

## Deployment

In folder `guides/lora-serving` of the project:

- in file `kustomization.yaml` uncomment option `- ./vllm/overlays/runtime-loaded-from-pv`

- run:
```bash
kustomize build --enable-helm . | kubectl apply -f -
```

## Adding LoRA Adapters

### Option 1: Manually copy adapters to the persistent volume
 - Get pod name:
 ```bash
POD_NAME=$(kubectl get pods -l llm-d.ai/inference-serving=true -o jsonpath='{.items[0].metadata.name}')
```

 - Copy adapter directory:
  ```bash
kubectl cp </path/to/local/adapter> $POD_NAME:/lora-adapters/adapter-name
```

### Option 2: Copy adapters from HuggingFace cache

In a case HuggingFace LoRA adpaters were previously loaded to the cache folder on pod, use the provided [`copy_lora_structure.sh`](copy_lora_structure.sh) script to copy LoRA adapters from the HuggingFace cache to the persistent volume. This script automatically filters out base models and only copies actual LoRA adapters.

**How it works:**
- Scans the HuggingFace cache directory (`/var/lib/llm-d/.hf/hub`)
- Identifies LoRA adapters by checking for adapter-specific files:
  - `adapter_config.json`
  - `adapter_model.safetensors` or `adapter_model.bin`
- Skips base models that don't have these files
- Copies only the adapters to `/lora-adapters`

**Usage:**

1. Get the pod name:

```bash
POD_NAME=$(kubectl get pods -l llm-d.ai/inference-serving=true -o jsonpath='{.items[0].metadata.name}')
```

2. Copy the script to the pod:

```bash
kubectl cp guides/lora-serving/vllm/overlays/runtime-loaded-from-pv/copy_lora_structure.sh \
  $POD_NAME:/tmp/copy_lora_structure.sh
```

3. Execute the script on the pod:

```bash
kubectl exec -it $POD_NAME -- bash -c "chmod +x /tmp/copy_lora_structure.sh && /tmp/copy_lora_structure.sh"
```


The script will output which adapters were copied and which models were skipped. Here is an example output:

```
Copied LoRA adapter: /lora-adapters/nvidia-llama-3.1-nemoguard-8b-topic-control
Copied LoRA adapter: /lora-adapters/algoprog-fact-generation-llama-3.1-8b-instruct-lora
Skipping base model: meta-llama-Llama-3.1-8B-Instruct (no adapter files found)
LoRA adapter copy complete. Adapters are in: /lora-adapters
```


## Using LoRA Adapters

Once adapters are in the persistent volume, reference them in your API requests:

```bash
curl -s "http://your-service/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "your-adapter-name",
        "messages": [{"role": "user", "content": "Your prompt here"}],
        "max_tokens": 100
    }'
```

Adapter is automatically loaded (if found and valid), and stays registered (and potentially loaded) for future requests

All vLLM pods share the same persistent volume, allowing them to access the same set of LoRA adapters without duplication.

## Configuration

### Storage Size

Modify the storage size in [`pvc.yaml`](pvc.yaml):

```yaml
resources:
  requests:
    storage: 100Gi  # Adjust as needed
```

### Storage Class

If you need a specific storage class, uncomment and set in [`pvc.yaml`](pvc.yaml):

```yaml
storageClassName: your-storage-class
```

### Cache Directory

The cache directory is set to `/lora-adapters`. To change it, update both:
1. The `VLLM_LORA_RESOLVER_CACHE_DIR` environment variable in [`kustomization.yaml`](kustomization.yaml)
2. The `volumeMounts.mountPath` in [`kustomization.yaml`](kustomization.yaml)


