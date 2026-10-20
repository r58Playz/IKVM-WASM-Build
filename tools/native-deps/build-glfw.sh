#!/usr/bin/env bash
# build-glfw.sh - Builds emscripten-glfw for WASM against mesa-wink, Mesa's own OpenGL on WebGPU, and stages wink's
# archives and JS libraries next to it.
#
# mesa-wink (https://github.com/MercuryWorkshop/mesa-wink, branch `wink`) is cloned and built with its own script,
# `wink/build.sh --variant=<mt|st>`. It is the only GL
# backend: NG-GL4ES/Krypton (WebGL) and MobileGL (WebGPU) were removed. GL is reached only through wink_get_proc_address
# (the patched GLFW's glXGetProcAddress), because a static wasm link has one namespace and wink exports no gl* symbol.
#
# Outputs in out/<variant>/:
#   libglfw3.a                         GLFW, compiled against wink's headers
#   libwink.a libwink_webgpu.a libwink_tint.a   mesa-wink (st/mesa + gex_wgpu + Tint + emdawnwebgpu's webgpu.cpp)
#   lib_emscripten_glfw3.js            GLFW's JS library
#   wink-js/NN-<name>.js               wink's --js-library files, numbered in the order the link must pass them
#
# Both GLFW and wink are compiled with upstream emsdk 3.1.56; the app links them with .NET's emsdk (wink/README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

EMSCRIPTEN_GLFW_REPO="https://github.com/pongasoft/emscripten-glfw.git"
# Latest emscripten-glfw release verified to build with emsdk 3.1.56.
EMSCRIPTEN_GLFW_REF="${EMSCRIPTEN_GLFW_REF:-v3.4.0.20250607}"
EMSCRIPTEN_GLFW_PATCH="${EMSCRIPTEN_GLFW_PATCH:-$SCRIPT_DIR/emscripten-glfw.patch}"

MESA_WINK_REPO="${MESA_WINK_REPO:-https://github.com/MercuryWorkshop/mesa-wink.git}"
MESA_WINK_REF="${MESA_WINK_REF:-f2928f2fc363692bae3a2d827ee5fabc4c7a3572}"
# Like IKVM_DIR, this can point at an existing working checkout.
WINK_SRC_DIR="${MESA_WINK_DIR:-$WORKSPACE/mesa-wink}"

OUTPUT_DIR="${OUTPUT_DIR:-}"
VARIANT="${VARIANT:-mt}"
KEEP_TMP="false"
TMP_DIR=""

usage() {
    cat <<'USAGE'
Usage: build-glfw.sh [options]

Options:
  --variant=<mt|st>            Build variant for both GLFW and wink (default: mt).
  --wink-ref=<ref>             Initial mesa-wink git ref (default: pinned commit, or $MESA_WINK_REF).
  --output-dir=<path>          Output directory (default: tools/native-deps/out/<variant>).
  --glfw-ref=<ref>             emscripten-glfw git ref (default: v3.4.0.20250607).
  --tmp-dir=<path>             Temporary build directory (default: mktemp).
  --keep-tmp                   Keep temporary build directory.
  -h, --help                   Show this help message.

Clones mesa-wink with full history into tools/native-deps/mesa-wink (or
$MESA_WINK_DIR), starting its local wink branch at the pinned ref. Existing
checkouts are built as they stand, including local commits and edits; the ref
only applies when cloning. Install its host tools first: git, curl, cmake, ninja,
bison >= 3, flex, and Python >= 3.10 with venv support. Wink uses $EMSDK when set,
and caches its build dependencies in ${XDG_CACHE_HOME:-~/.cache}/mesa-wink.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --wink-ref=*) MESA_WINK_REF="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --glfw-ref=*) EMSCRIPTEN_GLFW_REF="${arg#*=}" ;;
        --tmp-dir=*) TMP_DIR="${arg#*=}" ;;
        --keep-tmp) KEEP_TMP="true" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$arg'" >&2; usage; exit 1 ;;
    esac
done

log() {
    echo "[build-glfw/$VARIANT] $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command '$1' not found" >&2
        exit 1
    fi
}

apply_patch_once() {
    local repo_dir="$1"
    local patch_file="$2"
    local patch_name="$3"

    if [ ! -f "$patch_file" ]; then
        return 0
    fi

    if git -C "$repo_dir" apply --check "$patch_file" >/dev/null 2>&1; then
        log "Applying $patch_name"
        git -C "$repo_dir" apply "$patch_file"
    elif git -C "$repo_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        log "$patch_name already applied, skipping."
    else
        echo "ERROR: $patch_name cannot be applied cleanly in $repo_dir" >&2
        exit 1
    fi
}

require_cmd git
require_cmd emcmake
require_cmd cmake
require_cmd emcc
require_cmd python3

CMAKE_GENERATOR=()
if command -v ninja >/dev/null 2>&1; then
    CMAKE_GENERATOR=(-GNinja)
fi

case "$VARIANT" in
    mt)
        GLFW_TARGET="glfw3_pthread"
        GLFW_ARCHIVE_NAME="libglfw3_pthread.a"
        ;;
    st)
        GLFW_TARGET="glfw3"
        GLFW_ARCHIVE_NAME="libglfw3.a"
        ;;
    *)
        echo "ERROR: --variant must be mt or st (got '$VARIANT')" >&2
        exit 1
        ;;
esac

if [ ! -e "$WINK_SRC_DIR/.git" ]; then
    log "Cloning mesa-wink @ $MESA_WINK_REF"
    git clone --no-checkout --branch wink "$MESA_WINK_REPO" "$WINK_SRC_DIR"
    git -C "$WINK_SRC_DIR" checkout -B wink "$MESA_WINK_REF"
else
    log "mesa-wink source already present, using working checkout."
fi
WINK_HEAD="$(git -C "$WINK_SRC_DIR" rev-parse HEAD)"
log "Building mesa-wink's working checkout @ ${WINK_HEAD:0:12} (initial pin: $MESA_WINK_REF)"
if [ -n "$(git -C "$WINK_SRC_DIR" status --porcelain --untracked-files=no)" ]; then
    log "  with uncommitted changes"
fi

log "Building mesa-wink ($VARIANT)"
bash "$WINK_SRC_DIR/wink/build.sh" --variant="$VARIANT"
WINK_OUT="$WINK_SRC_DIR/build/wink/out/$VARIANT"

if [ ! -f "$WINK_OUT/manifest.json" ]; then
    echo "ERROR: mesa-wink build did not produce $WINK_OUT/manifest.json." >&2
    exit 1
fi
WINK_VARIANT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("variant",""))' "$WINK_OUT/manifest.json")"
if [ -n "$WINK_VARIANT" ] && [ "$WINK_VARIANT" != "$VARIANT" ]; then
    echo "ERROR: $WINK_OUT is wink's '$WINK_VARIANT' build, not '$VARIANT'" >&2
    exit 1
fi

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$WORKSPACE/out/$VARIANT"
fi

if [ -n "$TMP_DIR" ]; then
    mkdir -p "$TMP_DIR"
else
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ikvm-glfw-build-${VARIANT}.XXXXXX")"
fi

cleanup() {
    if [ "$KEEP_TMP" = "true" ]; then
        log "Keeping temp directory: $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# emscripten-glfw (the GLFW port). The patch routes its GL context, present and proc-address seams to mesa-wink
# (gl_backend.h, which includes wink_emscripten_compat.h from wink's include directory).
# -----------------------------------------------------------------------------
GLFW_SRC_DIR="$WORKSPACE/emscripten-glfw"
GLFW_BUILD_DIR="$TMP_DIR/glfw-build"

if [ ! -d "$GLFW_SRC_DIR/.git" ]; then
    log "Cloning emscripten-glfw @ $EMSCRIPTEN_GLFW_REF"
    git clone --depth 1 --branch "$EMSCRIPTEN_GLFW_REF" "$EMSCRIPTEN_GLFW_REPO" "$GLFW_SRC_DIR"
else
    log "emscripten-glfw source already present, skipping clone."
fi
apply_patch_once "$GLFW_SRC_DIR" "$EMSCRIPTEN_GLFW_PATCH" "emscripten-glfw.patch"

log "Configuring emscripten-glfw against $WINK_OUT/include"
CXXFLAGS="-I$WINK_OUT/include" CFLAGS="-I$WINK_OUT/include" \
    emcmake cmake -S "$GLFW_SRC_DIR" -B "$GLFW_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "${CMAKE_GENERATOR[@]}"

log "Building $GLFW_TARGET"
cmake --build "$GLFW_BUILD_DIR" --target "$GLFW_TARGET" -j"$(nproc)"

GLFW_ARCHIVE="$GLFW_BUILD_DIR/$GLFW_ARCHIVE_NAME"
if [ ! -f "$GLFW_ARCHIVE" ]; then
    echo "ERROR: expected glfw archive not found: $GLFW_ARCHIVE" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"/libglfw3.a "$OUTPUT_DIR"/libwink*.a "$OUTPUT_DIR"/wink-js "$OUTPUT_DIR"/*.js
cp "$GLFW_ARCHIVE" "$OUTPUT_DIR/libglfw3.a"
cp "$GLFW_SRC_DIR/src/js/lib_emscripten_glfw3.js" "$OUTPUT_DIR/lib_emscripten_glfw3.js"
for a in libwink.a libwink_webgpu.a libwink_tint.a; do
    if [ ! -f "$WINK_OUT/lib/$a" ]; then
        echo "ERROR: expected wink archive not found: $WINK_OUT/lib/$a" >&2
        exit 1
    fi
    cp "$WINK_OUT/lib/$a" "$OUTPUT_DIR/$a"
done
# wink's JS libraries, numbered in the order the manifest lists them (the link must pass them in that order)
mkdir -p "$OUTPUT_DIR/wink-js"
python3 - "$WINK_OUT" "$OUTPUT_DIR/wink-js" <<'PY'
import json, os, shutil, sys
out, dest = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(out, "manifest.json")))
js = (m.get("link") or {}).get("js_libraries")
if not js:
    sys.exit("manifest.json has no link.js_libraries")
for i, rel in enumerate(js):
    shutil.copy(os.path.join(out, rel), os.path.join(dest, "%02d-%s" % (i, os.path.basename(rel))))
PY

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR" "$OUTPUT_DIR/wink-js"
