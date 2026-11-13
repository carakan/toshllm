#!/bin/zsh
# Checks that the AMD Metal port on top of upstream ggml is intact.
#
# The port is a merged series, so a hunk can land on the wrong function and the build
# still succeeds. These checks catch the ways that shows up:
#
#   * the series no longer applies to the ggml commit the engine pins
#   * two Metal function constants claim the same index in one file, which the Metal
#     compiler rejects with a duplicate-index error
#   * the host asks for a kernel the port does not define
#   * the ggml-level API the Metal side calls (the TurboQuant types, the Dynamic MoE
#     ops) is missing from the header
#
#   ./scripts/test-amd-metal-port.sh            # the static checks, a few seconds
#   ./scripts/test-amd-metal-port.sh --build    # also build the ported ggml and run the
#                                               # backend op tests on the Metal device
#
# Exit 0 when every check passes, 1 otherwise.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"

BUILD=0
[ "${1:-}" = "--build" ] && BUILD=1

fails=0
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok()   { echo "  ok: $1"; }

# The ggml commit the image engine pins, and the series that ports onto it.
GGML_COMMIT="$(grep -oE 'GGML_COMMIT:-[a-f0-9]+' scripts/build-engines.sh | cut -d- -f2)"
[ -n "$GGML_COMMIT" ] || { echo "no GGML_COMMIT in scripts/build-engines.sh" >&2; exit 1; }
SERIES=(patches/image-metal/*.patch(N))
[ ${#SERIES} -gt 0 ] || { echo "no patches under patches/image-metal" >&2; exit 1; }

# The ggml sources live in the image engine's submodule; the series is applied from the
# engine's root, where the submodule sits in ggml/.
GGML_DIR="$ROOT/vendor/stable-diffusion.cpp/ggml"
ENGINE_DIR="$ROOT/vendor/stable-diffusion.cpp"
if [ ! -d "$GGML_DIR/.git" ] && [ ! -f "$GGML_DIR/.git" ]; then
    echo "FAIL: $GGML_DIR is not a git checkout; run ./scripts/build-engines.sh first" >&2
    exit 1
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "AMD Metal port checks (ggml $GGML_COMMIT)"
echo

# 1. The series applies to the pinned commit.
echo "the series applies to the pinned ggml"
git -C "$GGML_DIR" worktree add -q --detach "$WORK/ggml" "$GGML_COMMIT" 2>/dev/null
if [ ! -d "$WORK/ggml" ]; then
    echo "  (the commit is not in the local clone; fetching it)"
    git -C "$GGML_DIR" fetch -q origin "$GGML_COMMIT" && \
        git -C "$GGML_DIR" worktree add -q --detach "$WORK/ggml" "$GGML_COMMIT"
fi
[ -d "$WORK/ggml" ] || { fail "cannot get the ggml worktree at $GGML_COMMIT"; exit 1; }

# The worktree is the ggml project itself; the series is written against the engine's
# root, where the submodule sits in ggml/, so the paths are prefixed on the way in.
for patch in $SERIES; do
    # each patch lands on the series before it, the way the build applies them, so a
    # patch is checked against the accumulated tree and not against the bare commit
    if ! git -C "$WORK/ggml" apply --check -p2 "$ROOT/$patch" 2>/dev/null; then
        fail "$(basename "$patch") does not apply after the patches before it"
        git -C "$WORK/ggml" apply --check -p2 "$ROOT/$patch" 2>&1 | head -5
    else
        ok "$(basename "$patch")"
        git -C "$WORK/ggml" apply -p2 "$ROOT/$patch" 2>/dev/null
    fi
done

KERNELS="$WORK/ggml/src/ggml-metal/kernels"

# 2. No two function constants in one file claim the same index.
echo
echo "the Metal function constants have no duplicate index"
dupes=$(python3 - "$KERNELS" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for name in sorted(os.listdir(root)):
    if not name.endswith((".metal", ".h")):
        continue
    seen = {}
    for i, line in enumerate(open(os.path.join(root, name), encoding="utf-8", errors="replace")):
        # a commented-out declaration is not a claim on the index
        code = line.split("//", 1)[0]
        for m in re.finditer(r"\[\[function_constant\(\s*([A-Za-z_0-9]+)\s*\+\s*(\d+)\s*\)\]\]", code):
            key = (m.group(1), int(m.group(2)))
            if key in seen:
                bad.append(f"{name}: {key[0]}+{key[1]} is claimed twice (lines {seen[key]} and {i+1})")
            else:
                seen[key] = i + 1
print("\n".join(bad))
PY
)
if [ -n "$dupes" ]; then
    print -r -- "$dupes" | while read -r line; do fail "$line"; done
    fails=$((fails + $(print -r -- "$dupes" | grep -c .)))
else
    ok "every index is claimed once per file"
fi

# 3. The kernels the host names by hand exist.
echo
echo "the kernels the host names exist"
missing=$(python3 - "$WORK/ggml/src/ggml-metal" <<'PY'
import os, re, sys
root = sys.argv[1]
kernels = os.path.join(root, "kernels")
# The kernel names the Metal library knows are the host_names the shaders declare. The
# upstream kernels build theirs from the type name, so only the fixed ones can be read
# back from the source; the rest is what the backend op tests below cover at runtime.
defined = set()
for name in os.listdir(kernels):
    if not name.endswith(".metal"):
        continue
    for m in re.finditer(r'host_name\("(kernel_[a-z0-9_]+)"\)',
                         open(os.path.join(kernels, name), encoding="utf-8", errors="replace").read()):
        defined.add(m.group(1))
bad = []
for want in ("kernel_mul_mm_f32_f32_w64", "kernel_mul_mv_iq1_m_f32_r1_w64", "kernel_mul_mm_f16_f32_w_w64"):
    if want not in defined:
        bad.append(want)
print("\n".join(bad))
PY
)
if [ -n "$missing" ]; then
    print -r -- "$missing" | while read -r line; do fail "$line is missing from the kernels"; done
    fails=$((fails + $(print -r -- "$missing" | grep -c .)))
else
    ok "the wave64 kernels the AMD backend needs are there"
fi

# 4. The ggml-level API the Metal side calls is declared.
echo
echo "the ggml-level API the Metal side calls is declared"
header="$WORK/ggml/include/ggml.h"
for sym in GGML_TYPE_TURBO2_0 GGML_TYPE_TURBO3_0 GGML_TYPE_TURBO4_0 GGML_TYPE_TQ3_1S GGML_TYPE_TQ4_1S \
           GGML_TYPE_PQ2_0 GGML_TYPE_PTQ1_0 GGML_OP_TOSH_DMOE_PUBLISH GGML_OP_TOSH_DMOE_JOIN \
           GGML_OP_TOSH_DMOE_OBSERVE; do
    if grep -q "\b$sym\b" "$header"; then
        ok "$sym"
    else
        fail "$sym is missing from include/ggml.h"
    fi
done

# 5. The op tables and the enum agree, which is what the linker checks.
echo
echo "the op tables match the op enum"
python3 - "$WORK/ggml" <<'PY'
import re, sys
root = sys.argv[1]
header = open(root + "/include/ggml.h", encoding="utf-8").read()
body = open(root + "/src/ggml.c", encoding="utf-8").read()
m = re.search(r"enum ggml_op \{(.*?)\n    \};", header, re.S)
enum = re.findall(r"\b(GGML_OP_[A-Z0-9_]+)", m.group(1))
enum = [e for e in enum if e != "GGML_OP_COUNT"]
for table in ("GGML_OP_NAME", "GGML_OP_SYMBOL"):
    m = re.search(r"static const char \* " + table + r"\[GGML_OP_COUNT\] = \{(.*?)\n\};", body, re.S)
    rows = [l for l in m.group(1).split("\n") if l.strip().startswith('"')]
    if len(rows) != len(enum):
        print(f"FAIL: {table} has {len(rows)} entries but the enum has {len(enum)}")
    else:
        print(f"  ok: {table} has one entry per op ({len(rows)})")
PY

# 6. With --build, the ported ggml compiles and the backend op tests pass on the Metal
#    device. The shaders are embedded, so a kernel that does not compile fails the build
#    rather than the first model load.
if [ "$BUILD" = 1 ]; then
    echo
    echo "the ported ggml builds and passes the backend op tests"
    cmake -B "$WORK/build" -S "$WORK/ggml" \
        -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
        > "$WORK/cmake.log" 2>&1 || { fail "cmake failed, see $WORK/cmake.log"; cmake_ok=0; }
    if cmake --build "$WORK/build" -j "$(sysctl -n hw.ncpu)" > "$WORK/build.log" 2>&1; then
        ok "the ported ggml builds, shaders included"
        if "$WORK/build/bin/test-backend-ops" test > "$WORK/ops.log" 2>&1; then
            ok "the backend op tests pass"
        else
            fail "the backend op tests failed, see $WORK/ops.log"
            grep -E "FAIL|not supported" "$WORK/ops.log" | head -20
        fi
    else
        fail "the ported ggml does not build, see $WORK/build.log"
        grep -E "error:" "$WORK/build.log" | head -20
    fi
fi

echo
if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) failed"
    exit 1
fi
echo "every check passed"
exit 0
