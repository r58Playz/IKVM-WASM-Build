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

MOBILEGLUES_REPO="${MOBILEGLUES_REPO:-https://github.com/MobileGL-Dev/MobileGlues.git}"
MOBILEGLUES_REF="${MOBILEGLUES_REF:-main}"
MOBILEGLUES_PATCH="${MOBILEGLUES_PATCH:-$SCRIPT_DIR/mobileglues.patch}"
MOBILEGLUES_SYMBOL_GEN="${MOBILEGLUES_SYMBOL_GEN:-$SCRIPT_DIR/gen-mobileglues-gl-symbols.py}"

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
  --gl-backend=<ng-gl4es|mobileglues>
                               GL translation backend (default: ng-gl4es).
  --output-dir=<path>          Output directory (default: tools/native-deps/out/<variant>).
  --glfw-ref=<ref>             emscripten-glfw git ref (default: v3.4.0.20250607).
  --mobileglues-ref=<ref>      MobileGlues git ref (default: main).
  --mobileglues-symbol-gen=<path>
                               MobileGlues GL symbol generator script.
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
  MOBILEGLUES_REF
  MOBILEGLUES_SYMBOL_GEN
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
        --mobileglues-ref=*) MOBILEGLUES_REF="${arg#*=}" ;;
        --mobileglues-symbol-gen=*) MOBILEGLUES_SYMBOL_GEN="${arg#*=}" ;;
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
    mobileglues|ng-gl4es)
        ;;
    *)
        echo "ERROR: --gl-backend must be ng-gl4es or mobileglues (got '$GL_BACKEND')" >&2
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
# the krypton backend so the wasm references krypton_* (not mobileglues_*).
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

MOBILEGLUES_SRC_DIR="$WORKSPACE/MobileGlues"
MOBILEGLUES_CPP_DIR="$MOBILEGLUES_SRC_DIR/MobileGlues-cpp"
MOBILEGLUES_BUILD_DIR="$TMP_DIR/mobileglues-build"
MOBILEGLUES_ARCHIVES=()

BACKEND_ARCHIVES=()

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
    require_cmd em++
    MOBILEGLUES_NM="$(find_first_cmd llvm-nm llvm-nm-20 llvm-nm-19 llvm-nm-18 llvm-nm-17 emnm nm || true)"
    if [ -z "$MOBILEGLUES_NM" ]; then
        echo "ERROR: unable to find llvm-nm (or compatible nm tool) for MobileGlues symbol generation" >&2
        exit 1
    fi

    if [ ! -d "$MOBILEGLUES_SRC_DIR/.git" ]; then
        log "Cloning MobileGlues @ $MOBILEGLUES_REF"
        git clone --depth 1 --branch "$MOBILEGLUES_REF" --recurse-submodules --shallow-submodules "$MOBILEGLUES_REPO" "$MOBILEGLUES_SRC_DIR"
    else
        log "MobileGlues source already present, skipping clone."
    fi
    log "Updating MobileGlues submodules"
    git -C "$MOBILEGLUES_SRC_DIR" submodule update --init --recursive
    apply_patch_once "$MOBILEGLUES_SRC_DIR" "$MOBILEGLUES_PATCH" "mobileglues.patch"

    log "Configuring MobileGlues"
    if [ "$VARIANT" = "mt" ]; then
        CFLAGS="-pthread" CXXFLAGS="-pthread" emcmake cmake -S "$MOBILEGLUES_CPP_DIR" -B "$MOBILEGLUES_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "${CMAKE_GENERATOR[@]}"
    else
        emcmake cmake -S "$MOBILEGLUES_CPP_DIR" -B "$MOBILEGLUES_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "${CMAKE_GENERATOR[@]}"
    fi

    log "Building MobileGlues"
    cmake --build "$MOBILEGLUES_BUILD_DIR" --target mobileglues -j"$(nproc)"

    MOBILEGLUES_ARCHIVES=(
        "$MOBILEGLUES_BUILD_DIR/libmobileglues.a"
        "$MOBILEGLUES_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-c.a"
        "$MOBILEGLUES_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-core.a"
        "$MOBILEGLUES_BUILD_DIR/3rdparty/SPIRV-Cross/libspirv-cross-glsl.a"
        "$MOBILEGLUES_BUILD_DIR/3rdparty/glslang/glslang/libglslang.a"
    )

    for archive in "${MOBILEGLUES_ARCHIVES[@]}"; do
        if [ ! -f "$archive" ]; then
            echo "ERROR: expected MobileGlues archive not found: $archive" >&2
            exit 1
        fi
    done

    MOBILEGLUES_PRIMARY_ARCHIVE="${MOBILEGLUES_ARCHIVES[0]}"
    if [ ! -f "$MOBILEGLUES_SYMBOL_GEN" ]; then
        echo "ERROR: MobileGlues symbol generator not found: $MOBILEGLUES_SYMBOL_GEN" >&2
        exit 1
    fi

    MOBILEGLUES_SYMBOLS_C="$TMP_DIR/mobileglues_gl_symbols.c"
    MOBILEGLUES_PREFIX_HEADER_DIR="$TMP_DIR/mobileglues-prefix"
    MOBILEGLUES_PREFIX_HEADER="$MOBILEGLUES_PREFIX_HEADER_DIR/gl_prefix_overrides.h"
    MOBILEGLUES_SYMBOLS_OBJ="$TMP_DIR/mobileglues_gl_symbols.o"

    mkdir -p "$MOBILEGLUES_PREFIX_HEADER_DIR"

    log "Generating MobileGlues symbol table"
    python3 "$MOBILEGLUES_SYMBOL_GEN" \
        --archive "$MOBILEGLUES_PRIMARY_ARCHIVE" \
        --output-c "$MOBILEGLUES_SYMBOLS_C" \
        --output-header "$MOBILEGLUES_PREFIX_HEADER" \
        --source-root "$MOBILEGLUES_CPP_DIR" \
        --nm "$MOBILEGLUES_NM"

    if [ ! -s "$MOBILEGLUES_PREFIX_HEADER" ]; then
        echo "ERROR: generated MobileGlues prefix header is empty: $MOBILEGLUES_PREFIX_HEADER" >&2
        exit 1
    fi

    log "Rebuilding MobileGlues with generated GL symbol prefixes"
    rm -rf "$MOBILEGLUES_BUILD_DIR"
    if [ "$VARIANT" = "mt" ]; then
        CFLAGS="-pthread -include $MOBILEGLUES_PREFIX_HEADER" CXXFLAGS="-pthread -include $MOBILEGLUES_PREFIX_HEADER" \
            emcmake cmake -S "$MOBILEGLUES_CPP_DIR" -B "$MOBILEGLUES_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "${CMAKE_GENERATOR[@]}"
    else
        CFLAGS="-include $MOBILEGLUES_PREFIX_HEADER" CXXFLAGS="-include $MOBILEGLUES_PREFIX_HEADER" \
            emcmake cmake -S "$MOBILEGLUES_CPP_DIR" -B "$MOBILEGLUES_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "${CMAKE_GENERATOR[@]}"
    fi

    cmake --build "$MOBILEGLUES_BUILD_DIR" --target mobileglues -j"$(nproc)"

    for archive in "${MOBILEGLUES_ARCHIVES[@]}"; do
        if [ ! -f "$archive" ]; then
            echo "ERROR: expected MobileGlues archive not found after prefixed rebuild: $archive" >&2
            exit 1
        fi
    done

    log "Compiling generated MobileGlues symbol table"
    if [ "${#PTHREAD_FLAGS[@]}" -gt 0 ]; then
        em++ "${PTHREAD_FLAGS[@]}" -x c++ -O2 -fPIC -I"$MOBILEGLUES_PREFIX_HEADER_DIR" -I"$MOBILEGLUES_CPP_DIR" -I"$MOBILEGLUES_CPP_DIR/include" \
            -include "$MOBILEGLUES_PREFIX_HEADER" -c "$MOBILEGLUES_SYMBOLS_C" -o "$MOBILEGLUES_SYMBOLS_OBJ"
    else
        em++ -x c++ -O2 -fPIC -I"$MOBILEGLUES_PREFIX_HEADER_DIR" -I"$MOBILEGLUES_CPP_DIR" -I"$MOBILEGLUES_CPP_DIR/include" \
            -include "$MOBILEGLUES_PREFIX_HEADER" -c "$MOBILEGLUES_SYMBOLS_C" -o "$MOBILEGLUES_SYMBOLS_OBJ"
    fi

    log "Injecting MobileGlues symbol table into archive"
    emar rcs "$MOBILEGLUES_PRIMARY_ARCHIVE" "$MOBILEGLUES_SYMBOLS_OBJ"
    BACKEND_ARCHIVES=("${MOBILEGLUES_ARCHIVES[@]}")
fi

COMBINED_OBJ="$TMP_DIR/glfw-${GL_BACKEND}-$VARIANT.o"
log "Combining glfw + $GL_BACKEND into single archive"
if [ "${#PTHREAD_FLAGS[@]}" -gt 0 ]; then
    emcc "${PTHREAD_FLAGS[@]}" -r -o "$COMBINED_OBJ" \
        -Wl,--whole-archive \
        "$GLFW_ARCHIVE" \
        "${BACKEND_ARCHIVES[@]}" \
        -Wl,--no-whole-archive
else
    emcc -r -o "$COMBINED_OBJ" \
        -Wl,--whole-archive \
        "$GLFW_ARCHIVE" \
        "${BACKEND_ARCHIVES[@]}" \
        -Wl,--no-whole-archive
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR/libglfw3.a"
emar rcs "$OUTPUT_DIR/libglfw3.a" "$COMBINED_OBJ"
cp "$GLFW_SRC_DIR/src/js/lib_emscripten_glfw3.js" "$OUTPUT_DIR/lib_emscripten_glfw3.js"

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
