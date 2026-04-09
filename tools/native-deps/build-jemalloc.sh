#!/usr/bin/env bash
# build-jemalloc.sh - Builds a static jemalloc archive for Emscripten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

JEMALLOC_REPO="https://github.com/jemalloc/jemalloc.git"
# jemalloc 5.3.0 is the latest release and builds with emsdk 3.1.56.
JEMALLOC_REF="${JEMALLOC_REF:-5.3.0}"
JEMALLOC_PATCH="${JEMALLOC_PATCH:-$SCRIPT_DIR/jemalloc.patch}"
JEMALLOC_LWJGL_COMPAT_SRC="${JEMALLOC_LWJGL_COMPAT_SRC:-$SCRIPT_DIR/jemalloc-lwjgl-compat.c}"
EXPECTED_EMSDK_VERSION="${EXPECTED_EMSDK_VERSION:-3.1.56}"

OUTPUT_DIR="${OUTPUT_DIR:-}"
VARIANT="${VARIANT:-mt}"
KEEP_TMP="false"
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage: build-jemalloc.sh [options]

Options:
  --variant=<mt|st>            Build variant (default: mt).
  --output-dir=<path>          Output directory (default: tools/native-deps/out/<variant>).
  --jemalloc-ref=<ref>         jemalloc git ref/tag (default: 5.3.0).
  --jemalloc-patch=<path>      Optional patch to apply to jemalloc clone.
  --tmp-dir=<path>             Temporary build directory (default: mktemp).
  --keep-tmp                   Keep temporary build directory.
  -h, --help                   Show this help message.

Environment overrides:
  VARIANT
  OUTPUT_DIR
  JEMALLOC_REF
  JEMALLOC_PATCH
  EXPECTED_EMSDK_VERSION
EOF
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --jemalloc-ref=*) JEMALLOC_REF="${arg#*=}" ;;
        --jemalloc-patch=*) JEMALLOC_PATCH="${arg#*=}" ;;
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
    echo "[build-jemalloc/$VARIANT] $*"
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
require_cmd emcc
require_cmd emar
require_cmd emconfigure
require_cmd emmake
require_cmd autoconf
require_cmd make

EMCC_VERSION_LINE="$(emcc --version | sed -n '1p')"
if [ -n "$EXPECTED_EMSDK_VERSION" ] && ! printf '%s' "$EMCC_VERSION_LINE" | grep -q " $EXPECTED_EMSDK_VERSION "; then
    echo "ERROR: emcc version mismatch. Expected emsdk $EXPECTED_EMSDK_VERSION, got: $EMCC_VERSION_LINE" >&2
    exit 1
fi

case "$VARIANT" in
    mt)
        CONFIGURE_CFLAGS="-pthread"
        CONFIGURE_CXXFLAGS="-pthread"
        CONFIGURE_LDFLAGS="-pthread"
        ;;
    st)
        CONFIGURE_CFLAGS=""
        CONFIGURE_CXXFLAGS=""
        CONFIGURE_LDFLAGS=""
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
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ikvm-jemalloc-build-${VARIANT}.XXXXXX")"
fi

cleanup() {
    if [ "$KEEP_TMP" = "true" ]; then
        log "Keeping temp directory: $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

JEMALLOC_SRC_DIR="$WORKSPACE/jemalloc"
JEMALLOC_BUILD_DIR="$TMP_DIR/jemalloc-build"

if [ ! -d "$JEMALLOC_SRC_DIR/.git" ]; then
    log "Cloning jemalloc @ $JEMALLOC_REF"
    git clone --depth 1 --branch "$JEMALLOC_REF" "$JEMALLOC_REPO" "$JEMALLOC_SRC_DIR"
else
    log "jemalloc source already present, skipping clone."
fi
apply_patch_once "$JEMALLOC_SRC_DIR" "$JEMALLOC_PATCH" "$(basename "$JEMALLOC_PATCH")"

log "Generating configure script"
(cd "$JEMALLOC_SRC_DIR" && ./autogen.sh >/dev/null)

rm -rf "$JEMALLOC_BUILD_DIR"
mkdir -p "$JEMALLOC_BUILD_DIR"

JEMALLOC_CONFIGURE_ARGS=(
    --host=wasm32-unknown-emscripten
    --disable-shared
    --enable-static
    --disable-cxx
    --with-jemalloc-prefix=je_
    --without-export
    --with-lg-quantum=4
)

log "Configuring jemalloc"
if [ "$VARIANT" = "mt" ]; then
    (
        cd "$JEMALLOC_BUILD_DIR"
        CFLAGS="$CONFIGURE_CFLAGS" CXXFLAGS="$CONFIGURE_CXXFLAGS" LDFLAGS="$CONFIGURE_LDFLAGS" \
            emconfigure "$JEMALLOC_SRC_DIR/configure" "${JEMALLOC_CONFIGURE_ARGS[@]}"
    )
else
    (
        cd "$JEMALLOC_BUILD_DIR"
        emconfigure "$JEMALLOC_SRC_DIR/configure" "${JEMALLOC_CONFIGURE_ARGS[@]}"
    )
fi

log "Building jemalloc"
(cd "$JEMALLOC_BUILD_DIR" && emmake make -j"$(nproc)")

JEMALLOC_ARCHIVE="$JEMALLOC_BUILD_DIR/lib/libjemalloc.a"
if [ ! -f "$JEMALLOC_ARCHIVE" ]; then
    echo "ERROR: expected jemalloc archive not found: $JEMALLOC_ARCHIVE" >&2
    exit 1
fi

if [ -f "$JEMALLOC_LWJGL_COMPAT_SRC" ]; then
    log "Adding LWJGL jemalloc compatibility symbols"
    COMPAT_OBJ="$JEMALLOC_BUILD_DIR/lwjgl_jemalloc_compat.o"
    if [ "$VARIANT" = "mt" ]; then
        emcc -O2 -pthread -c "$JEMALLOC_LWJGL_COMPAT_SRC" -o "$COMPAT_OBJ"
    else
        emcc -O2 -c "$JEMALLOC_LWJGL_COMPAT_SRC" -o "$COMPAT_OBJ"
    fi
    emar rcs "$JEMALLOC_ARCHIVE" "$COMPAT_OBJ"
fi

mkdir -p "$OUTPUT_DIR"
cp "$JEMALLOC_ARCHIVE" "$OUTPUT_DIR/libjemalloc.a"

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
