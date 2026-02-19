# Hello World

- install cluster dependencies (Gateway CRDs / GAIE CRDs):
```bash
./guides/prereq/gateway-provider/install-gateway-provider-dependencies.sh 
```

- install gateway provider (Istio)

```bash
helmfile apply -f ./guides/prereq/gateway-provider/istio.helmfile.yaml
```

- create ns

```bash
export NAMESPACE=llm-d-nebius
kubectl create namespace ${NAMESPACE}
```

- create hf token
```bash
export HF_TOKEN=<from Huggingface>
export HF_TOKEN_NAME=${HF_TOKEN_NAME:-llm-d-hf-token}
kubectl create secret generic ${HF_TOKEN_NAME} \
    --from-literal="HF_TOKEN=${HF_TOKEN}" \
    --namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
```

- deploy

```bash
cd guides/inference-scheduling
helmfile apply -e istio -n ${NAMESPACE}
kubectl apply -f httproute.yaml -n ${NAMESPACE}
```

- we should see
```bash
helm list -n ${NAMESPACE} 

>> NAME                            NAMESPACE       REVISION        UPDATED                                 STATUS          CHART                           APP VERSION
>> gaie-inference-scheduling       llm-d-nebius    1               2026-02-18 15:48:49.048809 -0500 EST    deployed        inferencepool-v1.3.0            v1.3.0     
>> infra-inference-scheduling      llm-d-nebius    1               2026-02-18 15:48:44.355183 -0500 EST    deployed        llm-d-infra-v1.3.6              v0.3.0     
>> ms-inference-scheduling         llm-d-nebius    1               2026-02-18 15:48:55.599343 -0500 EST    deployed        llm-d-modelservice-v0.4.5       v0.4.0 
```

```bash
robertgshaw@Roberts-MacBook-Pro inference-scheduling % kubectl get gateways -n ${NAMESPACE}
NAME                                           CLASS   ADDRESS                                                                             PROGRAMMED   AGE
infra-inference-scheduling-inference-gateway   istio   infra-inference-scheduling-inference-gateway-istio.llm-d-nebius.svc.cluster.local   True         11m
```

- port forward

```
oc port-forward -n llm-d-nebius svc/infra-inference-scheduling-inference-gateway-istio 8080:80
```

- make a curl request
```
curl http://localhost:8080/v1/models

{"data":[{"created":1771459693,"id":"Qwen/Qwen3-0.6B","max_model_len":40960,"object":"model","owned_by":"vllm","parent":null,"permission":[{"allow_create_engine":false,"allow_fine_tuning":false,"allow_logprobs":true,"allow_sampling":true,"allow_search_indices":false,"allow_view":true,"created":1771459693,"group":null,"id":"modelperm-8c56714797ab69a0","is_blocking":false,"object":"model_permission","organization":"*"}],"root":"Qwen/Qwen3-0.6B"}],"object":"list"}% 
```

# P/D

- exec into the nodes and change the filesystem

```bash
chmod -R 0777 /mnt/filesystem-x7/hf-cache
chmod -R 0777 /mnt/filesystem-x7/vllm-cache/ 
chmod -R 0777 /mnt/filesystem-x7/torch-compile-cache/
```

- got this with NIXL, had to update the container launch to set ulimit -l unlimited
```
ulimit: max locked memory: cannot modify limit: Operation not permitted
```

```
# Drain the node first
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data

# Exec into the node
kubectl debug node/$NODE -it --image=ubuntu -- bash -c "chroot /host"

# On the node
mkdir -p /etc/systemd/system/containerd.service.d/
cat > /etc/systemd/system/containerd.service.d/override.conf <<EOF
[Service]
LimitMEMLOCK=infinity
EOF

systemctl daemon-reload
systemctl restart containerd

# Uncordon
kubectl uncordon $NODE

# Check ulimit -l
kubectl debug node/$NODE -it --image=ubuntu -- /bin/bash
ulimit -l
>> ulimited
```

On some nodes, sometimes (on the same nodes sometimes It works), Im getting:
```bash
(APIServer pid=1) (EngineCore_DP0 pid=195) INFO 02-19 02:03:16 [nixl_connector.py:813] Initializing NIXL wrapper
(APIServer pid=1) (EngineCore_DP0 pid=195) INFO 02-19 02:03:16 [nixl_connector.py:814] Initializing NIXL worker 5da9310e-f1ed-46cb-b5dd-fd54d95d400e
[1771466599.213651] [ms-pd-llm-d-modelservice-prefill-dd4c9c94c-p4njb:195  :0]          parser.c:2359 UCX  WARN  unused environment variable: UCX_PREFIX
[1771466599.213651] [ms-pd-llm-d-modelservice-prefill-dd4c9c94c-p4njb:195  :0]          parser.c:2359 UCX  WARN  (set UCX_WARN_UNUSED_ENV_VARS=n to suppress this warning)
[1771466605.147536] [ms-pd-llm-d-modelservice-prefill-dd4c9c94c-p4njb:195  :1]       ib_device.c:1385 UCX  ERROR   ibv_create_ah(dlid=49152 sl=0 port=1 src_path_bits=0 dgid=fe80::9876:34ff:fee9:b3fc flow_label=0xffffffff sgid_index=0 traffic_class=0) for RC DEVX QP connect on mlx5_12 failed: No such device
```
So I set:
```
UCX_NET_DEVICES=mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_7:1,mlx5_8:1,mlx5_9:1,mlx5_10:1,mlx5_11:1
```

- this ended up giving me all valid NICS


- deploy with these env vars

```bash
cd guides/pd-disaggregation
helmfile apply -e istio -n ${NAMESPACE}
kubectl apply -f httproute.yaml -n ${NAMESPACE}
```

- make a request
```
kubectl port-forward svc/infra-pd-inference-gateway-istio -n $NAMESPACE 8000:80
```

```
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "openai/gpt-oss-120b",
    "messages": [
      {"role": "user", "content": "Hello!"}
    ]
  }'

>> {"choices":[{"finish_reason":"stop","index":0,"logprobs":null,"message":{"annotations":null,"audio":null,"content":"Hello! How can I help you today?","function_call":null,"reasoning":"User says \"Hello!\" It's a greeting. Should respond politely. No special instructions. Should be friendly.","reasoning_content":"User says \"Hello!\" It's a greeting. Should respond politely. No special instructions. Should be friendly.","refusal":null,"role":"assistant","tool_calls":[]},"stop_reason":null,"token_ids":null}],"created":1771467418,"id":"chatcmpl-ddf6dbcc-df81-4e5b-b960-51c2f1eba942","kv_transfer_params":null,"model":"openai/gpt-oss-120b","object":"chat.completion","prompt_logprobs":null,"prompt_token_ids":null,"service_tier":null,"system_fingerprint":null,"usage":{"completion_tokens":40,"prompt_tokens":67,"prompt_tokens_details":null,"total_tokens":107}}%  
```

### Benchmark

- run p/d benchmark
```bash
BENCHMARK_DIR=bench-pd-test OUTPUT_DIR=bench-pd-test-output ./run-bench.sh
```

result
```bash
"latency": {
    "request_latency": {
    "mean": 15.286510281667788,
    "min": 7.219938760999867,
    "max": 18.358723880999605,
    "p0.1": 7.376207157039831,
    "p1": 9.347114582510384,
    "p5": 11.522130686849959,
    "p10": 12.400420037998993,
    "p25": 14.307325921749907,
    "median": 16.02811132950046,
    "p75": 16.421380162998958,
    "p90": 16.747520571800305,
    "p95": 17.04093554289884,
    "p99": 17.71396104075935,
    "p99.9": 18.248000338031964
    },
```

- deploy baseline
```bash
helm uninstall ms-pd gaie-pd infra-pd -n $NAMESPACE
kubectl delete httproute llm-d-pd-disaggregation -n $NAMESPACE
kubectl apply -f baseline.yaml
```

- run baseline benchmark (raw IP is the service addr)
```bash
kubectl get services

NAME       TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
baseline   ClusterIP   10.145.51.67   <none>        8000/TCP   25m
```

```
BENCHMARK_DIR=bench-baseline-test OUTPUT_DIR=bench-baseline-test-output RAW_IP=10.145.51.67 RAW_PORT=8000  ./run-bench.sh
```

result
```
    "latency": {
      "request_latency": {
        "mean": 29.178721353981665,
        "min": 10.88147312699948,
        "max": 40.27823549800087,
        "p0.1": 11.280841469750325,
        "p1": 13.43609910445961,
        "p5": 17.140505255649533,
        "p10": 19.76468971650047,
        "p25": 25.74203602750049,
        "median": 30.335301284999332,
        "p75": 33.90098686550027,
        "p90": 36.13730210569993,
        "p95": 37.28731653069853,
        "p99": 39.2887882678109,
        "p99.9": 40.169823912800226
      },
```
