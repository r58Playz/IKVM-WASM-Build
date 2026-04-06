#!/usr/bin/env bash
# build-lwjgl3.sh - Builds a LWJGL3 jar + static native archive for Emscripten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LWJGL_REPO="https://github.com/LWJGL/lwjgl3.git"
# 3.4.1 is the latest LWJGL release and compiles with emsdk 3.1.56.
LWJGL_REF="${LWJGL_REF:-3.4.1}"
EXPECTED_EMSDK_VERSION="${EXPECTED_EMSDK_VERSION:-3.1.56}"
ANT_VERSION="${ANT_VERSION:-1.10.15}"
ANT_BASE_URL="${ANT_BASE_URL:-https://archive.apache.org/dist/ant/binaries}"

OUTPUT_DIR="${OUTPUT_DIR:-}"
VARIANT="${VARIANT:-mt}"
KEEP_TMP="false"
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage: build-lwjgl3.sh [options]

Options:
  --variant=<mt|st>            Build variant (default: mt).
  --output-dir=<path>          Output directory (default: out/java-native-deps/<variant>).
  --lwjgl-ref=<ref>            LWJGL git ref/tag (default: 3.4.1).
  --tmp-dir=<path>             Temporary build directory (default: mktemp).
  --keep-tmp                   Keep temporary build directory.
  -h, --help                   Show this help message.

Environment overrides:
  VARIANT
  OUTPUT_DIR
  LWJGL_REF
  EXPECTED_EMSDK_VERSION
EOF
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --lwjgl-ref=*) LWJGL_REF="${arg#*=}" ;;
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
    echo "[build-lwjgl3/$VARIANT] $*"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: required command '$1' not found" >&2
        exit 1
    fi
}

setup_ant() {
    if [ -n "${ANT_HOME:-}" ] && [ -x "$ANT_HOME/bin/ant" ]; then
        printf '%s' "$ANT_HOME/bin/ant"
        return 0
    fi

    local ant_root="$TMP_DIR/apache-ant-$ANT_VERSION"
    local ant_archive="$TMP_DIR/apache-ant-$ANT_VERSION-bin.tar.gz"
    if [ ! -x "$ant_root/bin/ant" ]; then
        log "Downloading Apache Ant $ANT_VERSION" >&2
        curl -fsSL -o "$ant_archive" "$ANT_BASE_URL/apache-ant-$ANT_VERSION-bin.tar.gz"
        tar -xzf "$ant_archive" -C "$TMP_DIR"
    fi

    if [ ! -x "$ant_root/bin/ant" ]; then
        echo "ERROR: failed to initialize Apache Ant in $ant_root" >&2
        exit 1
    fi

    printf '%s' "$ant_root/bin/ant"
}

build_binding_args() {
    local enabled_csv="$1"
    local -n out_args="$2"
    local enabled=",$enabled_csv,"
    local binding

    local all_bindings=(
        assimp bgfx egl fmod freetype glfw harfbuzz hwloc jawt jemalloc ktx llvm lmdb lz4
        meshoptimizer msdfgen nanovg nfd nuklear odbc openal opencl opengl opengles openxr
        opus par remotery renderdoc rpmalloc sdl shaderc spng spvc stb tinyexr tinyfd vulkan
        vma xxhash yoga zstd
    )

    out_args=()
    for binding in "${all_bindings[@]}"; do
        if [[ "$enabled" == *",$binding,"* ]]; then
            out_args+=("-Dbinding.$binding=true")
        else
            out_args+=("-Dbinding.$binding=false")
        fi
    done
}

detect_java_home() {
    if [ -n "${JAVA_HOME:-}" ] && [ -f "$JAVA_HOME/include/jni.h" ]; then
        printf '%s' "$JAVA_HOME"
        return 0
    fi

    if command -v javac >/dev/null 2>&1; then
        local javac_path
        javac_path="$(readlink -f "$(command -v javac)")"
        local guessed_home
        guessed_home="$(dirname "$(dirname "$javac_path")")"
        if [ -f "$guessed_home/include/jni.h" ]; then
            printf '%s' "$guessed_home"
            return 0
        fi
    fi

    return 1
}

require_cmd git
require_cmd emcc
require_cmd emar
require_cmd curl
require_cmd tar
require_cmd javac
require_cmd jar

EMCC_VERSION_LINE="$(emcc --version | sed -n '1p')"
if [ -n "$EXPECTED_EMSDK_VERSION" ] && ! printf '%s' "$EMCC_VERSION_LINE" | grep -q " $EXPECTED_EMSDK_VERSION "; then
    echo "ERROR: emcc version mismatch. Expected emsdk $EXPECTED_EMSDK_VERSION, got: $EMCC_VERSION_LINE" >&2
    exit 1
fi

JAVA_HOME_DETECTED="$(detect_java_home || true)"
if [ -z "$JAVA_HOME_DETECTED" ]; then
    echo "ERROR: unable to find a JDK with JNI headers. Set JAVA_HOME to a JDK path." >&2
    exit 1
fi

case "$VARIANT" in
    mt)
        PTHREAD_FLAGS=(-pthread)
        PTHREAD_DEFINE="-D__EMSCRIPTEN_PTHREADS__=1"
        ;;
    st)
        PTHREAD_FLAGS=()
        PTHREAD_DEFINE="-D__EMSCRIPTEN_PTHREADS__=0"
        ;;
    *)
        echo "ERROR: --variant must be mt or st (got '$VARIANT')" >&2
        exit 1
        ;;
esac

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$REPO_ROOT/out/java-native-deps/$VARIANT"
fi

if [ -n "$TMP_DIR" ]; then
    mkdir -p "$TMP_DIR"
else
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ikvm-lwjgl3-build-${VARIANT}.XXXXXX")"
fi

cleanup() {
    if [ "$KEEP_TMP" = "true" ]; then
        log "Keeping temp directory: $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

LWJGL_SRC_DIR="$TMP_DIR/lwjgl3"
NATIVE_BUILD_DIR="$TMP_DIR/native-build"

mkdir -p "$NATIVE_BUILD_DIR/obj" "$OUTPUT_DIR"

log "Cloning lwjgl3 @ $LWJGL_REF"
git clone --depth 1 --branch "$LWJGL_REF" "$LWJGL_REPO" "$LWJGL_SRC_DIR"

ANT_CMD="$(setup_ant)"

declare -a TEMPLATE_BINDING_ARGS
declare -a COMPILE_BINDING_ARGS
build_binding_args "glfw,egl,opengl,opengles,vulkan" TEMPLATE_BINDING_ARGS
build_binding_args "glfw" COMPILE_BINDING_ARGS

log "Compiling lwjgl3 Java classes with Ant"
(cd "$LWJGL_SRC_DIR" && "$ANT_CMD" "${TEMPLATE_BINDING_ARGS[@]}" compile-templates)
(cd "$LWJGL_SRC_DIR" && "$ANT_CMD" "${COMPILE_BINDING_ARGS[@]}" compile)

CORE_CLASSES_DIR="$LWJGL_SRC_DIR/bin/classes/lwjgl/core"
GLFW_CLASSES_DIR="$LWJGL_SRC_DIR/bin/classes/lwjgl/glfw"
if [ ! -d "$CORE_CLASSES_DIR" ] || [ ! -d "$GLFW_CLASSES_DIR" ]; then
    echo "ERROR: expected Ant compile outputs not found under $LWJGL_SRC_DIR/bin/classes/lwjgl" >&2
    exit 1
fi

JAR_STAGING_DIR="$TMP_DIR/jar-staging"
rm -rf "$JAR_STAGING_DIR"
mkdir -p "$JAR_STAGING_DIR"
cp -a "$CORE_CLASSES_DIR"/. "$JAR_STAGING_DIR"/
cp -a "$GLFW_CLASSES_DIR"/. "$JAR_STAGING_DIR"/
jar cf "$OUTPUT_DIR/lwjgl3.jar" -C "$JAR_STAGING_DIR" .

log "Compiling lwjgl3 native sources"
NATIVE_SOURCES=(
    modules/lwjgl/core/src/main/c/common_tools.c
    modules/lwjgl/core/src/main/c/org_lwjgl_system_MemoryUtil.c
    modules/lwjgl/core/src/main/c/org_lwjgl_system_SharedLibraryUtil.c
    modules/lwjgl/core/src/main/c/org_lwjgl_system_ThreadLocalUtil.c
    modules/lwjgl/core/src/main/c/org_lwjgl_system_Upcalls.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_JNI.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_MemoryAccessJNI.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_jni_JNINativeInterface.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_libc_LibCErrno.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_libc_LibCLocale.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_libc_LibCStdio.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_libc_LibCStdlib.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_libc_LibCString.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_libffi_FFICIF.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_libffi_FFIClosure.c
    modules/lwjgl/core/src/generated/c/org_lwjgl_system_libffi_LibFFI.c
    modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_DynamicLinkLoader.c
    modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_FCNTL.c
    modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_MMAN.c
    modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_PThread.c
    modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_Socket.c
    modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_Stat.c
)

COMMON_NATIVE_FLAGS=(
    -O2
    -fPIC
    -Wno-error
    "$PTHREAD_DEFINE"
    -DLWJGL_LINUX
    -DLWJGL_x64
    -I"$JAVA_HOME_DETECTED/include"
    -I"$JAVA_HOME_DETECTED/include/linux"
    -I"$LWJGL_SRC_DIR/modules/lwjgl/core/src/main/c"
    -I"$LWJGL_SRC_DIR/modules/lwjgl/core/src/main/c/linux"
    -I"$LWJGL_SRC_DIR/modules/lwjgl/core/src/main/c/libffi"
    -I"$LWJGL_SRC_DIR/modules/lwjgl/core/src/main/c/libffi/x86"
)

for rel in "${NATIVE_SOURCES[@]}"; do
    src="$LWJGL_SRC_DIR/$rel"
    if [ ! -f "$src" ]; then
        echo "ERROR: expected source file not found: $src" >&2
        exit 1
    fi

    obj_name="$(basename "${rel%.c}").o"
    obj="$NATIVE_BUILD_DIR/obj/$obj_name"
    emcc -c "$src" -o "$obj" "${COMMON_NATIVE_FLAGS[@]}" "${PTHREAD_FLAGS[@]}"
done

emar rcs "$OUTPUT_DIR/liblwjgl3.a" "$NATIVE_BUILD_DIR"/obj/*.o

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
