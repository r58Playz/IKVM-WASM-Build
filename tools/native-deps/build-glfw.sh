#!/usr/bin/env bash
# build-glfw.sh - Builds emscripten-glfw artifacts for WASM.
# Produces one libglfw3.a archive with a selectable GL translation backend
# (default: Krypton Wrapper / NG-GL4ES).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

EMSCRIPTEN_GLFW_REPO="https://github.com/pongasoft/emscripten-glfw.git"
# Latest emscripten-glfw release verified to build with emsdk 3.1.56.
EMSCRIPTEN_GLFW_REF="${EMSCRIPTEN_GLFW_REF:-v3.4.0.20250607}"
EMSCRIPTEN_GLFW_PATCH="${EMSCRIPTEN_GLFW_PATCH:-$SCRIPT_DIR/emscripten-glfw.patch}"

# MobileGL: our GL 3.3 core + EGL implementation whose Emscripten backend renders through WebGPU.
# It carries the emscripten-glfw adapter (mobilegl_webgl_*) and the SimpleFPEWrapper submodule
# (fixed-function emulation for legacy GL, e.g. Minecraft 1.16 and lower).
MOBILEGL_REPO="${MOBILEGL_REPO:-https://github.com/r58Playz/MobileGL.git}"
MOBILEGL_REF="${MOBILEGL_REF:-feat/wasm-webgpu-backend}"
# Prebuilt tint (SPIR-V -> WGSL). If empty, built per-variant via MobileGL's tools/build-tint.sh
# (the mt variant needs a -pthread tint since the rest of the archive is -pthread).
MOBILEGL_TINT_DIR="${MOBILEGL_TINT_DIR:-}"

NG_GL4ES_REPO="${NG_GL4ES_REPO:-https://github.com/BZLZHH/NG-GL4ES.git}"
NG_GL4ES_REF="${NG_GL4ES_REF:-main}"
NG_GL4ES_PATCH="${NG_GL4ES_PATCH:-$SCRIPT_DIR/kryptonloader.patch}"

GL_BACKEND="${GL_BACKEND:-ng-gl4es}"
NG_GL4ES_DEBUG="${NG_GL4ES_DEBUG:-false}"

OUTPUT_DIR="${OUTPUT_DIR:-}"
VARIANT="${VARIANT:-mt}"
KEEP_TMP="false"
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage: build-glfw.sh [options]

Options:
  --variant=<mt|st>            Build variant (default: mt).
  --gl-backend=<ng-gl4es|mobilegl>
                               GL translation backend (default: ng-gl4es).
                               mobilegl = MobileGL (GL 3.3 core -> WebGPU) + SimpleFPEWrapper.
  --output-dir=<path>          Output directory (default: tools/native-deps/out/<variant>).
  --glfw-ref=<ref>             emscripten-glfw git ref (default: v3.4.0.20250607).
  --mobilegl-ref=<ref>         MobileGL git ref (default: feat/wasm-webgpu-backend).
  --ng-gl4es-ref=<ref>         NG-GL4ES git ref (default: main).
  --ng-gl4es-patch=<path>      NG-GL4ES patch path (default: kryptonloader.patch).
  --ng-gl4es-debug             Build NG-GL4ES with -DDEBUG (enables per-draw trace via DBG()).
  --tmp-dir=<path>             Temporary build directory (default: mktemp).
  --keep-tmp                   Keep temporary build directory.
  -h, --help                   Show this help message.

Environment overrides:
  VARIANT
  OUTPUT_DIR
  GL_BACKEND
  EMSCRIPTEN_GLFW_REF
  MOBILEGL_REPO
  MOBILEGL_REF
  MOBILEGL_TINT_DIR
  NG_GL4ES_REF
  NG_GL4ES_PATCH
  NG_GL4ES_DEBUG               Set to 'true' to enable -DDEBUG (same as --ng-gl4es-debug).
EOF
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --gl-backend=*) GL_BACKEND="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --glfw-ref=*) EMSCRIPTEN_GLFW_REF="${arg#*=}" ;;
        --mobilegl-ref=*) MOBILEGL_REF="${arg#*=}" ;;
        --mobilegl-tint-dir=*) MOBILEGL_TINT_DIR="${arg#*=}" ;;
        --ng-gl4es-ref=*) NG_GL4ES_REF="${arg#*=}" ;;
        --ng-gl4es-patch=*) NG_GL4ES_PATCH="${arg#*=}" ;;
        --ng-gl4es-debug) NG_GL4ES_DEBUG="true" ;;
        --tmp-dir=*) TMP_DIR="${arg#*=}" ;;
        --keep-tmp) KEEP_TMP="true" ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument '$arg'" >&2
            usage
            exit 1
            ;;
    esac
done

log() {
    echo "[build-glfw/$VARIANT/$GL_BACKEND] $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command '$1' not found" >&2
        exit 1
    fi
}

find_first_cmd() {
    local candidate
    for candidate in "$@"; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
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
require_cmd emar
require_cmd python3

CMAKE_GENERATOR=()
if command -v ninja >/dev/null 2>&1; then
    CMAKE_GENERATOR=(-GNinja)
fi

case "$VARIANT" in
    mt)
        GLFW_TARGET="glfw3_pthread"
        GLFW_ARCHIVE_NAME="libglfw3_pthread.a"
        PTHREAD_FLAGS=(-pthread)
        ;;
    st)
        GLFW_TARGET="glfw3"
        GLFW_ARCHIVE_NAME="libglfw3.a"
        PTHREAD_FLAGS=()
        ;;
    *)
        echo "ERROR: --variant must be mt or st (got '$VARIANT')" >&2
        exit 1
        ;;
esac

case "$GL_BACKEND" in
    mobilegl|ng-gl4es)
        ;;
    *)
        echo "ERROR: --gl-backend must be ng-gl4es or mobilegl (got '$GL_BACKEND')" >&2
        exit 1
        ;;
esac

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$WORKSPACE/out/$VARIANT"
fi

if [ -n "$TMP_DIR" ]; then
    mkdir -p "$TMP_DIR"
else
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ikvm-glfw-build-${VARIANT}-${GL_BACKEND}.XXXXXX")"
fi

cleanup() {
    if [ "$KEEP_TMP" = "true" ]; then
        log "Keeping temp directory: $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

GLFW_SRC_DIR="$WORKSPACE/emscripten-glfw"
GLFW_BUILD_DIR="$TMP_DIR/glfw-build"

if [ ! -d "$GLFW_SRC_DIR/.git" ]; then
    log "Cloning emscripten-glfw @ $EMSCRIPTEN_GLFW_REF"
    git clone --depth 1 --branch "$EMSCRIPTEN_GLFW_REF" "$EMSCRIPTEN_GLFW_REPO" "$GLFW_SRC_DIR"
else
    log "emscripten-glfw source already present, skipping clone."
fi
apply_patch_once "$GLFW_SRC_DIR" "$EMSCRIPTEN_GLFW_PATCH" "emscripten-glfw.patch"

# The patched emscripten-glfw selects its GL-backend symbol prefix at compile
# time via #ifdef GL_BACKEND_KRYPTON. Pass the define when building against
# the krypton backend so the wasm references krypton_* (not mobilegl_*).
GLFW_BACKEND_CXXFLAGS=""
if [ "$GL_BACKEND" = "ng-gl4es" ]; then
    GLFW_BACKEND_CXXFLAGS="-DGL_BACKEND_KRYPTON=1"
fi

log "Configuring emscripten-glfw"
emcmake cmake -S "$GLFW_SRC_DIR" -B "$GLFW_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS="$GLFW_BACKEND_CXXFLAGS" \
    "${CMAKE_GENERATOR[@]}"

log "Building $GLFW_TARGET"
cmake --build "$GLFW_BUILD_DIR" --target "$GLFW_TARGET" -j"$(nproc)"

GLFW_ARCHIVE="$GLFW_BUILD_DIR/$GLFW_ARCHIVE_NAME"
if [ ! -f "$GLFW_ARCHIVE" ]; then
    echo "ERROR: expected glfw archive not found: $GLFW_ARCHIVE" >&2
    exit 1
fi

NG_GL4ES_SRC_DIR="$WORKSPACE/NG-GL4ES"
NG_GL4ES_BUILD_DIR="$TMP_DIR/ng-gl4es-build"
NG_GL4ES_ARCHIVES=()

MOBILEGL_SRC_DIR="$WORKSPACE/MobileGL"
MOBILEGL_BUILD_DIR="$TMP_DIR/mobilegl-build"

# Archives combined with --whole-archive (all symbols retained; these hold the glfw/backend
# entry points reached only via proc-address at runtime). Support libs that are merely
# referenced internally go in BACKEND_SUPPORT_ARCHIVES (--no-whole-archive) so duplicate
# symbols across them (e.g. tint's bundled SPIRV-Tools vs glslang's) dedup instead of clashing.
BACKEND_ARCHIVES=()
BACKEND_SUPPORT_ARCHIVES=()

if [ "$GL_BACKEND" = "ng-gl4es" ]; then
    if [ ! -d "$NG_GL4ES_SRC_DIR/.git" ]; then
        log "Cloning NG-GL4ES @ $NG_GL4ES_REF"
        git clone --depth 1 --branch "$NG_GL4ES_REF" "$NG_GL4ES_REPO" "$NG_GL4ES_SRC_DIR"
    else
        log "NG-GL4ES source already present, skipping clone."
    fi

    log "Updating NG-GL4ES submodules"
    git -C "$NG_GL4ES_SRC_DIR" submodule update --init --recursive

    if [ -f "$NG_GL4ES_PATCH" ]; then
        apply_patch_once "$NG_GL4ES_SRC_DIR" "$NG_GL4ES_PATCH" "$(basename "$NG_GL4ES_PATCH")"
    else
        log "WARNING: NG-GL4ES patch not found at $NG_GL4ES_PATCH; build will fail unless emscripten_api.c is already present."
    fi

    NG_GL4ES_CFLAGS=""
    if [ "$VARIANT" = "mt" ]; then
        NG_GL4ES_CFLAGS="-pthread"
    fi
    if [ "$NG_GL4ES_DEBUG" = "true" ]; then
        log "NG-GL4ES debug logging enabled (-DDEBUG)"
        NG_GL4ES_CFLAGS="$NG_GL4ES_CFLAGS -DDEBUG"
    fi

    log "Configuring NG-GL4ES"
    CFLAGS="$NG_GL4ES_CFLAGS" CXXFLAGS="$NG_GL4ES_CFLAGS" emcmake cmake -S "$NG_GL4ES_SRC_DIR" -B "$NG_GL4ES_BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release -DSTATICLIB=ON -DNOX11=ON -DNOEGL=ON "${CMAKE_GENERATOR[@]}"

    log "Building NG-GL4ES"
    cmake --build "$NG_GL4ES_BUILD_DIR" --target ng_gl4es -j"$(nproc)"

    NG_GL4ES_PRIMARY="$NG_GL4ES_BUILD_DIR/libng_gl4es.a"
    if [ ! -f "$NG_GL4ES_PRIMARY" ]; then
        echo "ERROR: expected NG-GL4ES archive not found: $NG_GL4ES_PRIMARY" >&2
        exit 1
    fi

    NG_GL4ES_ARCHIVES=("$NG_GL4ES_PRIMARY")
    NG_GL4ES_OPTIONAL_ARCHIVES=(
        "$NG_GL4ES_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-c.a"
        "$NG_GL4ES_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-core.a"
        "$NG_GL4ES_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-glsl.a"
        "$NG_GL4ES_BUILD_DIR/3rdparty/glslang/glslang/libglslang.a"
        "$NG_GL4ES_BUILD_DIR/3rdparty/glslang/glslang/libMachineIndependent.a"
        "$NG_GL4ES_BUILD_DIR/3rdparty/glslang/glslang/libGenericCodeGen.a"
        "$NG_GL4ES_BUILD_DIR/3rdparty/glslang/glslang/libglslang-default-resource-limits.a"
        "$NG_GL4ES_BUILD_DIR/3rdparty/glslang/SPIRV/libSPIRV.a"
        "$NG_GL4ES_BUILD_DIR/3rdparty/glslang/glslang/OSDependent/Unix/libOSDependent.a"
    )

    for archive in "${NG_GL4ES_OPTIONAL_ARCHIVES[@]}"; do
        if [ -f "$archive" ]; then
            NG_GL4ES_ARCHIVES+=("$archive")
        fi
    done

    BACKEND_ARCHIVES=("${NG_GL4ES_ARCHIVES[@]}")
else
    # ---------------------------------------------------------------------------
    # MobileGL (GL 3.3 core -> WebGPU) + SimpleFPEWrapper (fixed-function emulation).
    # ---------------------------------------------------------------------------
    require_cmd em++
    MOBILEGL_NM="$(find_first_cmd llvm-nm llvm-nm-20 llvm-nm-19 llvm-nm-18 llvm-nm-17 emnm nm || true)"
    if [ -z "$MOBILEGL_NM" ]; then
        echo "ERROR: unable to find llvm-nm (or compatible nm tool) for SimpleFPEWrapper symbol rename" >&2
        exit 1
    fi

    # Skip git-LFS smudge: MobileGL's only LFS objects are trace-replay fixture PNGs (gated
    # behind MOBILEGL_BUILD_TRACE_REPLAY, off here) and the repo's LFS budget may be exhausted,
    # which otherwise fails the checkout. The build needs no LFS content.
    if [ ! -d "$MOBILEGL_SRC_DIR/.git" ]; then
        log "Cloning MobileGL @ $MOBILEGL_REF (LFS smudge disabled)"
        GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 --branch "$MOBILEGL_REF" \
            --recurse-submodules --shallow-submodules "$MOBILEGL_REPO" "$MOBILEGL_SRC_DIR"
    else
        log "MobileGL source already present, skipping clone."
    fi
    log "Updating MobileGL submodules"
    GIT_LFS_SKIP_SMUDGE=1 git -C "$MOBILEGL_SRC_DIR" submodule update --init --recursive

    # glslang resolves its SPIRV-Tools/SPIRV-Headers via update_glslang_sources.py (a build-time
    # fetch keyed on known_good.json), NOT git submodules, so a fresh checkout lacks them and
    # MobileGL's configure fails ("ENABLE_OPT set but SPIR-V tools not found"). Populate them.
    log "Populating glslang SPIR-V Tools (update_glslang_sources.py)"
    ( cd "$MOBILEGL_SRC_DIR/3rdparty/glslang" && python3 update_glslang_sources.py )

    SFPEW_SRC_DIR="$MOBILEGL_SRC_DIR/SimpleFPEWrapper"
    if [ ! -d "$SFPEW_SRC_DIR/SimpleFPEWrapper" ]; then
        echo "ERROR: SimpleFPEWrapper submodule missing at $SFPEW_SRC_DIR (submodule update failed?)" >&2
        exit 1
    fi

    # -pthread must be consistent across MobileGL + SFPEW + tint + all deps for the mt archive.
    MGL_PTHREAD=""
    if [ "$VARIANT" = "mt" ]; then
        MGL_PTHREAD="-pthread"
    fi

    # Tint (SPIR-V -> WGSL). Built per-variant (mt needs a -pthread tint). Cached under the
    # workspace so repeat builds skip the expensive Dawn/tint compile.
    TINT_DIR="$MOBILEGL_TINT_DIR"
    if [ -z "$TINT_DIR" ]; then
        TINT_DIR="$WORKSPACE/tint-out-$VARIANT"
    fi
    if [ ! -f "$TINT_DIR/libtint.a" ]; then
        log "Building tint into $TINT_DIR (variant=$VARIANT); this is slow the first time"
        CFLAGS="$MGL_PTHREAD" CXXFLAGS="$MGL_PTHREAD" OUTPUT_DIR="$TINT_DIR" \
            bash "$MOBILEGL_SRC_DIR/tools/build-tint.sh"
    else
        log "Reusing prebuilt tint at $TINT_DIR"
    fi

    log "Configuring MobileGL ($VARIANT)"
    CFLAGS="$MGL_PTHREAD" CXXFLAGS="$MGL_PTHREAD" emcmake cmake -S "$MOBILEGL_SRC_DIR" -B "$MOBILEGL_BUILD_DIR" \
        -DCMAKE_BUILD_TYPE=Release -DMOBILEGL_FORCE_RELEASE_OPT=ON \
        -DMOBILEGL_EMSCRIPTEN_GLFW=ON -DMOBILEGL_EMSCRIPTEN_GLFW_FPE=ON \
        -DMOBILEGL_TINT_DIR="$TINT_DIR" \
        -DMOBILEGL_BUILD_TEST=OFF -DMOBILEGL_BUILD_BENCHMARK=OFF \
        "${CMAKE_GENERATOR[@]}"

    log "Building libMobileGL.a"
    cmake --build "$MOBILEGL_BUILD_DIR" --target MobileGL -j"$(nproc)"

    # --- SimpleFPEWrapper: two-pass build renaming its exported gl*/egl* to sfpew_* so they
    # don't collide with MobileGL's own gl*/egl* when the archives are combined. (llvm-objcopy
    # can't rename wasm symbols, so use a compile-time prefix header, like the old MobileGlues
    # path; force-included uniformly so the funcs-table members rename consistently too.)
    SFPEW_BUILD1="$TMP_DIR/sfpew-build1"
    SFPEW_BUILD2="$TMP_DIR/sfpew-build2"
    SFPEW_PREFIX_HEADER="$TMP_DIR/sfpew_gl_prefix.h"

    log "Building SimpleFPEWrapper (pass 1: discover exported symbols)"
    CFLAGS="$MGL_PTHREAD" CXXFLAGS="$MGL_PTHREAD" emcmake cmake -S "$SFPEW_SRC_DIR" -B "$SFPEW_BUILD1" \
        -DCMAKE_BUILD_TYPE=Release "${CMAKE_GENERATOR[@]}"
    cmake --build "$SFPEW_BUILD1" --target SimpleFPEWrapper -j"$(nproc)"

    log "Generating SimpleFPEWrapper gl*/egl* -> sfpew_* prefix header"
    {
        echo "// Auto-generated by build-glfw.sh: rename SimpleFPEWrapper's exported gl*/egl*"
        echo "// symbols to sfpew_* so they don't collide with MobileGL's own gl*/egl*."
        echo "#ifndef SFPEW_GL_PREFIX_OVERRIDES_H"
        echo "#define SFPEW_GL_PREFIX_OVERRIDES_H"
        "$MOBILEGL_NM" --defined-only --extern-only "$SFPEW_BUILD1/libSimpleFPEWrapper.a" 2>/dev/null \
            | awk '$2 ~ /^[TW]$/ {print $3}' | grep -E "^(gl|egl)[A-Za-z]" | sort -u \
            | awk '{print "#define "$1" sfpew_"$1}'
        echo "#endif"
    } > "$SFPEW_PREFIX_HEADER"
    RENAME_COUNT="$(grep -c '^#define' "$SFPEW_PREFIX_HEADER" || true)"
    if [ "${RENAME_COUNT:-0}" -lt 1 ]; then
        echo "ERROR: SimpleFPEWrapper symbol discovery found no gl*/egl* symbols to rename" >&2
        exit 1
    fi
    log "SimpleFPEWrapper: renaming $RENAME_COUNT gl*/egl* symbols to sfpew_*"

    log "Building SimpleFPEWrapper (pass 2: renamed)"
    rm -rf "$SFPEW_BUILD2"
    CFLAGS="$MGL_PTHREAD -include $SFPEW_PREFIX_HEADER" CXXFLAGS="$MGL_PTHREAD -include $SFPEW_PREFIX_HEADER" \
        emcmake cmake -S "$SFPEW_SRC_DIR" -B "$SFPEW_BUILD2" -DCMAKE_BUILD_TYPE=Release "${CMAKE_GENERATOR[@]}"
    cmake --build "$SFPEW_BUILD2" --target SimpleFPEWrapper -j"$(nproc)"

    SFPEW_ARCHIVE="$SFPEW_BUILD2/libSimpleFPEWrapper.a"

    # Whole-archived: their symbols are reached only via proc-address at runtime, so they must
    # not be stripped. libMobileGL.a pulls its own tint/glslang/etc. references from the support
    # libs below.
    BACKEND_ARCHIVES=(
        "$MOBILEGL_BUILD_DIR/libMobileGL.a"
        "$SFPEW_ARCHIVE"
    )
    # Support libs (referenced internally by MobileGL) — pulled as needed, not whole-archived,
    # so tint's bundled SPIRV-Tools and glslang's copy (byte-identical, pinned by build-tint.sh)
    # resolve to one definition instead of colliding.
    BACKEND_SUPPORT_ARCHIVES=(
        "$TINT_DIR/libtint.a"
        "$MOBILEGL_BUILD_DIR/3rdparty/glslang/glslang/libglslang.a"
        "$MOBILEGL_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-c.a"
        "$MOBILEGL_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-core.a"
        "$MOBILEGL_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-glsl.a"
        "$MOBILEGL_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-reflect.a"
        "$MOBILEGL_BUILD_DIR/3rdparty/glslang/External/spirv-tools/source/libSPIRV-Tools.a"
        "$MOBILEGL_BUILD_DIR/3rdparty/glslang/External/spirv-tools/source/opt/libSPIRV-Tools-opt.a"
        "$MOBILEGL_BUILD_DIR/3rdparty/SPIRV-Reflect/libspirv-reflect-static.a"
        "$MOBILEGL_BUILD_DIR/xxhash_build/libxxhash.a"
    )
    for archive in "${BACKEND_ARCHIVES[@]}" "${BACKEND_SUPPORT_ARCHIVES[@]}"; do
        if [ ! -f "$archive" ]; then
            echo "ERROR: expected MobileGL archive not found: $archive" >&2
            exit 1
        fi
    done

    # JS libraries the final app link must include (emdawnwebgpu bindings + MobileGL's JSPI shim).
    # emdawnwebgpu is fetched into the MobileGL build dir at configure time.
    EMDAWN_SRC="$MOBILEGL_BUILD_DIR/_deps/emdawnwebgpu-src/webgpu/src"
    MOBILEGL_JS_LIBS=(
        "$EMDAWN_SRC/library_webgpu_enum_tables.js"
        "$EMDAWN_SRC/library_webgpu_generated_struct_info.js"
        "$EMDAWN_SRC/library_webgpu_generated_sig_info.js"
        "$EMDAWN_SRC/library_webgpu.js"
        "$MOBILEGL_SRC_DIR/MobileGL/MG_Backend/DirectWebGPU/lib_mobilegl_webgpu.js"
    )
fi

COMBINED_OBJ="$TMP_DIR/glfw-${GL_BACKEND}-$VARIANT.o"
log "Combining glfw + $GL_BACKEND into single archive"
if [ "${#PTHREAD_FLAGS[@]}" -gt 0 ]; then
    emcc "${PTHREAD_FLAGS[@]}" -r -o "$COMBINED_OBJ" \
        -Wl,--whole-archive \
        "$GLFW_ARCHIVE" \
        "${BACKEND_ARCHIVES[@]}" \
        -Wl,--no-whole-archive \
        "${BACKEND_SUPPORT_ARCHIVES[@]}"
else
    emcc -r -o "$COMBINED_OBJ" \
        -Wl,--whole-archive \
        "$GLFW_ARCHIVE" \
        "${BACKEND_ARCHIVES[@]}" \
        -Wl,--no-whole-archive \
        "${BACKEND_SUPPORT_ARCHIVES[@]}"
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/libglfw3.a"
emar rcs "$OUTPUT_DIR/libglfw3.a" "$COMBINED_OBJ"
cp "$GLFW_SRC_DIR/src/js/lib_emscripten_glfw3.js" "$OUTPUT_DIR/lib_emscripten_glfw3.js"

# The MobileGL/WebGPU backend needs extra JS libraries at the final app link: the emdawnwebgpu
# bindings and MobileGL's JSPI shim. Ship them next to the archive so the client can --js-library them.
if [ "$GL_BACKEND" = "mobilegl" ]; then
    for js in "${MOBILEGL_JS_LIBS[@]}"; do
        if [ ! -f "$js" ]; then
            echo "ERROR: expected MobileGL JS library not found: $js" >&2
            exit 1
        fi
        cp "$js" "$OUTPUT_DIR/"
    done
    log "Copied $(( ${#MOBILEGL_JS_LIBS[@]} )) MobileGL/emdawnwebgpu JS libraries to $OUTPUT_DIR"
fi

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
