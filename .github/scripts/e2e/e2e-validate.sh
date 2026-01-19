#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# e2e-validate.sh — CI e2e Gateway smoke-test (chat + completion, 10 iterations)
# -----------------------------------------------------------------------------

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -n, --namespace NAMESPACE   Kubernetes namespace (default: llm-d)
  -m, --model MODEL_ID        Model to query. If unset, discovers the first available model.
  -v, --verbose               Echo kubectl/curl commands before running
  -h, --help                  Show this help and exit
EOF
  exit 0
}

# ── Diagnostic function ─────────────────────────────────────────────────────
print_diagnostics() {
  local ns="$1"
  echo ""
  echo "=========================================="
  echo "DIAGNOSTIC INFORMATION FOR NAMESPACE: $ns"
  echo "=========================================="
  echo ""
  
  echo "=== Pods ==="
  kubectl get pods -n "$ns" -o wide || true
  echo ""
  
  echo "=== Services ==="
  kubectl get svc -n "$ns" || true
  echo ""
  
  echo "=== Gateways ==="
  kubectl get gateway -n "$ns" -o wide || true
  echo ""
  
  echo "=== HTTPRoutes ==="
  kubectl get httproute -n "$ns" -o wide || true
  echo ""
  
  echo "=== InferencePools ==="
  kubectl get inferencepool -n "$ns" -o wide || true
  echo ""
  
  echo "=== Gateway Details ==="
  kubectl get gateway -n "$ns" -o yaml || true
  echo ""
  
  echo "=== HTTPRoute Details ==="
  kubectl get httproute -n "$ns" -o yaml || true
  echo ""
  
  echo "=== Recent Events ==="
  kubectl get events -n "$ns" --sort-by='.lastTimestamp' | tail -20 || true
  echo ""
  
  echo "=== Gateway Pod Logs (last 50 lines) ==="
  # Try multiple label selectors to find gateway pod
  local gw_pod=$(kubectl get pods -n "$ns" -l "app.kubernetes.io/name=inference-gateway" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$gw_pod" ]]; then
    # Try alternative label selector for istio gateway
    gw_pod=$(kubectl get pods -n "$ns" | grep "inference-gateway" | head -1 | awk '{print $1}' 2>/dev/null || true)
  fi
  if [[ -n "$gw_pod" ]]; then
    echo "Gateway pod: $gw_pod"
    kubectl logs -n "$ns" "$gw_pod" --tail=50 || true
  else
    echo "No gateway pod found"
  fi
  echo ""
  
  echo "=========================================="
}

# ── Defaults ────────────────────────────────────────────────────────────────
NAMESPACE="llm-d"
CLI_MODEL_ID=""
VERBOSE=false

# ── Flag parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -m|--model)     CLI_MODEL_ID="$2"; shift 2 ;;
    -v|--verbose)   VERBOSE=true; shift ;;
    -h|--help)      show_help ;;
    *) echo "Unknown option: $1"; show_help ;;
  esac
done

if [[ "${VERBOSE}" == "true" ]]; then
  set -x
fi

# ── Helper for unique pod suffix ────────────────────────────────────────────
gen_id() { echo $(( RANDOM % 10000 + 1 )); }

# ── Discover Gateway address ────────────────────────────────────────────────
HOST="${GATEWAY_HOST:-$(kubectl get gateway -n "$NAMESPACE" \
          -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)}"
if [[ -z "$HOST" ]]; then
  echo "Error: could not discover a Gateway address in namespace '$NAMESPACE'." >&2
  print_diagnostics "$NAMESPACE"
  exit 1
fi
PORT=80
SVC_HOST="${HOST}:${PORT}"

# ── Determine MODEL_ID ──────────────────────────────────────────────────────
# Priority: command-line > env var > auto-discovery
if [[ -n "$CLI_MODEL_ID" ]]; then
  MODEL_ID="$CLI_MODEL_ID"
elif [[ -n "${MODEL_ID-}" ]]; then
  MODEL_ID="$MODEL_ID"
else
  echo "Attempting to auto-discover model ID from ${SVC_HOST}/v1/models..."
  
  # Retry logic for kubectl run with exponential backoff
  MAX_RETRIES=3
  RETRY_DELAY=2
  MODEL_ID=""
  
  for attempt in $(seq 1 $MAX_RETRIES); do
    echo "Discovery attempt $attempt of $MAX_RETRIES..."
    ID=$(gen_id)
    ret=0
    
    # Try to discover model ID
    MODEL_ID=$(kubectl run --pod-running-timeout 5m --rm -i curl-discover-${ID} \
                  --namespace "$NAMESPACE" \
                  --image=curlimages/curl --restart=Never -- \
                  sh -c "sleep 2; curl -sS --max-time 15 http://${SVC_HOST}/v1/models" 2>/dev/null | \
                  grep -o '"id":"[^"]*"' | \
                  head -n 1 | \
                  cut -d '"' -f 4) || ret=$?
    
    if [[ $ret -eq 0 && -n "$MODEL_ID" ]]; then
      echo "Successfully discovered model ID: $MODEL_ID"
      break
    fi
    
    echo "Attempt $attempt failed (exit code $ret), model ID: '${MODEL_ID}'"
    
    if [[ $attempt -lt $MAX_RETRIES ]]; then
      echo "Retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
      RETRY_DELAY=$((RETRY_DELAY * 2))
    fi
  done

  if [[ -z "$MODEL_ID" ]]; then
    echo "Error: Failed to auto-discover model ID from gateway after $MAX_RETRIES attempts." >&2
    echo "You can specify one using the -m flag or the MODEL_ID environment variable." >&2
    print_diagnostics "$NAMESPACE"
    exit 1
  fi
fi

echo "Namespace: $NAMESPACE"
echo "Inference Gateway:   ${SVC_HOST}"
echo "Model ID:  $MODEL_ID"
echo

# ── Main test loop (10 iterations) ──────────────────────────────────────────
for i in {1..10}; do
  echo "=== Iteration $i of 10 ==="
  failed=false

  # 1) POST /v1/chat/completions
  echo "1) POST /v1/chat/completions at ${SVC_HOST}"
  chat_payload='{
    "model":"'"$MODEL_ID"'",
    "messages":[{"role":"user","content":"Hello!  Who are you?"}]
  }'
  ID=$(gen_id)
  if $VERBOSE; then cat <<CMD
  - Running command:
    kubectl run --rm -i curl-${ID} \\
      --namespace "${NAMESPACE}" \\
      --image=curlimages/curl --restart=Never -- \\
      curl -sS -X POST "http://${SVC_HOST}/v1/chat/completions" \\
        -H 'accept: application/json' \\
        -H 'Content-Type: application/json' \\
        -d '${chat_payload//\'/\'}'
CMD
  fi
  ret=0
  output=$(kubectl run --rm -i curl-"$ID" \
            --namespace "$NAMESPACE" \
            --image=curlimages/curl --restart=Never -- \
            sh -c "sleep 1; curl -sS -X POST 'http://${SVC_HOST}/v1/chat/completions' \
                 -H 'accept: application/json' \
                 -H 'Content-Type: application/json' \
                 -d '$chat_payload'") || ret=$?
  echo "$output"
  [[ $ret -ne 0 || "$output" != *'{'* ]] && {
    echo "Error: POST /v1/chat/completions failed (exit $ret or no JSON)" >&2; failed=true; }
  echo

  # 2) POST /v1/completions
  echo "2) POST /v1/completions at ${SVC_HOST}"
  payload='{
    "model":"'"$MODEL_ID"'",
    "prompt":"You are a helpful AI assistant."
  }'
  ID=$(gen_id)
  if $VERBOSE; then cat <<CMD
  - Running command:
    kubectl run --rm -i curl-${ID} \\
      --namespace "${NAMESPACE}" \\
      --image=curlimages/curl --restart=Never -- \\
      curl -sS -X POST "http://${SVC_HOST}/v1/completions" \\
        -H 'accept: application/json' \\
        -H 'Content-Type: application/json' \\
        -d '${payload//\'/\'}'

CMD
  fi
  ret=0
  output=$(kubectl run --rm -i curl-"$ID" \
            --namespace "$NAMESPACE" \
            --image=curlimages/curl --restart=Never -- \
            sh -c "sleep 1; curl -sS -X POST 'http://${SVC_HOST}/v1/completions' \
                 -H 'accept: application/json' \
                 -H 'Content-Type: application/json' \
                 -d '$payload'") || ret=$?
  echo "$output"
  [[ $ret -ne 0 || "$output" != *'{'* ]] && {
    echo "Error: POST /v1/completions failed (exit $ret or no JSON)" >&2; failed=true; }
  echo

  if $failed; then
    echo "Iteration $i encountered errors; exiting." >&2
    echo "Printing diagnostics before exit..."
    print_diagnostics "$NAMESPACE"
    exit 1
  fi
done

echo "✅ All 10 iterations succeeded."
