#!/usr/bin/env bash
# build-glfw.sh - Builds emscripten-glfw artifacts for WASM.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

EMSCRIPTEN_GLFW_REPO="https://github.com/pongasoft/emscripten-glfw.git"
# Latest emscripten-glfw release verified to build with emsdk 3.1.56.
EMSCRIPTEN_GLFW_REF="${EMSCRIPTEN_GLFW_REF:-v3.4.0.20250607}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/out/java-native-deps}"
KEEP_TMP="false"
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage: build-glfw.sh [options]

Options:
  --output-dir=<path>   Output directory for final artifacts.
  --glfw-ref=<ref>      emscripten-glfw git ref (default: v3.4.0.20250607).
  --tmp-dir=<path>      Temporary build directory (default: mktemp).
  --keep-tmp            Keep temporary build directory.
  -h, --help            Show this help message.

Environment overrides:
  EMSCRIPTEN_GLFW_REF
  OUTPUT_DIR
EOF
}

for arg in "$@"; do
    case "$arg" in
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --glfw-ref=*) EMSCRIPTEN_GLFW_REF="${arg#*=}" ;;
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
    echo "[build-glfw] $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command '$1' not found" >&2
        exit 1
    fi
}

require_cmd git
require_cmd emcmake
require_cmd cmake

if command -v ninja >/dev/null 2>&1; then
    CMAKE_GENERATOR="-GNinja"
else
    CMAKE_GENERATOR=""
fi

if [ -n "$TMP_DIR" ]; then
    mkdir -p "$TMP_DIR"
else
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ikvm-glfw-build.XXXXXX")"
fi

cleanup() {
    if [ "$KEEP_TMP" = "true" ]; then
        log "Keeping temp directory: $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

SRC_DIR="$TMP_DIR/emscripten-glfw"
BUILD_DIR="$TMP_DIR/build"

log "Cloning emscripten-glfw @ $EMSCRIPTEN_GLFW_REF"
git clone --depth 1 --branch "$EMSCRIPTEN_GLFW_REF" "$EMSCRIPTEN_GLFW_REPO" "$SRC_DIR"

log "Configuring emscripten-glfw build"
if [ -n "$CMAKE_GENERATOR" ]; then
    emcmake cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release $CMAKE_GENERATOR
else
    emcmake cmake -S "$SRC_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
fi

log "Building libglfw3.a"
cmake --build "$BUILD_DIR" --target glfw3 -j"$(nproc)"

mkdir -p "$OUTPUT_DIR"
cp "$BUILD_DIR/libglfw3.a" "$OUTPUT_DIR/libglfw3.a"
cp "$SRC_DIR/src/js/lib_emscripten_glfw3.js" "$OUTPUT_DIR/lib_emscripten_glfw3.js"

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
