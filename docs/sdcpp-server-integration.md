# sd.cpp server integration for ComfyUI-SDCPP — design and handoff document

Status: design, ready to implement. Target consumer: an implementation agent with
access to this machine. Every command and fact below was verified on 2026-11-15
against the current `main` state of `/Users/carakan/development/toshllm`
(branch `7b822fb`, vendor pin `b56ed29`, engine `master-1027-e7b7ec6-1-g304bcad`).

## 1. Why (measured baseline)

The plugin today spawns a fresh `sd-cli` process per render. Each process pays:

| Phase | Measured |
| --- | --- |
| Process spawn + Metal init + pipeline load | ~1.5 s |
| Text encoder load | 0.42 s |
| Conditioning (text encode) | 1.75 s |
| DiT weights load (9 GB @ ~4.5 GB/s) | 1.25 s |
| LoRA apply | 0.08 s |
| VAE load + tiled decode | ~6.5 s |
| Teardown (`ggml_metal_free`) + node overhead | ~1.5 s |
| Sampling (832×1248, 8 steps, Qwen-Image 2.1 Turbo) | 76.9 s |

Non-sampling overhead is ~9-12 s per render (~12% of wall time). A resident
engine removes the load/init/teardown share (~4-5 s per render warm) and the
server's conditioning cache removes repeat-prompt encode costs on top.

**The VRAM tension (must-read before implementing C):** a resident engine is a
permanent VRAM holder (5.8 GB with `--params-backend te=cpu`, 9.3 GB without).
On this 16 GB RX 6800 XT the card is regularly held by ComfyUI's PyTorch pool
and browsers. macOS evicts *idle* holders' pages (verified: a 10.5 GB idle
filler was evicted, the hot engine kept full speed), so residency helps in
burst/calm periods and degrades to about cold-start cost when the card is held.
Do not ship always-resident (design C) without the idle-unload of design B or
explicit user opt-in.

## 2. Verified facts about the server

- `examples/server/` exists in the vendored tree; **no ToshLLM patch touches it**;
  the image-engine build (`scripts/build-engines.sh`) currently builds only the
  `sd-cli` target (`-t sd-cli`, line ~495).
- It compiles and links clean against the patched tree with the frontend off:

  ```sh
  cmake -S vendor/stable-diffusion.cpp -B vendor/stable-diffusion.cpp/build-static \
        -DSD_SERVER_BUILD_FRONTEND=OFF
  cmake --build vendor/stable-diffusion.cpp/build-static --config Release -t sd-server
  # -> vendor/stable-diffusion.cpp/build-static/bin/sd-server
  # (only warning: duplicate libwebp at link)
  ```

  `SD_SERVER_BUILD_FRONTEND=OFF` is required on this machine: the default ON
  needs `pnpm` + asdf-managed nodejs (absent). The frontend is a web UI the
  plugin does not need; pass `--serve-html-path` later if ever wanted.

- API families (from `examples/server/api.md`):
  - OpenAI-compatible `/v1/images/generations`, `/v1/images/edits`, `/v1/models`
  - A1111-compatible `/sdapi/v1/txt2img`, `/sdapi/v1/img2img`, progress, loras, samplers, ...
  - Native async `/sdcpp/v1/...`: `capabilities`, `img_gen`, `vid_gen`, `upscale`,
    `jobs/{id}` (poll), `jobs/{id}/cancel`, `recipes`, `model-files`,
    `models/refresh`, `models/status`, `models/load`, `models/unload`
- **Model management exists**: `POST /sdcpp/v1/models/load` (recipe + component
  paths), `POST /sdcpp/v1/models/unload` (release the context), 503 while
  loading (`model_loading`), 503 without model (`model_not_loaded`), 409
  `model_busy` during load/unload races.
- **Async jobs**: `img_gen` returns a job id; poll `jobs/{id}`; `--max-pending-jobs`
  (default 64) and `--completed-ttl-seconds` (default 600) bound the queue.
- **Server startup options** (`sd-server --help`): `--listen-ip` (default
  127.0.0.1), `--listen-port` (default 1234), `--max-pending-jobs`,
  `--completed-ttl-seconds`, `--model-dir` (repeatable), `--log-level` — plus
  the **same Context Options as sd-cli** (all model/component/placement flags).
- **Behavioral difference that WILL break renders**: server APIs do **not**
  parse `<lora:...>` tags inside the prompt — LoRA must be passed via structured
  request fields. The plugin currently renders exclusively through `<lora:...>`
  tags. This is the main migration item.
- Command-line model context (flags at server start) preloads a model at boot;
  recipe-based load/unload switches contexts at runtime.

## 3. The three designs

### A. Batch inside one process (no server, node-only)

Scope: amortize loads when a workflow renders several images back-to-back.
`sd-cli` stays per-process, but one process serves N results:

- Same prompt, N images: `--batch-count N` already exists (out `%d` sequence).
- Different prompts: sd-cli takes one prompt per process, so batch by
  grouping identical-prompt jobs; true multi-prompt needs the server (B).

Implementation (plugin only):
1. `sdcpp_nodes.py` collects the ComfyUI execution batch (`inputs["batch_size"]`,
   or the node's `batch_count` UI field if added) and passes `--batch-count`.
2. Keep the per-image output loop reading `%d` sequence outputs.
3. No engine changes; works on today's `main`.

Gain: full load/teardown share saved per extra image (~4-5 s each).
Risk: none. Ship this even if B is later built (it remains the fallback path).

### B. Idle-timeout daemon (recommended target)

The plugin manages one long-lived `sd-server` process; VRAM is released after
an idle window.

1. **Lifecycle manager** (plugin side):
   - Health-check `GET /sdcpp/v1/models/status` on 127.0.0.1 with a fixed port
     (suggest 12727 to avoid upstream's 1234 default and common services).
   - Start `sd-server` on demand with the workflow's Context Options (the same
     flags the node passes to sd-cli today), keep a pidfile under the node dir.
   - After N minutes without a completed job (suggest N=10, UI-configurable),
     `POST /sdcpp/v1/models/unload` to release VRAM; optionally exit the
     process after a second window. Cold render after unload = today's cost.
2. **Render path**: `POST /sdcpp/v1/img_gen` (async) → poll `jobs/{id}` every
   ~500 ms → read the result image path/bytes from the job response → feed into
   ComfyUI. On 503 `model_loading`, wait and retry; on 409 `model_busy`, queue.
3. **Fallback**: if the server is unreachable/unstartable, fall back to the
   current spawn path (keep `run_sdcli` intact). The plugin must never hard
   depend on the daemon.
4. **LoRA migration**: send LoRAs through the server's structured fields (check
   `routes_sdcpp.cpp` request schema at implementation time); translate the
   node's `<lora:file:strength>` prompt tags into the structured form server-side
   of the request builder. Reject or strip tags only after field-verified parity.
5. **Env parity**: `sdcli_env()` (TOSH_FA_AMD etc.) must be passed to the server
   process too.

Gain: warm renders save ~4-5 s; repeat prompts additionally save the encode via
the conditioning cache (`--conditioning-cache-size`, default 0 — set it, e.g. 8).
Risk: the daemon becomes a VRAM holder — the idle-unload is the safety valve.

### C. Always-resident daemon

Design B without unload. Only acceptable if the user accepts a permanent
5.8-9.3 GB holder; history on this machine (the strict-gate failure era) argues
against it. Documented here so the implementer does not "simplify" B into C.

## 4. Plugin integration points (facts)

- Plugin: `/Volumes/Sdiffusion/python/ComfyUI/custom_nodes/ComfyUI-SDCPP/sdcpp_nodes.py`.
- Binary resolution today: `$SDCPP_BIN` → `/Applications/ToshLLM.app/Contents/Resources/bin-image/sd-cli`
  → `sd-cli` on PATH. On this machine `$SDCPP_BIN` is set in ComfyUI's launch
  environment to `~/development/toshllm/vendor/stable-diffusion.cpp/build-static/bin/sd-cli`
  (visible in `comfyui.log` `[sd-cli] cmd:` lines) — rebuilding the vendor tree
  reaches the plugin directly. Add the same resolution for `sd-server`
  (`SDCPP_SERVER_BIN` → sibling `sd-server` → PATH).
- Concurrency rule in the plugin today: one sd-cli at a time (see the module
  comment and the shutdown helper). The server natively queues (async jobs),
  which replaces the lock for the server path.
- Models live on `/Volumes/Sdiffusion/python/{stable-diffusion-webui,ComfyUI}/models/...`;
  the plugin maps ComfyUI model folders to absolute paths per request.

## 5. Full `sd-cli` parameter reference (nothing lost)

Source of truth: `sd-cli --help` (captured 2026-11-15, 304 lines). Anything
marked *(dep.)* is deprecated but still parsed.

### 5.1 CLI / meta

`-o/--output` (printf `%d` sequences; .avi/.webm/.webp for video) · `--image`
+ `--metadata-format text|json` + `--metadata-raw` + `--metadata-brief` +
`--metadata-all` (metadata mode) · `--preview-path` + `--preview none|proj|tae|vae`
+ `--preview-interval` + `--preview-noisy` · `--imat-out` / `--imat-in` (imatrix)
· `--output-begin-idx` · `--compression-quality` · `--convert-name` (convert mode)
· `-M/--mode img_gen|adetailer|vid_gen|upscale|convert|metadata` · `--color`
· `--log-level` / `-v` · `-h`

### 5.2 Models and context (server startup + request schema overlap)

`-m/--model` · `--diffusion-model` · `--high-noise-diffusion-model` ·
`--uncond-diffusion-model` · `--clip_l` · `--clip_g` · `--clip_vision` ·
`--t5xxl` · `--llm` · `--llm_vision` · `--qwen2vl`/`--qwen2vl_vision` *(dep.)* ·
`--tokenizer` (path or `main=F,clip-l=F,clip-g=F`) · `--vae` · `--vae-format
auto|flux|sd3|flux2|wan` · `--audio-vae` · `--audio-encoder` · `--taesd`/`--tae` ·
`--taesd-preview-only` · `--control-net` · `--control-type
openpose|depth|scribble|canny|normal|segment|tile|repaint|...` · `--ip-adapter`
(needs `--clip_vision`) · `--motion-module` · `--embd-dir` · `--photo-maker` ·
`--pm-id-images-dir` · `--pm-id-embed-path` · `--pulid-weights` ·
`--pulid-id-embedding` · `--upscale-model` · `--lora-model-dir` ·
`--hires-upscalers-dir` · `--embeddings-connectors` · `--tensor-type-rules`
(e.g. `"^vae\.=f16,model\.=q8_0"`) · `--model-args` (chroma_use_dit_mask,
chroma_use_t5_mask, chroma_t5_mask_pad, qwen_image_zero_cond_t,
qwen_image_2_1_prefix_cache, qwen_image_2_1_prefix_cache_type)

### 5.3 Placement, memory, performance

`--backend` (runtime assignment: `cpu`, `clip=cpu`, `vae=cuda0`,
`diffusion=vulkan0`, `&`-joined multi-GPU) · `--params-backend` (parameter
placement: `disk`, `cpu`, or per-module `diffusion=disk,clip=cpu`; disables
auto-fit) · `--auto-fit on|off` (GPU→RAM→other GPU→disk placement ladder;
honors `--max-vram`; disabled by explicit `--params-backend`) · `--max-vram`
(GiB budget per device; negative reserves free VRAM, e.g. `-4`) · `--split-mode
layer|row` (multi-GPU distribution; row = CUDA only) · `--rpc-servers` ·
`-t/--threads` · `--offload-to-cpu` · `--mmap` · `--eager-load` ·
`--disable-prefetch` · `--disable-segmented-compute` · `--batched-cfg on|off` ·
`--flash-attn on|off|auto` or per-module (`auto,te=off,vae=on`; on RDNA2 the
diffusion path silently falls back — measured no-op, keep off) · `--fa` /
`--diffusion-fa` *(dep.)* · `--attn-scale` / `--linear-scale` · `--conv-direct
on|off|auto` or assignments · `--vae-conv-direct` / `--diffusion-conv-direct`
*(dep.)* · `--control-net-cpu` / `--clip-on-cpu` / `--vae-on-cpu` *(dep.)* ·
`--sage-attn` (CUDA) · `--force-sdxl-vae-conv-scale` · `--conditioning-cache-size`
(0 default; **set >0 in server mode**) · `--list-devices`

### 5.4 Generation and sampling

`-p/--prompt` · `-n/--negative-prompt` · `--prompt-file` ·
`--negative-prompt-file` · `-W/--width` · `-H/--height` · `--steps` ·
`-b/--batch-count` · `-s/--seed` (<0 random) · `--cfg-scale` ·
`--img-cfg-scale` · `--guidance` · `--slg-scale` + `--skip-layer-start/end` +
`--skip-layers` · `--eta` · `--flow-shift` · `--timestep-shift` · `--strength`
· `--clip-skip` · `--sampling-method` (20 methods: euler, euler_a, heun, dpm2,
dpm++2s_a, dpm++2m, dpm++2mv2, ipndm, ipndm_v, lcm, ddim_trailing, tcd,
res_multistep, res_2s, er_sde, euler_cfg_pp, euler_a_cfg_pp, euler_ge,
dpm++2m_sde, dpm++2m_sde_bt, lms) · `--scheduler` (discrete, karras,
exponential, ays, gits, sgm_uniform, simple, smoothstep, kl_optimal, lcm,
bong_tangent, ltx2, logit_normal, flux2, flux, beta, llada_image) · `--sigmas`
(comma list or preset `qwen-image-2.1-turbo`) · `--rng` / `--sampler-rng
std_default|cuda|cpu` · `--prediction` (eps, v, edm_v, sd3_flow, flux_flow,
sefi_flow, minit2i_flow, sensenova_u1_flow, flux3_flow, h3_av_flow,
ming_image_flow) · `--type` (weight type override) · `--lora-apply-mode
auto|immediately|at_runtime` · `--linear-scale` · `--circular` / `--circularx` /
`--circulary` · `--disable-image-metadata` · `--qwen-image-layers`

High-noise (Wan2.2 MoE / dual models): `--high-noise-diffusion-model` ·
`--high-noise-steps` · `--high-noise-cfg-scale` · `--high-noise-img-cfg-scale` ·
`--high-noise-guidance` · `--high-noise-slg-scale` ·
`--high-noise-skip-layer-start/end` · `--high-noise-skip-layers` ·
`--high-noise-sampling-method` · `--high-noise-eta` · `--moe-boundary`

Image inputs: `-i/--init-img` · `--end-img` · `--mask` · `--control-image` ·
`--ip-adapter-image` · `--control-video` · `-r/--ref-image` (repeatable;
Flux Kontext / MiniMax-H3) · `--ref-video` · `--ref-video-audio` · `--ref-audio`
· `--audio` · `--ref-image-args` · `--image-preprocess` (rules:
`target=...,index=N,mode=...,filter=...,width=,height=,pad_color=,canny=`) ·
`--increase-ref-index` · `--control-strength` · `--ip-adapter-strength` ·
`--pulid-id-weight` · `--pm-style-strength` · `--vace-strength`

Highres fix: `--hires` · `--hires-scale` · `--hires-width/height` ·
`--hires-steps` · `--hires-denoising-strength` · `--hires-upscaler` ·
`--hires-sigmas` · `--hires-upscale-tile-size`

Video: `--video-frames` · `--fps` · `--temporal-tiling` (plus
`--extra-tiling-args temporal_tile_frames/size/overlap`)

Upscale: `--upscale-repeats` · `--upscale-tile-size`

VAE: `--vae-tiling` · `--vae-tile-size` · `--vae-relative-tile-size` ·
`--vae-tile-overlap` · `--extra-tiling-args`

Advanced sampling: `--extra-sample-args` (CFG guidance_schedule; APG
apg_eta/momentum/norm_threshold/norm_threshold_smoothing; SLG slg_uncond; lcm
noise_clip_std/noise_scale_start/end; flux base_shift/max_shift; ltx2
max_shift/base_shift/stretch/terminal; euler_ge gamma; beta alpha/beta;
logit_normal mu/std/logsnr_min/max/resolution_aware; lms lms_max_order/shift/
divisions; noise_sampler iid|brownian_tree; brownian_tree_rng) ·
`--cache-mode easycache|ucache|dbcache|taylorseer|cache-dit|spectrum` ·
`--cache-option` (per-mode key=value) · `--scm-mask` · `--scm-policy`

ADetailer: `-M adetailer` + `--ad-model` · `--ad-prompt` ·
`--ad-negative-prompt` · `--extra-ad-args`

### 5.5 Environment knobs (process env, pass to server too)

`TOSH_MM_WIDE_FLOOR` · `TOSH_MM_TAIL_MAX` · `TOSH_MM_WIDE_EXT_DISABLE` ·
`TOSH_FA_AMD` · `TOSH_MM_NEO_FLOOR` / `TOSH_MM_TRACE`-family (see
`docs/comfyui-integration.md` for the full list and semantics) ·
`GGML_METAL_MM_DOUBLE_BUFFER_DISABLE` (halves manual-tile workspace under VRAM
pressure) · `SD_BF16_PROMOTE_F32` · `QWEN_DIFFUSION_MODEL` / `QWEN_VAE` /
`QWEN_LLM` (gate script overrides only)

## 6. Server-side request mapping (what the agent must verify per field)

- The native `img_gen` request schema mirrors `sd_cpp_extra_args` — most
  generation/sampling fields carry over 1:1 (prompt, negative_prompt, width,
  height, steps, cfg_scale, seed, sampling_method, scheduler, sigmas, strength,
  ref images, ...). Verify each field the node sends against
  `examples/server/routes_sdcpp.cpp` and record misses in the PR.
- Model context arrives via server startup flags (Context Options above) or
  `models/load` with recipes; the plugin's per-render absolute model paths map
  to a startup-flags config (preferred: one server per model context is NOT
  needed — `models/load` switches contexts, 409-guarded).
- LoRA: structured fields only (§2); no `<lora:>` tag parsing.
- The conditioning cache (`--conditioning-cache-size N`) is a server startup
  flag; enable it (8 is a good start) for repeat-prompt workflows.

## 7. Acceptance criteria

1. `SKIP_LLAMA=1 SKIP_WHISPER=1 ./scripts/build-engines.sh` still passes the
   Qwen-Image 2.1 gate (the gate runs inside the build script; both renders must
   produce >50 KB images).
2. `sd-server` target builds with `SD_SERVER_BUILD_FRONTEND=OFF`; add the
   `-t sd-server` line to `scripts/build-engines.sh` next to the `sd-cli` one
   and strip it like the CLI binary.
3. Smoke: start `sd-server` with the Qwen context flags (the gate script's
   model set + `--params-backend te=cpu` + `--conditioning-cache-size 8`),
   `curl /sdcpp/v1/capabilities`, generate one 512×512 via `img_gen`, poll to
   completion, `models/unload`, Ctrl-C. No GGML_ASSERT in the log.
4. Plugin: with the server up, a two-image portrait workflow completes; wall
   time for the second render must beat the spawn path by ≥3 s; with the server
   killed mid-workflow the node falls back to spawn and still completes.
5. VRAM safety: after the idle window, `models/status` shows unloaded and
   `sudo powermetrics`/Activity Monitor shows the resident's VRAM released.
6. Parity spot-check: same seed+prompt via spawn vs server produce visually
   identical images (metadata-seeded comparison).

## 8. Out of scope (do not do here)

- Do not touch the vendor pins, the patch series, or `build-engines.sh`'s
  patch application order.
- Do not enable the pnpm frontend.
- Do not make the plugin hard-depend on the daemon (fallback stays).
- Do not set design C without explicit user opt-in (VRAM holder history:
  2026-11-14 era failures).
