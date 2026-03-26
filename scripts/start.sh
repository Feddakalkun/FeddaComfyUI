#!/bin/bash
set -e

echo "========================================="
echo "  FeddaComfyUI - Docker Startup"
echo "========================================="
echo "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null || echo 'none detected')"
echo ""

# --- 1. Detect volume mount path ---
# RunPod serverless mounts at /runpod-volume, pods mount at /workspace
if [ -d "/runpod-volume" ]; then
    VOLUME="/runpod-volume"
elif [ -d "/workspace" ]; then
    VOLUME="/workspace"
else
    VOLUME="/workspace"
    mkdir -p "$VOLUME"
fi
echo "[SETUP] Using volume: $VOLUME"

# --- 2. Model directories on network volume ---
MODELS_DIR="$VOLUME/models"
mkdir -p "$MODELS_DIR"/{checkpoints,diffusion_models,clip,text_encoders,vae,loras,model_patches}
mkdir -p "$VOLUME/output"
mkdir -p "$VOLUME/input"

# --- 2. Symlink ComfyUI model directories to network volume ---
echo "[SETUP] Symlinking model directories to $VOLUME..."
for dir in checkpoints diffusion_models clip text_encoders vae loras model_patches; do
    rm -rf "/app/ComfyUI/models/$dir"
    ln -sf "$MODELS_DIR/$dir" "/app/ComfyUI/models/$dir"
done

# Symlink output and input
rm -rf /app/ComfyUI/output
ln -sf "$VOLUME/output" /app/ComfyUI/output
rm -rf /app/ComfyUI/input
ln -sf "$VOLUME/input" /app/ComfyUI/input

# --- 3. Custom nodes: sync from image to workspace (copy missing ones) ---
mkdir -p "$VOLUME/custom_nodes"

for node_dir in /app/custom_nodes/*/; do
    node_name=$(basename "$node_dir")
    if [ ! -d "$VOLUME/custom_nodes/$node_name" ]; then
        echo "[NODES] NEW: Copying $node_name to workspace..."
        cp -r "$node_dir" "$VOLUME/custom_nodes/"
    fi
done

# Symlink custom_nodes into ComfyUI
rm -rf /app/ComfyUI/custom_nodes
ln -sf "$VOLUME/custom_nodes" /app/ComfyUI/custom_nodes

echo "[NODES] $(ls "$VOLUME/custom_nodes" | wc -l) custom nodes ready."

# --- 4. Copy bundled workflows ---
WORKFLOW_DEST="/app/ComfyUI/user/default/workflows"
mkdir -p "$WORKFLOW_DEST"
if [ -d "/app/workflows" ]; then
    cp -f /app/workflows/*.json "$WORKFLOW_DEST/" 2>/dev/null || true
    cp -f /app/workflows/*.JSON "$WORKFLOW_DEST/" 2>/dev/null || true
    echo "[WORKFLOWS] Bundled workflows copied to ComfyUI."
fi

# --- 5. Configure ComfyUI-Manager ---
MANAGER_DIR="$VOLUME/custom_nodes/ComfyUI-Manager"
if [ -d "$MANAGER_DIR" ]; then
    mkdir -p "$MANAGER_DIR/user"
    cat > "$MANAGER_DIR/user/config.ini" << 'EOF'
[default]
security_level = weak
network_mode = public
EOF
fi

# --- 6. Launch services ---
echo ""
if [ "${SERVERLESS}" = "true" ]; then
    echo "========================================="
    echo "  Mode: SERVERLESS"
    echo "  ComfyUI: background (localhost:8188)"
    echo "  Handler: RunPod serverless"
    echo "========================================="

    # In serverless mode, set Manager to offline (no external calls)
    if [ -d "$MANAGER_DIR" ]; then
        cat > "$MANAGER_DIR/user/config.ini" << 'MGREOF'
[default]
security_level = weak
network_mode = offline
MGREOF
    fi

    # Start ComfyUI in background
    python3 /app/ComfyUI/main.py --disable-auto-launch --disable-metadata --listen --port 8188 &
    echo $! > /tmp/comfyui.pid

    # Start RunPod handler
    cd /app/src
    exec python3 -u rp_handler.py
else
    echo "========================================="
    echo "  Mode: POD (interactive)"
    echo "  ComfyUI: port 8188"
    echo "  Jupyter:  port 8888"
    echo "========================================="
    exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
fi
