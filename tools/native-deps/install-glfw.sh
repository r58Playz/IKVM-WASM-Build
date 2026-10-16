#!/usr/bin/env bash
# install-glfw.sh - Stage locally-built emscripten-glfw + mesa-wink artifacts into a consumer project's statics/
# directory:
#
#   out/<variant>/libglfw3.a                -> statics/libglfw3.a
#   out/<variant>/libwink.a                 -> statics/libwink.a
#   out/<variant>/libwink_webgpu.a          -> statics/libwink_webgpu.a
#   out/<variant>/libwink_tint.a            -> statics/libwink_tint.a
#   out/<variant>/lib_emscripten_glfw3.js   -> statics/lib_emscripten_glfw3.js
#   out/<variant>/wink-js/NN-*.js           -> statics/wink-js/ (numbered: the link passes them in that order)
#
# The MobileGL-era files (library_webgpu*.js at the top of statics/, lib_mobilegl_webgpu.js) are removed: wink ships
# its own emdawnwebgpu JS, patched for emsdk 3.1.56, and the two must not both be linked.
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

FILES=(
    libglfw3.a
    libwink.a
    libwink_webgpu.a
    libwink_tint.a
    lib_emscripten_glfw3.js
)

for f in "${FILES[@]}"; do
    if [ ! -f "$SRC/$f" ]; then
        echo "ERROR: expected artifact missing: $SRC/$f" >&2
        echo "       re-run 'build-glfw.sh --variant=$VARIANT'." >&2
        exit 1
    fi
done
if ! ls "$SRC"/wink-js/*.js >/dev/null 2>&1; then
    echo "ERROR: no wink JS libraries in $SRC/wink-js" >&2
    exit 1
fi

echo "Staging glfw + wink artifacts ($VARIANT): $SRC -> $STATICS"
for f in "${FILES[@]}"; do
    cp -v "$SRC/$f" "$STATICS/$f"
done
rm -rf "$STATICS/wink-js"
cp -rv "$SRC/wink-js" "$STATICS/wink-js"
rm -fv "$STATICS"/library_webgpu_enum_tables.js "$STATICS"/library_webgpu_generated_struct_info.js \
       "$STATICS"/library_webgpu_generated_sig_info.js "$STATICS"/library_webgpu.js "$STATICS"/lib_mobilegl_webgpu.js

echo
echo "Done. Because libglfw3.a's exported symbols changed, regenerate statics.c"
echo "(gen-static-libs.py) against the new archive before linking the consumer."
