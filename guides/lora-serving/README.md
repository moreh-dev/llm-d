# Multi-LoRA Serving with llm-d

## Overview

[LoRA (Low-Rank Adaptation)](https://arxiv.org/abs/2106.09685) enables efficient fine-tuning by training small adapter weights instead of modifying the full model. A single base model can serve multiple LoRA adapters simultaneously, allowing enterprises to support many specialized tasks (sentiment analysis, SQL generation, code completion, etc.) from a shared GPU deployment.

llm-d combines vLLM's multi-LoRA serving with Gateway API-based routing to provide:

- **Shared infrastructure** — One base model serves all adapters, reducing GPU cost
- **Dynamic adapter management** — Load and unload adapters at runtime without restarting
- **Intelligent request routing** — Route requests to the correct adapter via the Gateway API
- **Scalable multi-tenancy** — Isolate workloads using path-based or header-based routing

### Architecture

```text
                        ┌──────────────────────────────────────────┐
                        │              Kubernetes Cluster          │
                        │                                          │
  Client ──► Gateway ──►│  HTTPRoute ──► InferencePool ──► vLLM    │
                        │                                   │      │
                        │                          ┌────────┴────┐ │
                        │                          │ Base Model  │ │
                        │                          │ (Llama 3.1) │ │
                        │                          │             │ │
                        │                          │ + LoRA A    │ │
                        │                          │ + LoRA B    │ │
                        │                          └─────────────┘ │
                        └──────────────────────────────────────────┘
```

Clients select an adapter by setting the `model` field in OpenAI-compatible API requests. The Gateway routes the request to the InferencePool, which forwards it to a vLLM instance serving that adapter.

## Prerequisites

* All prerequisites from the [upper level](../README.md).
* Have the [proper client tools installed on your local system](../prereq/client-setup/README.md) to use this guide.
* Ensure your cluster infrastructure is sufficient to [deploy high scale inference](../prereq/infrastructure/README.md).
* Configure and deploy your [Gateway control plane](../prereq/gateway-provider/README.md).
* Have the [Monitoring stack](../../docs/monitoring/README.md) installed on your system.
* Create a namespace for installation.

  ```bash
  export NAMESPACE=llm-d-lora # or any other namespace (shorter names recommended)
  kubectl create namespace ${NAMESPACE}
  ```

* [Create the `llm-d-hf-token` secret in your target namespace with the key `HF_TOKEN` matching a valid HuggingFace token](../prereq/client-setup/README.md#huggingface-token) to pull models.
* [Choose an llm-d version](../prereq/client-setup/README.md#llm-d-version)

## Deploy Base Model with LoRA Support

```bash
cd guides/lora-serving
```

### Deploy Gateway and HTTPRoute

Deploy the Gateway and HTTPRoute. This extends the [Istio gateway recipe](../recipes/gateway/istio) with a single HTTPRoute that sends all traffic to the InferencePool.

```bash
kubectl apply -k ./gateway -n ${NAMESPACE}
```

### Deploy vLLM Model Server

This guide provides two modes of LoRA serving. Choose the one that fits your use case:

- **Preloaded** — Adapters are specified at startup and always available. Best for stable, known workloads.
- **Runtime-Loaded** — Adapters are loaded and unloaded dynamically via API. Best for experimentation or multi-tenant platforms.

<!-- TABS:START -->

<!-- TAB:Preloaded:default -->
#### Preloaded Adapters

Deploy the vLLM model server with LoRA adapters specified at startup. The adapters will be downloaded and loaded when the pod starts.

```bash
kubectl apply -k ./vllm/overlays/preloaded -n ${NAMESPACE}
```

This configuration preloads two adapters on `meta-llama/Llama-3.1-8B-Instruct`:
- `sql-lora` — `FinGPT/fingpt-forecaster_llama3-8b_lora`
- `sentiment-lora` — `FinGPT/fingpt-sentiment_llama3-8b_lora`

<!-- TAB:Runtime-Loaded -->
#### Runtime-Loaded Adapters

Deploy the vLLM model server with LoRA enabled but no adapters preloaded. Adapters are loaded dynamically via the vLLM API.

```bash
kubectl apply -k ./vllm/overlays/runtime-loaded -n ${NAMESPACE}
```

This configuration sets `VLLM_ALLOW_RUNTIME_LORA_UPDATING=True`, which enables the `/v1/load_lora_adapter` and `/v1/unload_lora_adapter` API endpoints.

<!-- TABS:END -->

### Deploy InferencePool

To deploy the `InferencePool`, select your provider below.

<!-- TABS:START -->

<!-- TAB:GKE:default -->

#### GKE

This command deploys the `InferencePool` on GKE with GKE-specific monitoring enabled.

```bash
helm install llm-d-infpool \
    -n ${NAMESPACE} \
    -f ../recipes/inferencepool/values.yaml \
    --set "provider.name=gke" \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.3.0
```

<!-- TAB:Istio -->

#### Istio

This command deploys the `InferencePool` with Istio, enabling Prometheus monitoring.

```bash
helm install llm-d-infpool \
    -n ${NAMESPACE} \
    -f ../recipes/inferencepool/values.yaml \
    --set "provider.name=istio" \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.3.0
```

<!-- TAB:Kgateway -->

#### Kgateway

This command deploys the `InferencePool` with Kgateway.

```bash
helm install llm-d-infpool \
    -n ${NAMESPACE} \
    -f ../recipes/inferencepool/values.yaml \
    --set "provider.name=kgateway" \
    oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool \
    --version v1.3.0
```

<!-- TABS:END -->

## Verifying the Installation

You can verify the installation by checking the status of the created resources.

### Check the Gateway

```bash
kubectl get gateway -n ${NAMESPACE}
```

You should see output similar to the following, with the `PROGRAMMED` status as `True`.

```text
NAME                      CLASS                              ADDRESS     PROGRAMMED   AGE
llm-d-inference-gateway   gke-l7-regional-external-managed   <redacted>  True         16m
```

### Check the HTTPRoute

```bash
kubectl get httproute -n ${NAMESPACE}
```

```text
NAME          HOSTNAMES   AGE
llm-d-route               17m
```

### Check the InferencePool

```bash
kubectl get inferencepool -n ${NAMESPACE}
```

```text
NAME            AGE
llm-d-infpool   16m
```

### Check the Pods

```bash
kubectl get pods -n ${NAMESPACE}
```

You should see the InferencePool's endpoint pod and the model server pod in a `Running` state.

```text
NAME                                  READY   STATUS    RESTARTS   AGE
llm-d-infpool-epp-xxxxxxxx-xxxxx     1/1     Running   0          16m
llm-d-model-server-xxxxxxxx-xxxxx    1/1     Running   0          11m
```

### Verify Loaded Adapters

Once the model server pod is running, verify the available models (including adapters):

```bash
export MODEL_POD=$(kubectl get pods -n ${NAMESPACE} -l llm-d.ai/inference-serving=true -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n ${NAMESPACE} ${MODEL_POD} 8000:8000 &
curl -s http://localhost:8000/v1/models | python3 -m json.tool
```

For the **preloaded** configuration, you should see the base model and both adapters:

```json
{
    "data": [
        {"id": "meta-llama/Llama-3.1-8B-Instruct", "object": "model"},
        {"id": "sql-lora", "object": "model"},
        {"id": "sentiment-lora", "object": "model"}
    ]
}
```

For the **runtime-loaded** configuration, you will initially see only the base model. Adapters appear after loading them (see [Runtime-Loaded LoRA Mode](#runtime-loaded-lora-mode)).

## Preloaded LoRA Mode

When adapters are preloaded at startup (via `--lora-modules`), they are immediately available for inference. Select an adapter by setting the `model` field in your request.

### Query the Base Model

```bash
export GATEWAY_IP=$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')

curl -s ${GATEWAY_IP}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-3.1-8B-Instruct",
    "messages": [{"role": "user", "content": "What is machine learning?"}],
    "max_tokens": 100
  }'
```

### Query a LoRA Adapter

To route a request to a specific adapter, set the `model` field to the adapter name:

```bash
curl -s ${GATEWAY_IP}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "sql-lora",
    "messages": [{"role": "user", "content": "Predict the stock trend for AAPL next week."}],
    "max_tokens": 100
  }'
```

```bash
curl -s ${GATEWAY_IP}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "sentiment-lora",
    "messages": [{"role": "user", "content": "Analyze the sentiment: The company reported record earnings and raised guidance for the next quarter."}],
    "max_tokens": 100
  }'
```

### Memory Impact

Each preloaded adapter consumes GPU memory at startup. The memory overhead depends on the adapter rank and the number of target modules:

- A rank-16 adapter for Llama 3.1 8B uses approximately 50-100 MB of GPU memory
- A rank-64 adapter uses approximately 200-400 MB
- The `--max-cpu-loras` flag offloads inactive adapters to CPU memory, reducing GPU pressure

With `--max-loras 3`, at most 3 adapters will be active in GPU memory simultaneously. Additional adapters (up to `--max-cpu-loras`) are kept in CPU memory and swapped in as needed.

## Runtime-Loaded LoRA Mode

When using the runtime-loaded configuration, the server starts with only the base model. Adapters are loaded and unloaded dynamically via the vLLM API.

### Register Adapters with the Helper Script

The [`register-adapters.sh`](./register-adapters.sh) script automates adapter registration across all model-server pods. Edit the `ADAPTERS` array in the script to define your adapters, then run:

```bash
./register-adapters.sh ${NAMESPACE}
```

The script port-forwards to each pod, loads every adapter, and reports success/failure per pod. This is especially useful when running multiple replicas, since runtime-loaded adapters must be registered on each pod individually.

### Load an Adapter Manually

To load a single adapter on one pod:

```bash
export MODEL_POD=$(kubectl get pods -n ${NAMESPACE} -l llm-d.ai/inference-serving=true -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n ${NAMESPACE} ${MODEL_POD} 8000:8000 &

curl -s -X POST http://localhost:8000/v1/load_lora_adapter \
  -H "Content-Type: application/json" \
  -d '{
    "lora_name": "sql-lora",
    "lora_path": "FinGPT/fingpt-forecaster_llama3-8b_lora"
  }'
```

Verify the adapter is loaded:

```bash
curl -s http://localhost:8000/v1/models | python3 -m json.tool
```

You should now see `sql-lora` in the model list. You can then query it through the Gateway as shown in [Query a LoRA Adapter](#query-a-lora-adapter).

### Unload an Adapter

```bash
curl -s -X POST http://localhost:8000/v1/unload_lora_adapter \
  -H "Content-Type: application/json" \
  -d '{
    "lora_name": "sql-lora"
  }'
```

### Cold vs Warm Latency

- **Cold load** — The first time an adapter is loaded, vLLM downloads the weights from HuggingFace and initializes them. This can take 10-60 seconds depending on adapter size and network speed.
- **Warm load** — If the adapter weights are already cached locally (in `/data` or the HuggingFace cache), loading is near-instant (sub-second).

### When to Use Runtime vs Preloaded

| Consideration | Preloaded | Runtime-Loaded |
| :--- | :--- | :--- |
| Startup latency | Higher (downloads all adapters) | Lower (base model only) |
| Request latency | No cold-start penalty | First request may have cold-start |
| Adapter management | Requires redeployment to change | Load/unload via API |
| Best for | Stable, known workloads | Experimentation, multi-tenant platforms |
| Operational complexity | Lower | Higher (need to manage adapter lifecycle) |

## Gateway-Based Routing

You can use Gateway API HTTPRoutes to create dedicated endpoints for each adapter, enabling multi-tenant isolation without modifying client code.

### Path-Based Routing

Create separate path prefixes for each adapter. This allows clients to call a fixed URL without needing to set the `model` field.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: lora-sql-route
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: llm-d-inference-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /sql
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: llm-d-infpool
          port: 8000
      timeouts:
        backendRequest: 0s
        request: 0s
```

With this route, clients can call:

```bash
curl -s ${GATEWAY_IP}/sql/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "sql-lora",
    "messages": [{"role": "user", "content": "Predict the stock trend for AAPL."}],
    "max_tokens": 100
  }'
```

### Header-Based Routing

Route requests based on HTTP headers, useful for tenant isolation:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: lora-tenant-route
spec:
  parentRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: llm-d-inference-gateway
  rules:
    - matches:
        - headers:
            - name: x-tenant
              value: finance
      backendRefs:
        - group: inference.networking.k8s.io
          kind: InferencePool
          name: llm-d-infpool
          port: 8000
      timeouts:
        backendRequest: 0s
        request: 0s
```

Clients include the tenant header:

```bash
curl -s ${GATEWAY_IP}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-tenant: finance" \
  -d '{
    "model": "sql-lora",
    "messages": [{"role": "user", "content": "Predict the stock trend for AAPL."}],
    "max_tokens": 100
  }'
```

This pattern enables multi-tenant isolation at the Gateway layer without requiring RBAC or namespace separation per tenant.

## Operational Guidance

### Memory Model

vLLM GPU memory is divided between three components:

| Component | Description | Approximate Size (Llama 3.1 8B FP16) |
| :--- | :--- | :--- |
| Base model weights | The full model parameters | ~16 GB |
| KV cache | Per-request key-value cache | Remainder of GPU memory |
| LoRA adapter weights | Delta weights for each active adapter | 50-400 MB per adapter |

LoRA adapter weights are small relative to the base model, but they reduce the available KV cache space. Monitor KV cache utilization via the `vllm:kv_cache_usage_perc` metric.

### Adapter Limits and OOM

- `--max-loras` controls how many adapters can be active in GPU memory simultaneously
- `--max-cpu-loras` controls how many additional adapters are cached in CPU memory
- `--max-lora-rank` sets the maximum rank supported (higher rank = more memory per adapter)
- If total GPU memory is exhausted (base model + KV cache + active adapters), vLLM will queue or reject requests — not OOM-crash

Start with conservative limits (`--max-loras 2-3`) and increase based on observed KV cache utilization.

### Multi-Replica Behavior

When running multiple replicas:

- **Preloaded mode** — All replicas load the same adapters at startup. The InferencePool load-balances requests across replicas.
- **Runtime-loaded mode** — Each replica manages its own adapter set independently. Loading an adapter on one replica does not affect others. You must load adapters on each replica individually or use an orchestration layer.

For runtime-loaded mode with multiple replicas, consider using a DaemonSet-style approach or a controller to ensure adapters are loaded consistently across replicas.

### Production Recommendations

- Use **preloaded mode** for production workloads with a known, stable set of adapters
- Set `--max-loras` to the number of adapters you need to serve concurrently
- Set `--max-cpu-loras` higher than `--max-loras` to cache additional adapters in CPU memory
- Monitor `vllm:kv_cache_usage_perc` — keep it below 90% to avoid request queuing
- Use `--max-lora-rank 64` unless your adapters require higher rank
- Consider separate InferencePools for different adapter groups if you need resource isolation

## Cleanup

To remove the deployment:

```bash
helm uninstall llm-d-infpool -n ${NAMESPACE}
```

<!-- TABS:START -->

<!-- TAB:Preloaded:default -->

```bash
kubectl delete -k ./vllm/overlays/preloaded -n ${NAMESPACE}
```

<!-- TAB:Runtime-Loaded -->

```bash
kubectl delete -k ./vllm/overlays/runtime-loaded -n ${NAMESPACE}
```

<!-- TABS:END -->

Delete the Gateway and HTTPRoute:

```bash
kubectl delete -k ./gateway -n ${NAMESPACE}
```

Delete any custom HTTPRoutes created for routing:

```bash
kubectl delete httproute lora-sql-route lora-tenant-route -n ${NAMESPACE} 2>/dev/null
```

Delete the namespace:

```bash
kubectl delete namespace ${NAMESPACE}
```
