# ComfyUI integration

ToshLLM's image generation is exposed to ComfyUI through a custom node that shells out to the bundled `sd-cli` binary. This page documents the parameters and knobs involved.

## Binary lookup

The ComfyUI node looks up the binary in this order:

1. The `SDCPP_BIN` environment variable
2. `/Applications/ToshLLM.app/Contents/Resources/bin-image/sd-cli`
3. `sd-cli` on `PATH`

One `sd-cli` is used at a time; every render spawns its own process.

## Model parameters

- `--diffusion-model` — the diffusion model in GGUF format
- `--vae` — the VAE in safetensors format
- `--llm` — the text encoder, as GGUF or safetensors
- `--llm_vision` — the mmproj GGUF; needed for reference-image/EDIT flows
- `--lora-model-dir DIR` — directory of LoRA models (`.sdcpp.safetensors` files), merged at runtime; select one in the prompt with the tag `<lora:name:weight>`

## Compute placement

`--params-backend te=cpu` keeps text-encoder weights in system RAM. On a 16 GiB card this is the difference between fitting and not. `--backend te=cpu` is the per-backend form.

## Sampling

- `--steps`, `--cfg-scale` — step count and guidance scale
- `--sampling-method` — e.g. `euler`, `dpm++2m`
- `--scheduler` — e.g. `simple`, `flux`
- `--sigmas` — a named preset such as `minimax-h3-image`, or an explicit comma-separated list
- `-s SEED` — seed
- `-W` / `-H` — width and height, auto-aligned up to multiples of 32 (792x1000 becomes 800x1024)
- `-n` — negative prompt

## Memory and performance

- `--vae-tiling` — tile VAE decoding
- `--flash-attn off,diffusion=on` — per-component flash attention control

## Env knobs

Opt-outs for the Qwen-Image 2.1 speed paths (each restores the older, slower graph):

- `TOSH_QWEN21_QKV_F16_DISABLE`
- `TOSH_QWEN21_GATEUP_F16_DISABLE`
- `TOSH_QWEN21_SWIGLU_DISABLE`
- `TOSH_QWEN21_ROPE_TABLE_DISABLE`

Matmul tuning:

- `TOSH_MM_WIDE_FLOOR`
- `TOSH_MM_TAIL_MAX`
- `TOSH_MM_NE0_FLOOR`
- `TOSH_MM_WIDE_EXT_DISABLE`
- `GGML_METAL_MM_DOUBLE_BUFFER_DISABLE` — halves the manual-tile workspace when VRAM is tight

## Reading the log

Before each spawn, the node runs `gc.collect()`, `unload_all_models()`, and `soft_empty_cache(force=True)`, then prints:

```
[sd-cli] MPS after release: tensors N MB, driver M MB
```

Reading it: if the driver figure is much larger than the tensors figure, it is MPS pool/heap reservation — restart ComfyUI. If the tensors figure is large, live models another node loaded are still resident.

In the sd-cli log, `reported free X MB / total Y MB` is the driver's system-wide free VRAM — the number that decides whether a segment fits. The `budget` figure is accounting headroom, NOT free memory. `cannot make enough memory available: need A device / available B device` means a graph segment needs more device memory than is free: free the holder or use an engine state with the smaller segment need.

## Build gate

`scripts/test-qwen-image.sh` renders Qwen-Image 2.1 (a full pass and a one-word pass) after every image-engine build and fails the build if either render fails. `SKIP_QWEN_IMAGE_TEST=1` skips it; it skips itself when the model files are absent (paths via `QWEN_DIFFUSION_MODEL` / `QWEN_VAE` / `QWEN_LLM`).
