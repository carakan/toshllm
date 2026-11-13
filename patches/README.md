# Patches

Patches against the pinned upstream commits, one directory per engine:

```
llama/          llama.cpp, one patch per feature in a folder per area
image-metal/    the AMD Metal backend for stable-diffusion.cpp, on upstream ggml's kernels/ layout
shared-metal/   the Metal backend for whisper.cpp, on the older single-file ggml layout
whisper/        whisper.cpp, outside the Metal backend
image/          stable-diffusion.cpp, outside the Metal backend
```

`scripts/build-engines.sh` discovers them per engine and applies them in **numeric order of the
file name**, recursively, so the number is the apply order: never reuse one, and keep it when
moving a file.

## `llama/`

The port to upstream `d81235049` (v0.6.0), one patch per feature, in a folder per area:

| folder | what lives there |
|---|---|
| `metal/` | the AMD Metal backend: host side, reductions and quant loads, matvec and ToshGEMM for both lane widths, AMD flash and sparse attention, fusions, older GCN and macOS 12 |
| `quant/` | turbo KV cache, Prism ternary types |
| `mgpu/` | multi-GPU: tensor groups, events and subgraphs, allreduce, TP2 fused boundary |
| `moe/` | expert prefetch, Dynamic MoE, its host cache and auto plan |
| `core/` | CPU expert dot products, loader and scheduler, 8-bit recurrent state |
| `model/` | DFlash, Flash-Next, rope and clip fixes |
| `spec/` | MTP |
| `server/` | chat templates and tool calls, MCP agent, reasoning budget, checkpoints, requests running together |

The number is global across the folders. Patches overlap in files, so they only apply in order.
**A new change gets its own numbered patch after the last one**, in the folder of its area, so it
can be read, measured and reverted on its own. When a batch of those is closed, fold each into
the feature patch it belongs to.

## `shared-metal/`

Whisper.cpp is pinned to a commit from before upstream split `ggml-metal.metal` into `kernels/`,
so it cannot take `llama/metal/`. The `0001-*` series here is that same backend against the
older layout, and the speech engine applies it unchanged. The image engine moved to the newer
layout and takes `image-metal/` instead.

## `image-metal/`

The AMD Metal backend for the image engine, on the ggml that upstream stable-diffusion.cpp
master pins (`d803c238`). Upstream split `ggml-metal.metal` into `kernels/` and added the
ggml-ext registry, so the backend had to be ported onto that layout before the engine could
take upstream master whole.

| patch | what it carries |
|---|---|
| `0001-ggml-types-and-ops.patch` | the ggml-level types and ops the backend needs: the TurboQuant and Prism ternary types, the Dynamic MoE ops, and the scheduler and CPU sides that go with them |
| `0002-amd-metal-kernels.patch` | the Metal shaders, including the wave64 variants of the matvec, the matmul and the flash attention |
| `0003-amd-metal-host.patch` | the Metal host side: the device's wave64 support, the manual (ToshGEMM) matmul path, the pipeline dispatch |
| `0004-image-ggml-rope-apply.patch` | `ggml_rope_apply` (`GGML_OP_ROPE_APPLY`): applying a rotation the engine prepared earlier, with its CPU forward and dispatch |
| `0012-image-qwen21-rope-table.patch` | the Qwen-Image 2.1 rope from the precomputed table: `ggml_rope_table` as a mode of `GGML_OP_ROPE`, its CPU forward and its Metal kernel, so the rotation is one pass over the table instead of the generic permute/repeat/multiply/add chain |
| `0013-image-qwen21-bf16-f16-mul-mm.patch` | the `bf16` weights against `f16` inputs matmul kernel, which a runtime bf16 LoRA on Qwen-Image 2.1 asks for: read as half, exact for bf16 values in their range |

The series is a merge of the ported `llama/metal/` series with upstream's newer ggml, so it is
one patch per area rather than one per feature. `scripts/test-amd-metal-port.sh` checks it:
that the series applies to the pinned commit, that no two Metal function constants claim the
same index, that the wave64 kernels are there, that the ggml-level API the Metal side calls is
declared, and that the op tables match the op enum. With `--build` it also builds the ported
ggml and runs the backend op tests on the Metal device.

Two things upstream's newer ggml changed under the backend:

- The `mul_mat_id` arguments were replaced by a routing map, so the expert GEMM's wave64 and
  half variants are written for arguments that no longer exist. They are off; the dense kernel
  runs the expert GEMM. A diffusion model does not use it, a Mixture-of-Experts text encoder
  does.
- The Metal compiler fails on the mxfp4 expert GEMM, so those weights are computed on the host.

## Flash attention on AMD

Upstream's Metal flash-attention support check ends in `return has_simdgroup_mm`, asking for
Apple's simdgroup matrix instructions. A Radeon never reports those (it reports Metal3, which
only `has_simdgroup_reduction` picks up), so flash attention is disabled on AMD and every
attention falls back to the full score matrix. That is the current, correct behaviour.

Turning the gate on is not just a switch. The backend carries AMD-adapted flash kernels
(`kernel_flash_attn_ext_*_amd`), but the host dispatch never selects the `_amd` names. What the
dispatch does select is the stock `kernel_flash_attn_ext_vec`, which on a Radeon is wrong —
`test-backend-ops` reports `inf` for `hsk=64` and a precision loss for `hsk=512`, the head sizes
the diffusion models use. So the AMD flash path needs the `_amd` kernels wired into the dispatch
and validated before the gate can be opened; a bare gate flip routes image generation to a
kernel that returns `inf`.

## The image engine's upstream commits

The image engine takes upstream stable-diffusion.cpp master whole, named in
`scripts/build-engines.sh` as `SD_COMMIT`. It used to be a base plus a list of commits
cherry-picked onto it (`SD_CHERRY_PICKS`), because the ggml it was pinned to predated the
ggml-ext registry, the runner's chunk helper and the compute callback that upstream master's own
commits ask for. The ggml moved to the commit that has them, so the list is empty and the
engine follows upstream: FLUX.3, Chroma, MiniMax-H3-Image and the rest arrive with the next
upstream pull instead of one commit at a time.

To move the engine, move `SD_COMMIT` and `GGML_COMMIT` together and port what the new ggml
broke; the checks in `scripts/test-amd-metal-port.sh` say what broke.


## Changing one

The vendor tree carries every patch at once, so `git diff` there is all of them, and it may also
carry experiments that are in no patch. Work in a worktree that has only the series:

```sh
git -C vendor/llama.cpp worktree add -f /tmp/series --detach <LLAMA_COMMIT>
# apply the patches before the one to change, commit, apply that one, edit, then
git -C /tmp/series diff -U8 <base-commit> > patches/llama/<area>/<NNNN-name>.patch
```

Three rules that have each cost real time:

- **`-U8` for `llama/`.** Anything narrower rewrites every hunk header in the file, and the
  `git diff` default of three lets a hunk land in a different kernel while the build still
  exits 0. Add new files with `git add -A` and take `git diff --cached`, or they are left out.
- **Every later patch must still apply.** `scripts/check-patch-series.sh <LLAMA_COMMIT>` runs the
  whole series in a throwaway worktree and reports each patch.
- **Verify the round trip.** Apply the whole series into a worktree at the pinned commit, and
  diff it against the tree you built and measured. No source file may differ.

`scripts/build-engines.sh` resets the vendor tree and re-applies the patch files, so working
tree edits are discarded: regenerate before building, never after.
