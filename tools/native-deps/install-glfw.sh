#!/usr/bin/env bash
# install-glfw.sh - Stage locally-built emscripten-glfw artifacts into a consumer project's
# statics/ directory, so a local `build-glfw.sh` output is drop-in interchangeable with the
# release assets the consumer Makefile downloads.
#
# It copies the same files, under the same (unsuffixed) names, that the release Makefile ends up
# with after fetching libglfw3-<variant>.a / lib_emscripten_glfw3-<variant>.js and unzipping
# mobilegl-webgpu-js-<variant>.zip:
#
#   out/<variant>/libglfw3.a                        -> statics/libglfw3.a
#   out/<variant>/lib_emscripten_glfw3.js           -> statics/lib_emscripten_glfw3.js
#   out/<variant>/library_webgpu_enum_tables.js     -> statics/...
#   out/<variant>/library_webgpu_generated_struct_info.js
#   out/<variant>/library_webgpu_generated_sig_info.js
#   out/<variant>/library_webgpu.js
#   out/<variant>/lib_mobilegl_webgpu.js
#
# Usage: install-glfw.sh [--variant=mt|st] [--dest=<consumer-repo-root>]
#   --variant   which out/ variant to copy (default: mt)
#   --dest      consumer project root that contains statics/ (default: ../../../ikvmcraft)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

VARIANT="mt"
DEST=""

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --dest=*) DEST="${arg#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$arg'" >&2; usage; exit 1 ;;
    esac
done

case "$VARIANT" in
    mt|st) ;;
    *) echo "ERROR: --variant must be mt or st (got '$VARIANT')" >&2; exit 1 ;;
esac

if [ -z "$DEST" ]; then
    DEST="$SCRIPT_DIR/../../../ikvmcraft"
fi

SRC="$SCRIPT_DIR/out/$VARIANT"
STATICS="$DEST/statics"

if [ ! -d "$SRC" ]; then
    echo "ERROR: source dir not found: $SRC" >&2
    echo "       run 'build-glfw.sh --variant=$VARIANT' first." >&2
    exit 1
fi
if [ ! -d "$STATICS" ]; then
    echo "ERROR: consumer statics dir not found: $STATICS" >&2
    echo "       check --dest, or run 'make statics' in the consumer first." >&2
    exit 1
fi

# The combined libglfw3.a (both GL backends) + the JS libraries the final app link needs.
# Keep in sync with build-glfw.sh's outputs and the consumer's IkvmWasm.csproj --js-library list.
FILES=(
    libglfw3.a
    lib_emscripten_glfw3.js
    library_webgpu_enum_tables.js
    library_webgpu_generated_struct_info.js
    library_webgpu_generated_sig_info.js
    library_webgpu.js
    lib_mobilegl_webgpu.js
)

for f in "${FILES[@]}"; do
    if [ ! -f "$SRC/$f" ]; then
        echo "ERROR: expected artifact missing: $SRC/$f" >&2
        echo "       re-run 'build-glfw.sh --variant=$VARIANT'." >&2
        exit 1
    fi
done

echo "Staging glfw artifacts ($VARIANT): $SRC -> $STATICS"
for f in "${FILES[@]}"; do
    cp -v "$SRC/$f" "$STATICS/$f"
done

echo
echo "Done. Because libglfw3.a's exported symbols changed, regenerate statics.c"
echo "(gen-static-libs.py) against the new archive before linking the consumer."
