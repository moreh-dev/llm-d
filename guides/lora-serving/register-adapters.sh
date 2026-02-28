#!/usr/bin/env bash
# register-adapters.sh — Load LoRA adapters onto a runtime-loaded vLLM server.
#
# Usage:
#   ./register-adapters.sh [NAMESPACE]
#
# This script port-forwards to each model-server pod in the namespace and
# registers a set of LoRA adapters via the vLLM runtime API.  Adapters are
# defined in the ADAPTERS array below — edit it to suit your needs.

set -euo pipefail

NAMESPACE="${1:-${NAMESPACE:-llm-d-lora}}"

# ── Adapters to register ────────────────────────────────────────────────
# Each entry is "adapter_name=huggingface_repo_id".
ADAPTERS=(
  "sql-lora=FinGPT/fingpt-forecaster_llama3-8b_lora"
  "sentiment-lora=FinGPT/fingpt-sentiment_llama3-8b_lora"
)

# ── Helpers ─────────────────────────────────────────────────────────────
LOCAL_PORT=8199  # chosen to avoid conflicts with common dev ports

load_adapter() {
  local name="$1" path="$2"
  echo "  Loading adapter: ${name} (${path})"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:${LOCAL_PORT}/v1/load_lora_adapter" \
    -H "Content-Type: application/json" \
    -d "{\"lora_name\": \"${name}\", \"lora_path\": \"${path}\"}")
  if [[ "${status}" == "200" ]]; then
    echo "    OK"
  else
    echo "    FAILED (HTTP ${status})" >&2
  fi
}

# ── Main ────────────────────────────────────────────────────────────────
PODS=$(kubectl get pods -n "${NAMESPACE}" \
  -l llm-d.ai/inference-serving=true \
  -o jsonpath='{.items[*].metadata.name}')

if [[ -z "${PODS}" ]]; then
  echo "Error: no model-server pods found in namespace '${NAMESPACE}'." >&2
  exit 1
fi

for POD in ${PODS}; do
  echo "Registering adapters on pod ${POD}..."
  kubectl port-forward -n "${NAMESPACE}" "${POD}" "${LOCAL_PORT}:8000" &
  PF_PID=$!
  # wait for port-forward to become ready
  for i in $(seq 1 30); do
    if curl -s -o /dev/null "http://localhost:${LOCAL_PORT}/health" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  for entry in "${ADAPTERS[@]}"; do
    name="${entry%%=*}"
    path="${entry#*=}"
    load_adapter "${name}" "${path}"
  done

  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
  echo ""
done

echo "Done. Verify with:"
echo "  kubectl port-forward -n ${NAMESPACE} <pod> 8000:8000"
echo "  curl -s http://localhost:8000/v1/models | python3 -m json.tool"
