#!/bin/zsh
# Renders Qwen-Image 2.1 with the just-built image engine and fails if the image
# does not come out. This is the gate that keeps the only must-work model working:
# build-engines.sh runs it after every image-engine build, so a change that breaks
# Qwen-Image fails the build instead of reaching ComfyUI. Skip with
# SKIP_QWEN_IMAGE_TEST=1.
#
#   ./scripts/test-qwen-image.sh
#   SKIP_QWEN_IMAGE_TEST=1 ./scripts/build-engines.sh
#
# Model paths come from the environment and default to the local ComfyUI stores
# (the test skips cleanly on machines without the models):
#   QWEN_DIFFUSION_MODEL, QWEN_VAE, QWEN_LLM
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="vendor/stable-diffusion.cpp/build-static/bin/sd-cli"
[ -x "$BIN" ] || { echo "FAIL: no sd-cli at $BIN; build the image engine first" >&2; exit 2; }

DIFFUSION="${QWEN_DIFFUSION_MODEL:-/Volumes/Sdiffusion/python/stable-diffusion-webui/models/Stable-diffusion/QwenImage/Turbo/Qwen-Image-2.1-Turbo-AD-Q5_K.gguf}"
VAE="${QWEN_VAE:-/Volumes/Sdiffusion/python/stable-diffusion-webui/models/VAE/qwen_image_2.1_vae_bf16.safetensors}"
LLM="${QWEN_LLM:-/Volumes/Sdiffusion/python/stable-diffusion-webui/models/text_encoder/Qwen-Image-2.1-Turbo-Uncensored-AD-Q3_K.gguf}"

missing=0
for f in "$DIFFUSION" "$VAE" "$LLM"; do
    if [ ! -f "$f" ]; then
        echo "SKIP: $f not found; point QWEN_DIFFUSION_MODEL / QWEN_VAE / QWEN_LLM at a Qwen-Image 2.1 setup to run the gate" >&2
        missing=1
    fi
done
[ "$missing" = 0 ] || exit 0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

render() {  # <name> <prompt> <steps>
    local name="$1" prompt="$2" steps="$3"
    local out="$TMP/$name.png" log="$TMP/$name.log"
    set +e
    "$BIN" --diffusion-model "$DIFFUSION" --vae "$VAE" --llm "$LLM" \
        -p "$prompt" -W 512 -H 512 --steps "$steps" --cfg-scale 1.0 \
        --sampling-method dpm++2m --scheduler flux -s 42 -o "$out" \
        --vae-tiling --params-backend te=cpu >"$log" 2>&1
    local rc=$?
    set -e
    if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
        echo "FAIL: Qwen-Image 2.1 '$name' render failed (exit $rc):" >&2
        grep -E 'GGML_ASSERT|ERROR|error|failed|cannot make|does not live' "$log" | tail -4 >&2
        exit 1
    fi
    # A 512x512 render is hundreds of KB; a tiny file means the pipeline wrote nothing.
    local bytes=$(stat -f%z "$out")
    if [ "$bytes" -lt 50000 ]; then
        echo "FAIL: Qwen-Image 2.1 '$name' image is only $bytes bytes" >&2
        exit 1
    fi
    echo "  ok: $name rendered ($bytes bytes, $steps steps)"
}

# The canonical text-to-image pass: the whole pipeline (LLM encoder, DiT, VAE).
render qwen-t2i "a red apple on a wooden table, photo" 4
# The one-token pass: a single-token prompt once squeezed the sequence dimension
# out of the conditioning and aborted the encoder (the short-prompt failure class).
render qwen-one-word "cat" 4

echo "Qwen-Image 2.1 gate passed"
