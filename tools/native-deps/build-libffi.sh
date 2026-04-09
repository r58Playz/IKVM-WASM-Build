#!/usr/bin/env bash
# build-libffi.sh - Builds a static libffi archive for Emscripten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

LIBFFI_REPO="https://github.com/libffi/libffi"
# libffi 3.5.2 is the latest release and builds with emsdk 3.1.56.
LIBFFI_REF="${LIBFFI_REF:-v3.5.2}"
LIBFFI_PATCH="${LIBFFI_PATCH:-$SCRIPT_DIR/libffi.patch}"
EXPECTED_EMSDK_VERSION="${EXPECTED_EMSDK_VERSION:-3.1.56}"

OUTPUT_DIR="${OUTPUT_DIR:-}"
VARIANT="${VARIANT:-mt}"
KEEP_TMP="false"
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage: build-libffi.sh [options]

Options:
  --variant=<mt|st>            Build variant (default: mt).
  --output-dir=<path>          Output directory (default: tools/native-deps/out/<variant>).
  --libffi-ref=<ref>           libffi git ref/tag (default: v3.5.2).
  --libffi-patch=<path>        Optional patch to apply to libffi clone.
  --tmp-dir=<path>             Temporary build directory (default: mktemp).
  --keep-tmp                   Keep temporary build directory.
  -h, --help                   Show this help message.

Environment overrides:
  VARIANT
  OUTPUT_DIR
  LIBFFI_REF
  LIBFFI_PATCH
  EXPECTED_EMSDK_VERSION
EOF
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --libffi-ref=*) LIBFFI_REF="${arg#*=}" ;;
        --libffi-patch=*) LIBFFI_PATCH="${arg#*=}" ;;
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
    echo "[build-libffi/$VARIANT] $*"
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
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ikvm-libffi-build-${VARIANT}.XXXXXX")"
fi

cleanup() {
    if [ "$KEEP_TMP" = "true" ]; then
        log "Keeping temp directory: $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

LIBFFI_SRC_DIR="$WORKSPACE/libffi"
LIBFFI_BUILD_DIR="$TMP_DIR/libffi-build"

if [ ! -d "$LIBFFI_SRC_DIR/.git" ]; then
    log "Cloning libffi @ $LIBFFI_REF"
    git clone --depth 1 --branch "$LIBFFI_REF" "$LIBFFI_REPO" "$LIBFFI_SRC_DIR"
else
    log "libffi source already present, skipping clone."
fi
apply_patch_once "$LIBFFI_SRC_DIR" "$LIBFFI_PATCH" "$(basename "$LIBFFI_PATCH")"

if [ ! -x "$LIBFFI_SRC_DIR/configure" ]; then
    require_cmd autoconf
    log "Generating configure script"
    (cd "$LIBFFI_SRC_DIR" && ./autogen.sh >/dev/null)
fi

rm -rf "$LIBFFI_BUILD_DIR"
mkdir -p "$LIBFFI_BUILD_DIR"

LIBFFI_CONFIGURE_ARGS=(
    --host=wasm32-unknown-emscripten
    --disable-shared
    --enable-static
)

log "Configuring libffi"
if [ "$VARIANT" = "mt" ]; then
    (
        cd "$LIBFFI_BUILD_DIR"
        CFLAGS="$CONFIGURE_CFLAGS" CXXFLAGS="$CONFIGURE_CXXFLAGS" LDFLAGS="$CONFIGURE_LDFLAGS" \
            emconfigure "$LIBFFI_SRC_DIR/configure" "${LIBFFI_CONFIGURE_ARGS[@]}"
    )
else
    (
        cd "$LIBFFI_BUILD_DIR"
        emconfigure "$LIBFFI_SRC_DIR/configure" "${LIBFFI_CONFIGURE_ARGS[@]}"
    )
fi

log "Building libffi"
(cd "$LIBFFI_BUILD_DIR" && emmake make -j"$(nproc)")

LIBFFI_ARCHIVE=""
LIBFFI_ARCHIVE_CANDIDATES=(
    "$LIBFFI_BUILD_DIR/.libs/libffi.a"
    "$LIBFFI_BUILD_DIR/libffi.a"
    "$LIBFFI_BUILD_DIR/libffi/.libs/libffi.a"
)

for archive in "${LIBFFI_ARCHIVE_CANDIDATES[@]}"; do
    if [ -f "$archive" ]; then
        LIBFFI_ARCHIVE="$archive"
        break
    fi
done

if [ -z "$LIBFFI_ARCHIVE" ]; then
    echo "ERROR: expected libffi archive not found under $LIBFFI_BUILD_DIR" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$LIBFFI_ARCHIVE" "$OUTPUT_DIR/libffi.a"

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
