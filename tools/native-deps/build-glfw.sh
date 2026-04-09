#!/usr/bin/env bash
# build-glfw.sh - Builds emscripten-glfw artifacts for WASM.
# Produces one libglfw3.a archive with MobileGlues desktop GL symbols included.

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

OUTPUT_DIR="${OUTPUT_DIR:-}"
VARIANT="${VARIANT:-mt}"
KEEP_TMP="false"
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage: build-glfw.sh [options]

Options:
  --variant=<mt|st>            Build variant (default: mt).
  --output-dir=<path>          Output directory (default: tools/native-deps/out/<variant>).
  --glfw-ref=<ref>             emscripten-glfw git ref (default: v3.4.0.20250607).
  --mobileglues-ref=<ref>      MobileGlues git ref (default: main).
  --tmp-dir=<path>             Temporary build directory (default: mktemp).
  --keep-tmp                   Keep temporary build directory.
  -h, --help                   Show this help message.

Environment overrides:
  VARIANT
  OUTPUT_DIR
  EMSCRIPTEN_GLFW_REF
  MOBILEGLUES_REF
EOF
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --glfw-ref=*) EMSCRIPTEN_GLFW_REF="${arg#*=}" ;;
        --mobileglues-ref=*) MOBILEGLUES_REF="${arg#*=}" ;;
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
require_cmd emar

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

GLFW_SRC_DIR="$WORKSPACE/emscripten-glfw"
GLFW_BUILD_DIR="$TMP_DIR/glfw-build"

if [ ! -d "$GLFW_SRC_DIR/.git" ]; then
    log "Cloning emscripten-glfw @ $EMSCRIPTEN_GLFW_REF"
    git clone --depth 1 --branch "$EMSCRIPTEN_GLFW_REF" "$EMSCRIPTEN_GLFW_REPO" "$GLFW_SRC_DIR"
else
    log "emscripten-glfw source already present, skipping clone."
fi
apply_patch_once "$GLFW_SRC_DIR" "$EMSCRIPTEN_GLFW_PATCH" "emscripten-glfw.patch"

log "Configuring emscripten-glfw"
emcmake cmake -S "$GLFW_SRC_DIR" -B "$GLFW_BUILD_DIR" -DCMAKE_BUILD_TYPE=Release "${CMAKE_GENERATOR[@]}"

log "Building $GLFW_TARGET"
cmake --build "$GLFW_BUILD_DIR" --target "$GLFW_TARGET" -j"$(nproc)"

GLFW_ARCHIVE="$GLFW_BUILD_DIR/$GLFW_ARCHIVE_NAME"
if [ ! -f "$GLFW_ARCHIVE" ]; then
    echo "ERROR: expected glfw archive not found: $GLFW_ARCHIVE" >&2
    exit 1
fi

MOBILEGLUES_SRC_DIR="$WORKSPACE/MobileGlues"
MOBILEGLUES_CPP_DIR="$MOBILEGLUES_SRC_DIR/MobileGlues-cpp"
MOBILEGLUES_BUILD_DIR="$TMP_DIR/mobileglues-build"

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

COMBINED_OBJ="$TMP_DIR/glfw-mobileglues-$VARIANT.o"
log "Combining glfw + MobileGlues into single archive"
if [ "${#PTHREAD_FLAGS[@]}" -gt 0 ]; then
    emcc "${PTHREAD_FLAGS[@]}" -r -o "$COMBINED_OBJ" \
        -Wl,--whole-archive \
        "$GLFW_ARCHIVE" \
        "${MOBILEGLUES_ARCHIVES[@]}" \
        -Wl,--no-whole-archive
else
    emcc -r -o "$COMBINED_OBJ" \
        -Wl,--whole-archive \
        "$GLFW_ARCHIVE" \
        "${MOBILEGLUES_ARCHIVES[@]}" \
        -Wl,--no-whole-archive
fi

mkdir -p "$OUTPUT_DIR"
emar rcs "$OUTPUT_DIR/libglfw3.a" "$COMBINED_OBJ"
cp "$GLFW_SRC_DIR/src/js/lib_emscripten_glfw3.js" "$OUTPUT_DIR/lib_emscripten_glfw3.js"

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
