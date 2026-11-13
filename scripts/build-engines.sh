#!/bin/zsh
# Builds the inference engines reproducibly:
#   1. Official llama.cpp + AMD patches  -> vendor/llama.cpp/build-static/bin
#   2. whisper.cpp speech-to-text        -> vendor/whisper.cpp/build-static/bin
#
# Usage:
#   ./scripts/build-engines.sh                  # host architecture
#   ARCH=x86_64 ./scripts/build-engines.sh      # cross-compile (CI on arm64 runners)
#   ARCH=universal ./scripts/build-engines.sh   # x86_64 + arm64 fat binaries (experimental)
set -e
cd "$(dirname "$0")/.."
ROOT="$PWD"

# Strips the debug symbols and the local symbols from a binary, so the shipped engine
# carries no DWARF and no symbol table. The binaries are already built Release, which
# leaves the symbol table behind: it names every function and its file, which is both
# size and a map of the source. STRIP=0 keeps them, for a build meant to be debugged.
# The Metal libraries next to the binaries are left alone: a .metallib has no symbols
# to strip, and the runtime reads the source it was built from.
strip_binaries() {
    [ "${STRIP:-1}" = 1 ] || return 0
    local bin
    for bin in "$@"; do
        [ -f "$bin" ] || continue
        strip -S -x "$bin"
    done
}

LLAMA_COMMIT="${LLAMA_COMMIT:-d81235049384534c167caea52b85a694f6103d14}"   # llama.cpp commit validated against the patches
WHISPER_COMMIT="${WHISPER_COMMIT:-371b5a7561823ab2bb32142d2751e35e7534727b}" # whisper.cpp v1.9.3
# stable-diffusion.cpp: upstream master, taken whole. The commits this engine used to
# cherry-pick onto an older base are all in master now, and the ones that were left out
# (the ggml-ext registry, the ggml chunk helper of the runner refactor, the ggml compute
# callback) come with the newer ggml below.
SD_COMMIT="${SD_COMMIT:-b9d7176bf88fe465576e0aafbe47ba253ffcfc2c}"   # stable-diffusion.cpp master
SD_CHERRY_PICKS="${SD_CHERRY_PICKS:-}"
# ggml: upstream split ggml-metal.metal into kernels/ and added the ggml-ext registry that
# stable-diffusion.cpp master registers its custom kernels with. The AMD Metal backend is
# ported onto that layout in patches/image-metal.
GGML_COMMIT="${GGML_COMMIT:-d803c238f67915fb825a9aa4df27b99356d51597}"
ARCH="${ARCH:-$(uname -m)}"
DEPLOYMENT_TARGET="14.0"        # same floor as the app (Package.swift)
if [ "$ARCH" = "universal" ]; then
    # Build each slice separately (ggml has per-arch sources) and lipo them.
    for slice in x86_64 arm64; do
        ARCH="$slice" "$0"
        for dir in vendor/llama.cpp vendor/whisper.cpp; do
            [ -d "$dir/build-static/bin" ] || continue
            for tool in llama-server llama-bench llama-perplexity whisper-cli whisper-server; do
                mv "$dir/build-static/bin/$tool" "$dir/build-static/bin/$tool.$slice" 2>/dev/null || true
            done
        done
    done
    for dir in vendor/llama.cpp vendor/whisper.cpp; do
        [ -d "$dir/build-static/bin" ] || continue
        for tool in llama-server llama-bench llama-perplexity whisper-cli whisper-server; do
            if [ -f "$dir/build-static/bin/$tool.x86_64" ] && [ -f "$dir/build-static/bin/$tool.arm64" ]; then
                lipo -create -output "$dir/build-static/bin/$tool" \
                    "$dir/build-static/bin/$tool.x86_64" "$dir/build-static/bin/$tool.arm64"
                rm "$dir/build-static/bin/$tool".{x86_64,arm64}
            fi
        done
    done
    echo "universal engines ready"
    exit 0
fi

# The shaders are always embedded, but compiling them at launch costs tens of seconds, so a
# precompiled default.metallib ships alongside and device.m prefers it on matching GPUs.
# Building it needs the Metal Toolchain from full Xcode, downloaded below if missing.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun metal -v >/dev/null 2>&1 || ! xcrun -f metallib >/dev/null 2>&1; then
    xcodebuild -downloadComponent MetalToolchain >/dev/null 2>&1 || true
fi
resolve_metal_toolchain() {
    # Resolve the demand-mounted toolchain before each shader build.
    xcrun metal -v >/dev/null 2>&1 || return 1
    METAL_COMPILER="$(xcrun -f metal 2>/dev/null)" || return 1
    METALLIB_COMPILER="$(xcrun -f metallib 2>/dev/null)" || return 1
    [ -x "$METAL_COMPILER" ] && [ -x "$METALLIB_COMPILER" ]
}

if resolve_metal_toolchain; then
    METAL_PRECOMPILE=1
    echo "Metal compiler available — will precompile default.metallib (fast model load)"
else
    METAL_PRECOMPILE=0
    echo "Metal compiler unavailable — embedded source only (slower first load)"
fi

# Stamped into the binaries so a log identifies the ToshLLM build, not just the
# upstream commit (which is unchanged across releases that only touch the patch).
TOSH_VERSION="$(tr -d '[:space:]' < "$(dirname "$0")/../VERSION")"

# CI runners drop DNS or reset a transfer now and then, and a release build should not lose
# minutes of compilation to it, so every networked git operation retries with backoff.
retry_git() {
    local attempt=1
    local max_attempts=4
    local delay

    while ! "$@"; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "ERROR: git operation failed after $max_attempts attempts: $*" >&2
            return 1
        fi
        delay=$((attempt * 10))
        echo "Git network operation failed (attempt $attempt/$max_attempts); retrying in ${delay}s..." >&2
        sleep "$delay"
        attempt=$((attempt + 1))
    done
}

# A build-static left from before a system or Command Line Tools update keeps the old SDK and
# compiler paths in its cache, and cmake never re-detects them: the link then fails with
# "library 'System' not found". Drop such a cache so the next configure starts clean.
reset_stale_cmake_cache() {
    local cache="$1/CMakeCache.txt" key cached
    [ -f "$cache" ] || return 0
    for key in CMAKE_OSX_SYSROOT CMAKE_C_COMPILER CMAKE_CXX_COMPILER; do
        cached=$(sed -n "s/^$key:[A-Z]*=//p" "$cache")
        if [ -n "$cached" ] && [ "${cached#/}" != "$cached" ] && [ ! -e "$cached" ]; then
            echo "stale cmake cache in $1 ($key -> $cached); reconfiguring"
            rm -rf "$cache" "$1/CMakeFiles"
            return 0
        fi
    done
}

CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DBUILD_SHARED_LIBS=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    # Compile the experimental MoE cache into the bundled engine. It remains
    # inert unless the app explicitly sets TOSH_MOE_MODE at process launch.
    -DTOSH_ENABLE_DYNAMIC_MOE=ON
    -DGGML_NATIVE=OFF
    -DCMAKE_OSX_ARCHITECTURES="$ARCH"
    # cmake defaults it to the build host, so a macos-26 runner emits binaries dyld
    # refuses to start on older systems
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    -DCMAKE_CXX_FLAGS="-DTOSH_VERSION=$TOSH_VERSION"
    # The server binds to localhost only; skip OpenSSL so static cross-builds
    # don't pick up host-arch Homebrew libraries on CI runners.
    -DLLAMA_OPENSSL=OFF
)

# pin every ISA flag in both variants: with GGML_NATIVE=OFF ggml's defaults follow the build
# host, an arm64 runner cross-building x86_64 does not count as cross-compiling, and a flag left
# out keeps whatever the previous variant cached in build-static. TOSH_NO_AVX2=1 is the SSE4.2
# baseline for pre-AVX Xeons.
ISA_FLAGS=()
if [ "$ARCH" = "x86_64" ]; then
    if [ -z "${TOSH_NO_AVX2:-}" ]; then
        ISA_FLAGS=(-DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON
                   -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_AVX_VNNI=OFF -DGGML_AVX512=OFF)
    else
        ISA_FLAGS=(-DGGML_SSE42=ON -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF
                   -DGGML_F16C=OFF -DGGML_BMI2=OFF -DGGML_AVX_VNNI=OFF -DGGML_AVX512=OFF)
    fi
    CMAKE_FLAGS+=("${ISA_FLAGS[@]}")
fi

build_engine() {
    local vendor="$1" ref="$2" fetch_ref="$3"
    shift 3
    local patches=("$@")

    if [ ! -d "$vendor/.git" ]; then
        retry_git git clone --filter=blob:none https://github.com/ggml-org/llama.cpp "$vendor"
    fi
    cd "$vendor"
    retry_git git fetch origin "$fetch_ref" 2>/dev/null || retry_git git fetch origin
    git checkout -qf "$ref"
    git checkout -- . 2>/dev/null || true
    # files a patch creates are untracked, so the checkout above leaves them behind
    # and the next apply fails; build dirs are gitignored and survive this
    git clean -qfd 2>/dev/null || true

    for patch in "${patches[@]}"; do
        git apply "$patch"
        echo "applied ${patch#$ROOT/patches/}"
    done

    reset_stale_cmake_cache build-static
    cmake -B build-static "${CMAKE_FLAGS[@]}"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t llama-server llama-bench llama-perplexity test-backend-ops

    # One library per kernel source, with the same defines the runtime would use on an Intel/AMD
    # GPU. They cannot be linked into one metallib: the sources share helper names.
    local embed_dir="build-static/ggml/src/ggml-metal/autogenerated"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -n "$(echo $embed_dir/ggml-metal-embed-*.metal(N))" ]; then
        local kernels="build-static/bin/kernels"
        rm -rf "$kernels"
        mkdir -p "$kernels"
        local ok=1
        if resolve_metal_toolchain; then
            for src in $embed_dir/ggml-metal-embed-*.metal; do
                local name="${${src:t:r}#ggml-metal-embed-}"
                "$METAL_COMPILER" -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                    -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                    -I ggml/src -I ggml/src/ggml-metal \
                    -c "$src" -o "$kernels/$name.air" &&
                "$METALLIB_COMPILER" "$kernels/$name.air" -o "$kernels/$name.metallib" || { ok=0; break; }
                # the engine loads a library only if its source matches the one embedded in the binary
                echo "$name $(shasum -a 256 "$src" | cut -d' ' -f1)" >> "$kernels/fingerprint"
            done
        else
            ok=0
        fi
        rm -f "$kernels"/*.air
        if [ "$ok" = 1 ]; then
            echo "precompiled $(ls "$kernels" | wc -l | tr -d ' ') metal libraries ($(du -sh "$kernels" | cut -f1))"
        else
            rm -rf "$kernels"
            echo "WARNING: metallib precompile failed — falling back to runtime compile"
            # Avoid repeating a failed optional precompile.
            METAL_PRECOMPILE=0
        fi
    fi
    strip_binaries build-static/bin/llama-server build-static/bin/llama-bench \
                   build-static/bin/llama-perplexity build-static/bin/test-backend-ops
    echo "engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

build_whisper_engine() {
    local vendor="vendor/whisper.cpp"
    if [ ! -d "$vendor/.git" ]; then
        retry_git git clone --filter=blob:none https://github.com/ggml-org/whisper.cpp "$vendor"
    fi
    cd "$vendor"
    retry_git git fetch origin "$WHISPER_COMMIT" 2>/dev/null || retry_git git fetch origin
    git checkout -qf "$WHISPER_COMMIT"
    git checkout -- . 2>/dev/null || true
    git clean -qfd 2>/dev/null || true

    # Reuse the shared AMD Metal series before applying Whisper-specific patches. It lives
    # apart from patches/llama because upstream split ggml-metal.metal into kernels/, and this
    # engine is pinned to a commit from before that split.
    for patch in "$ROOT"/patches/shared-metal/0001-*.patch; do
        [ -f "$patch" ] || continue
        git apply --include='ggml/src/ggml-metal/**' "$patch"
        echo "applied ${patch#$ROOT/patches/}"
    done
    for patch in "$ROOT"/patches/whisper/*.patch; do
        [ -f "$patch" ] || continue
        git apply "$patch"
        echo "applied ${patch#$ROOT/patches/}"
    done

    local isa=("${ISA_FLAGS[@]}")
    reset_stale_cmake_cache build-static
    cmake -B build-static \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DWHISPER_BUILD_SERVER=ON \
        -DWHISPER_BUILD_EXAMPLES=ON \
        -DWHISPER_BUILD_IS_DEV=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_NATIVE=OFF \
        "${isa[@]}" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t whisper-cli whisper-server

    # Precompile Metal shaders for first use.
    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if resolve_metal_toolchain && "$METAL_COMPILER" -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -I ggml/src -I ggml/src/ggml-metal \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           "$METALLIB_COMPILER" build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib for speech engine"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
            echo "WARNING: speech metallib precompile failed — using embedded source" >&2
            METAL_PRECOMPILE=0
        fi
    fi
    strip_binaries build-static/bin/whisper-cli build-static/bin/whisper-server
    echo "speech-to-text engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

# stable-diffusion.cpp shares the ggml/Metal stack, so it takes the ggml-metal hunks of the
# 0001 series and nothing else; the llama half has no counterpart here.
build_image_engine() {
    local vendor="vendor/stable-diffusion.cpp"
    # `git clone --recursive` stalls on the ggml submodule fetch on flaky links;
    # clone the main repo, then init the submodule separately, both abort-and-retry
    # on a stalled transfer instead of hanging.
    if [ ! -d "$vendor/.git" ]; then
        retry_git env GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
            git clone https://github.com/leejet/stable-diffusion.cpp "$vendor"
    fi
    cd "$vendor"
    retry_git git fetch origin
    # the previous build left the patches in both working trees; a bump that moves the
    # submodule cannot check the new commit out over them, so revert before switching
    git -C ggml checkout -- . 2>/dev/null || true
    # the Metal port adds kernel files; they are untracked, so the checkout above leaves
    # them behind and the next apply fails
    git -C ggml clean -qfd 2>/dev/null || true
    git checkout -- . 2>/dev/null || true
    git checkout -qf "$SD_COMMIT"
    # The upstream commits this engine needs are cherry-picked on top of the base, so the tree
    # comes from upstream alone and no local commit has to be pushed anywhere. Each one is
    # checked out as a commit of its own, then the whole set is committed together. The list is
    # empty now that the engine takes upstream master whole; the mechanism stays for the next
    # upstream bump that cannot.
    for pick in ${=SD_CHERRY_PICKS}; do
        if ! git cherry-pick -n "$pick"; then
            echo "ERROR: cannot cherry-pick $pick onto $SD_COMMIT" >&2
            git cherry-pick --abort 2>/dev/null || true
            exit 1
        fi
    done
    if [ -n "$SD_CHERRY_PICKS" ]; then
        git commit -q -m "ToshLLM: the upstream commits cherry-picked onto $SD_COMMIT"
    fi
    git submodule sync --recursive
    retry_git env GIT_HTTP_LOW_SPEED_LIMIT=2000 GIT_HTTP_LOW_SPEED_TIME=30 \
        git submodule update --init --recursive
    # The image engine takes the ggml commit its Metal port targets; upstream master pins the
    # same one, and the two are kept together so the port and the engine code agree.
    retry_git git -C ggml fetch -q origin "$GGML_COMMIT" 2>/dev/null || true
    git -C ggml checkout -qf "$GGML_COMMIT"
    git checkout -- . 2>/dev/null || true
    git -C ggml checkout -- . 2>/dev/null || true

    # The AMD Metal backend, ported onto upstream's kernels/ layout: the ggml-level types
    # and ops it needs, the Metal kernels, and the Metal host side.
    for patch in "$ROOT"/patches/image-metal/*.patch; do
        [ -f "$patch" ] || continue
        git apply -p1 "$patch"
        echo "applied ${patch#$ROOT/patches/}"
    done
    # Two fixes upstream ggml has not taken yet, and they still apply on the new base:
    # a failed buffer allocation dereferenced a null buffer instead of reporting the OOM,
    # and flash attention accepted the asymmetric K/V pairs its kernels do not cover.
    git apply --include='ggml/src/ggml-metal/*' -p1 "$ROOT/patches/image/0073-image-metal-alloc-null-check.patch"
    git apply --include='ggml/src/ggml-metal/*' -p1 "$ROOT/patches/image/0074-image-metal-fa-kv-guards.patch"
    # sd.cpp core (outside the ggml submodule).
    git apply -p1 "$ROOT/patches/image/0049-image-free-diffusion-before-video-decode.patch"
    # Yield between VAE tiles to keep the desktop responsive.
    git apply -p1 "$ROOT/patches/image/0050-image-vae-tile-yield.patch"
    # Read tensors with pread: stdio refills 4 KiB at a time and the load ran at a tenth
    # of what the disk gives.
    git apply -p1 "$ROOT/patches/image/0051-image-loader-pread.patch"
    # Convert bf16 weights on load when the device has no bfloat: the Metal backend
    # rejects every op that touches them, and a weight already placed in the device
    # buffer aborts the load instead of falling back.
    git apply -p1 "$ROOT/patches/image/0052-image-bf16-promote-without-bfloat.patch"
    # Cast an f16 weight to f32 before adding a LoRA diff: the diff is f32, Metal wants both
    # operands in one type, and a weight in private VRAM cannot fall back to the CPU for the add.
    git apply -p1 "$ROOT/patches/image/0053-image-lora-f16-weight-cast.patch"
    # Qwen-Image 2.1 runs its fused gate/up projection through one SwiGLU instead of copying
    # both halves out first; TOSH_QWEN21_SWIGLU_DISABLE restores the split graph.
    git apply -p1 "$ROOT/patches/image/0057-image-qwen21-fused-swiglu.patch"
    # The down projection takes its input in F16, which its tile loader rounds to anyway.
    git apply -p1 "$ROOT/patches/image/0061-image-qwen21-down-f16.patch"

    # The Metal port is a merged series, so a hunk can land on the wrong function and still
    # exit 0. Assert the markers that show the port took.
    local kernels="ggml/src/ggml-metal/kernels"
    for kernel in mul_mm_w64.metal mul_mv_w64.metal fa_w64.metal; do
        if [ ! -f "$kernels/$kernel" ]; then
            echo "ERROR: the AMD Metal port did not land: $kernels/$kernel is missing" >&2
            exit 1
        fi
    done
    # the routing map's expert count moved past the AMD function constants
    if ! grep -q "FC_mul_mm_id_map0_ne02 \[\[function_constant(FC_MUL_MM + 14)\]\]" "$kernels/mul_mm.metal"; then
        echo "ERROR: the AMD Metal port did not land: the mul_mm function constants moved" >&2
        exit 1
    fi

    local isa=("${ISA_FLAGS[@]}")
    reset_stale_cmake_cache build-static
    cmake -B build-static \
        -DCMAKE_BUILD_TYPE=Release \
        -DSD_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DGGML_NATIVE=OFF \
        "${isa[@]}" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    cmake --build build-static --config Release -j "$(sysctl -n hw.ncpu)" -t sd-cli

    local merged="build-static/ggml/src/ggml-metal/autogenerated/ggml-metal-embed.metal"
    if [ "$METAL_PRECOMPILE" = 1 ] && [ -f "$merged" ]; then
        if resolve_metal_toolchain && "$METAL_COMPILER" -O3 -mmacosx-version-min=14.0 -std=metal3.1 \
                -DGGML_METAL_EMBED_LIBRARY -DGGML_METAL_HAS_BF16 \
                -I ggml/src -I ggml/src/ggml-metal \
                -c "$merged" -o build-static/bin/ggml-metal.air &&
           "$METALLIB_COMPILER" build-static/bin/ggml-metal.air \
                -o build-static/bin/default.metallib; then
            rm -f build-static/bin/ggml-metal.air
            echo "precompiled default.metallib for image engine"
        else
            rm -f build-static/bin/ggml-metal.air build-static/bin/default.metallib
            # Embedded source remains available for runtime compilation.
            echo "WARNING: image metallib precompile failed — using embedded source" >&2
            METAL_PRECOMPILE=0
        fi
    fi
    strip_binaries build-static/bin/sd-cli
    echo "image engine ready at $PWD/build-static/bin (arch: $ARCH)"
    cd "$ROOT"
}

# Patches live in patches/<engine>/<area>/, and the numeric prefix is the apply order across
# every area, so ordering stays global while each area can be regenerated on its own.
patch_series() {
    find "$ROOT/patches/$1" -name '*.patch' -print |
        awk -F/ '{print $NF"\t"$0}' | sort | cut -f2-
}

# 1. Official engine (skip with SKIP_LLAMA=1 when iterating on the image engine)
if [ -z "$SKIP_LLAMA" ]; then
build_engine vendor/llama.cpp "$LLAMA_COMMIT" "$LLAMA_COMMIT" ${(f)"$(patch_series llama)"}
fi

# 2. Speech-to-text engine (skip with SKIP_WHISPER=1)
if [ -z "$SKIP_WHISPER" ]; then
    build_whisper_engine
fi


# 3. Image engine (stable-diffusion.cpp; skip with SKIP_IMAGE=1)
if [ -z "$SKIP_IMAGE" ]; then
    build_image_engine
fi
