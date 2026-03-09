#!/bin/bash
# copy_lora_structure.sh
# This script copies only LoRA adapters from HuggingFace cache to the LoRA resolver directory
# It filters out base models by checking for adapter-specific files

HF_CACHE="/var/lib/llm-d/.hf/hub"
LORA_RESOLVER_DIR="/lora-adapters"

mkdir -p "$LORA_RESOLVER_DIR"

for model_dir in "$HF_CACHE"/models--*/; do
    snapshot_dir=$(find "$model_dir/snapshots" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
    
    if [ -d "$snapshot_dir" ]; then
        # Check if this is a LoRA adapter by looking for adapter-specific files
        # LoRA adapters typically have adapter_config.json and adapter_model.safetensors/bin
        if [ -f "$snapshot_dir/adapter_config.json" ] || \
           [ -f "$snapshot_dir/adapter_model.safetensors" ] || \
           [ -f "$snapshot_dir/adapter_model.bin" ]; then
            
            adapter_name=$(basename "$model_dir" | sed 's/^models--//' | sed 's/--/-/g')
            adapter_dir="$LORA_RESOLVER_DIR/$adapter_name"
            
            mkdir -p "$adapter_dir"
            
            # Copy actual files (resolving symlinks)
            cp -L "$snapshot_dir"/* "$adapter_dir/" 2>/dev/null
            
            echo "Copied LoRA adapter: $adapter_dir"
        else
            model_name=$(basename "$model_dir" | sed 's/^models--//' | sed 's/--/-/g')
            echo "Skipping base model: $model_name (no adapter files found)"
        fi
    fi
done

echo "LoRA adapter copy complete. Adapters are in: $LORA_RESOLVER_DIR"
