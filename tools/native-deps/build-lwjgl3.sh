#!/usr/bin/env bash
# build-lwjgl3.sh - Builds a LWJGL3 jar + static native archive for Emscripten.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

LWJGL_REPO="https://github.com/LWJGL/lwjgl3.git"
# 3.4.2 is the latest LWJGL release. A single 3.4.2 jar + natives is built to
# serve as a drop-in replacement under every Minecraft version that uses LWJGL3
# (MC 1.13 through the 2026 line). See docs: the public binding surface is a
# near-superset of the 3.1.6/3.2.x/3.3.x versions MC ships and the >=3.3.0 "cookie"
# MemoryUtil offset resolution is IKVM-safe. Where 3.4.0 did remove or re-type API
# that older Minecraft links against, lwjgl3.patch re-adds it: struct *Stack helpers
# (generator shim), STBImageResize.nstbir_resize_uint8 (stb_image_resize v1, dropped
# for resize2) and the boolean TinyFileDialogs.tinyfd_messageBox overload.
LWJGL_REF="${LWJGL_REF:-3.4.2}"
LWJGL_PATCH="${LWJGL_PATCH:-$SCRIPT_DIR/lwjgl3.patch}"
EXPECTED_EMSDK_VERSION="${EXPECTED_EMSDK_VERSION:-3.1.56}"
ANT_VERSION="${ANT_VERSION:-1.10.15}"
ANT_BASE_URL="${ANT_BASE_URL:-https://archive.apache.org/dist/ant/binaries}"
ANT_CACHE_ROOT="${ANT_CACHE_ROOT:-$WORKSPACE/.cache}"

OUTPUT_DIR="${OUTPUT_DIR:-}"
VARIANT="${VARIANT:-mt}"
KEEP_TMP="false"
TMP_DIR=""

usage() {
    cat <<'EOF'
Usage: build-lwjgl3.sh [options]

Options:
  --variant=<mt|st>            Build variant (default: mt).
  --output-dir=<path>          Output directory (default: tools/native-deps/out/<variant>).
  --lwjgl-ref=<ref>            LWJGL git ref/tag (default: 3.4.2).
  --lwjgl-patch=<path>         Optional patch to apply to lwjgl clone.
  --ant-cache-root=<path>      Persistent Apache Ant cache root.
  --tmp-dir=<path>             Temporary build directory (default: mktemp).
  --keep-tmp                   Keep temporary build directory.
  -h, --help                   Show this help message.

Environment overrides:
  VARIANT
  OUTPUT_DIR
  LWJGL_REF
  LWJGL_PATCH
  EXPECTED_EMSDK_VERSION
  ANT_CACHE_ROOT
EOF
}

for arg in "$@"; do
    case "$arg" in
        --variant=*) VARIANT="${arg#*=}" ;;
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --lwjgl-ref=*) LWJGL_REF="${arg#*=}" ;;
        --lwjgl-patch=*) LWJGL_PATCH="${arg#*=}" ;;
        --ant-cache-root=*) ANT_CACHE_ROOT="${arg#*=}" ;;
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

shopt -s nullglob

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

setup_ant() {
    if [ -n "${ANT_HOME:-}" ] && [ -x "$ANT_HOME/bin/ant" ]; then
        printf '%s' "$ANT_HOME/bin/ant"
        return 0
    fi

    local ant_root="$ANT_CACHE_ROOT/apache-ant-$ANT_VERSION"
    local ant_archive="$ANT_CACHE_ROOT/apache-ant-$ANT_VERSION-bin.tar.gz"
    mkdir -p "$ANT_CACHE_ROOT"

    if [ ! -x "$ant_root/bin/ant" ]; then
        if [ ! -f "$ant_archive" ]; then
            log "Downloading Apache Ant $ANT_VERSION" >&2
            curl -fsSL -o "$ant_archive" "$ANT_BASE_URL/apache-ant-$ANT_VERSION-bin.tar.gz"
        else
            log "Using cached Apache Ant archive: $ant_archive" >&2
        fi

        rm -rf "$ant_root"
        tar -xzf "$ant_archive" -C "$ANT_CACHE_ROOT"
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
    local binding

    # 3.4.2 binding module set. Unlisted modules default to enabled in
    # config/build-bindings.xml, so every module must appear here to be
    # explicitly toggled. (core11/core25/core27 are multi-release overlays,
    # not bindings, and are intentionally absent.) Every entry must be a real
    # module under modules/lwjgl/: with "all" each becomes -Dbinding.X=true,
    # which BindingConfig turns into a modules/lwjgl/X/src/templates/kotlin path
    # that kotlinc requires to exist (there is no "sse" module, so it is absent).
    local all_bindings=(
        assimp bgfx egl fmod freetype glfw harfbuzz hwloc jawt jemalloc ktx llvm lmdb
        lz4 meshoptimizer mimalloc msdfgen nanovg nfd nuklear odbc openal opencl opengl
        opengles openxr opus par remotery renderdoc rpmalloc sdl shaderc spng spvc
        stb tinyexr tinyfd vma vulkan xxhash yoga zstd
    )

    local enabled
    if [ "$enabled_csv" = "all" ]; then
        # Turn on every binding so the whole Java surface is generated/compiled.
        local IFS=,
        enabled=",${all_bindings[*]},"
    else
        enabled=",$enabled_csv,"
    fi

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

parse_java_major() {
    local version="$1"

    case "$version" in
        1.*)
            printf '%s' "${version#1.}" | cut -d. -f1
            ;;
        *)
            printf '%s' "$version" | cut -d. -f1
            ;;
    esac
}

detect_java8_home() {
    local -a candidates=()
    local javac_path
    local guessed_home
    local candidate
    local javac_version
    local major
    local -A seen=()

    if [ -n "${JAVA8_HOME:-}" ]; then
        candidates+=("$JAVA8_HOME")
    fi

    if [ -n "${JAVA_HOME:-}" ]; then
        candidates+=("$JAVA_HOME")
    fi

    if command -v javac >/dev/null 2>&1; then
        javac_path="$(readlink -f "$(command -v javac)")"
        guessed_home="$(dirname "$(dirname "$javac_path")")"
        candidates+=("$guessed_home")
    fi

    for candidate in /usr/lib/jvm/*; do
        [ -d "$candidate" ] || continue
        candidates+=("$candidate")
    done

    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
        [ -d "$candidate" ] || continue

        if [ -n "${seen[$candidate]:-}" ]; then
            continue
        fi
        seen["$candidate"]=1

        if [ ! -x "$candidate/bin/javac" ] || [ ! -f "$candidate/include/jni.h" ] || [ ! -f "$candidate/jre/lib/rt.jar" ]; then
            continue
        fi

        javac_version="$("$candidate/bin/javac" -version 2>&1 | awk '{print $2}')"
        major="$(parse_java_major "$javac_version")"

        if [ "$major" = "8" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done

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

JAVA8_HOME_DETECTED="$(detect_java8_home || true)"
if [ -z "$JAVA8_HOME_DETECTED" ]; then
    echo "ERROR: unable to find a JDK 8 installation with rt.jar. Set JAVA8_HOME to a JDK 8 path." >&2
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
    OUTPUT_DIR="$WORKSPACE/out/$VARIANT"
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

LWJGL_SRC_DIR="$WORKSPACE/lwjgl3"
NATIVE_BUILD_DIR="$TMP_DIR/native-build"
LIBFFI_INCLUDE_DIR="$WORKSPACE/out/$VARIANT/libffi-include"

if [ ! -f "$LIBFFI_INCLUDE_DIR/ffi.h" ] || [ ! -f "$LIBFFI_INCLUDE_DIR/ffitarget.h" ]; then
    echo "ERROR: expected configured libffi headers not found under $LIBFFI_INCLUDE_DIR" >&2
    echo "Run build-libffi.sh for variant '$VARIANT' before build-lwjgl3.sh." >&2
    exit 1
fi

mkdir -p "$NATIVE_BUILD_DIR/obj" "$OUTPUT_DIR"

if [ ! -d "$LWJGL_SRC_DIR/.git" ]; then
    log "Cloning lwjgl3 @ $LWJGL_REF"
    git clone --depth 1 --branch "$LWJGL_REF" "$LWJGL_REPO" "$LWJGL_SRC_DIR"
else
    log "lwjgl3 source already present, skipping clone."
fi

# Guard against a stale checkout at a different ref (the skip-clone path above
# only checks for a .git dir). A mismatched tree would silently build the wrong
# LWJGL and fail to apply the (ref-specific) patch.
CHECKOUT_REF="$(git -C "$LWJGL_SRC_DIR" describe --tags --always 2>/dev/null || true)"
if [ "$CHECKOUT_REF" != "$LWJGL_REF" ]; then
    echo "ERROR: lwjgl3 checkout is at '$CHECKOUT_REF' but expected '$LWJGL_REF'." >&2
    echo "Remove '$LWJGL_SRC_DIR' so it is re-cloned at the correct ref." >&2
    exit 1
fi

apply_patch_once "$LWJGL_SRC_DIR" "$LWJGL_PATCH" "$(basename "$LWJGL_PATCH")"

# LWJGL's GeneratorKt rewrites modules/lwjgl/*/src/generated/ with only the
# JNI overloads needed by the bindings enabled on THIS run. If a prior run
# narrowed JNI.java (e.g. compiled without openal), the array-taking invokePV
# overloads vanish and javac fails. Restore generated/ from git so each build
# starts from upstream's full set and is independent of prior runs.
log "Restoring lwjgl3 generated/ trees from git"
(cd "$LWJGL_SRC_DIR" && \
    git ls-tree -d --name-only HEAD -r \
    | grep -E '^modules/lwjgl/[^/]+/src/generated$' \
    | xargs -r git checkout HEAD --)

# Force the generator to re-emit every generated file. Two independent caches would
# otherwise ship the upstream (unpatched) sources we just restored — losing
# generator-emitted patches such as the re-added struct mallocStack/callocStack
# compatibility methods:
#   1. Ant's `generate` target caches on bin/classes/generator/generated-touch.txt.
#   2. GeneratorKt itself skips a file when its output is newer than the generator
#      sources (`max(moduleLM, GENERATOR_LAST_MODIFIED) < output.lastModified`). The
#      `git checkout` above stamps restored files with the current time, which flips
#      regeneration on/off depending on the previous build's state.
# Backdate the restored generated files and drop the ant touch file so both checks
# always regenerate. Regeneration is deterministic and only adds a few seconds.
rm -f "$LWJGL_SRC_DIR/bin/classes/generator/generated-touch.txt"
find "$LWJGL_SRC_DIR"/modules/lwjgl/*/src/generated -type f -exec touch -t 200001010000 {} + 2>/dev/null || true

# Force a full javac recompile. The backdating above sets every generated .java
# to the year 2000 to drive the generator's regeneration check, but that same
# ancient mtime defeats javac's up-to-date check: if a prior build left stale
# .class files (e.g. a narrower JNI.class from a smaller binding set), ant's
# <javac> sees the "older" source and skips recompiling it, so the new bindings
# would compile against the stale core. Deleting the compile output guarantees
# every module is rebuilt from the current generated sources.
rm -rf "$LWJGL_SRC_DIR/bin/classes/lwjgl"

# Force compile-templates to recompile the Kotlin templates for the full binding
# set. `module.templatepath` (BindingConfig.java) lists only the *enabled*
# bindings' template dirs, but compile-templates caches on bin/classes/templates/
# touch.txt vs. the .kt mtimes -- it never invalidates when the enabled binding
# set changes. A prior narrower build therefore leaves bin/classes/templates
# holding only that subset; the Generator then logs "No templates found in
# <binding>.templates package" for the rest and emits a NARROWED core JNI.java
# (missing invoke*/call* overloads), which makes every unbuilt binding's javac
# fail. Wipe the compiled templates so kotlinc re-emits all of them this run.
rm -rf "$LWJGL_SRC_DIR/bin/classes/templates"

ANT_CMD="$(setup_ant)"

# Enable every LWJGL 3.4.2 binding on the Java side. The native archives built
# further down only cover the handful of modules we ship native code for
# (core/opengl/stb/tinyfd + friends), but the jar carries the *full* Java binding
# surface so IKVM/Minecraft never fails to load a class just because a native
# binding hasn't been wired up yet. A binding whose natives are absent only
# breaks if one of its native methods is actually invoked at runtime.
declare -a ALL_BINDING_ARGS
build_binding_args "all" ALL_BINDING_ARGS

log "Compiling lwjgl3 Java classes with Ant"
(cd "$LWJGL_SRC_DIR" && env JAVA8_HOME="$JAVA8_HOME_DETECTED" "$ANT_CMD" "${ALL_BINDING_ARGS[@]}" compile-templates)
(cd "$LWJGL_SRC_DIR" && env JAVA8_HOME="$JAVA8_HOME_DETECTED" "$ANT_CMD" "${ALL_BINDING_ARGS[@]}" compile)

LWJGL_CLASSES_ROOT="$LWJGL_SRC_DIR/bin/classes/lwjgl"
CORE_CLASSES_DIR="$LWJGL_CLASSES_ROOT/core"
# core must always be present and populated; without it nothing else links. The
# per-binding dirs are validated implicitly: compileBinding fails the whole Ant
# run (failonerror) if any enabled module does not compile, so a successful
# compile above means every binding produced classes.
if [ ! -d "$CORE_CLASSES_DIR" ] || [ -z "$(find "$CORE_CLASSES_DIR" -name '*.class' -print -quit)" ]; then
    echo "ERROR: expected Ant compile output (core classes) not found under $LWJGL_CLASSES_ROOT" >&2
    exit 1
fi

JAR_STAGING_DIR="$TMP_DIR/jar-staging"
rm -rf "$JAR_STAGING_DIR"
mkdir -p "$JAR_STAGING_DIR"

# Fold every compiled binding module into the jar. compileBinding creates an
# output dir for every module regardless of whether it was enabled, so only
# copy dirs that actually contain classes (skips the empty placeholders and any
# module that legitimately emitted nothing).
SHIPPED_MODULES=()
for module_dir in "$LWJGL_CLASSES_ROOT"/*/; do
    [ -d "$module_dir" ] || continue
    if [ -z "$(find "$module_dir" -name '*.class' -print -quit)" ]; then
        continue
    fi
    cp -a "$module_dir". "$JAR_STAGING_DIR"/
    SHIPPED_MODULES+=("$(basename "$module_dir")")
done

log "Shipping ${#SHIPPED_MODULES[@]} Java binding modules: ${SHIPPED_MODULES[*]}"
jar cf "$OUTPUT_DIR/lwjgl3.jar" -C "$JAR_STAGING_DIR" .

log "Compiling lwjgl3 native sources"
NATIVE_SOURCES=(
    modules/lwjgl/core/src/main/c/common_tools.c
    modules/lwjgl/core/src/main/c/org_lwjgl_system_MemoryUtil.c
    modules/lwjgl/core/src/main/c/org_lwjgl_system_ThreadLocalUtil.c
    # 3.4.x moved the upcall/callback machinery out of Callback.c into Upcalls.c
    # (libffi-based). SharedLibraryUtil.c is required by the patched LinuxLibrary.getPath.
    modules/lwjgl/core/src/main/c/org_lwjgl_system_Upcalls.c
    modules/lwjgl/core/src/main/c/org_lwjgl_system_SharedLibraryUtil.c
    # Combined wasm libffi closure allocator (patch-added), replaces the old dyncall bridge.
    modules/lwjgl/core/src/main/c/lwjgl_wasm_ffi_closure.c
    modules/lwjgl/core/src/main/c/linux/org_lwjgl_system_linux_StaticLinkLoader.c
    modules/lwjgl/tinyfd/src/main/c/tinyfd_js_proxy.c
)

STB_NATIVE_SOURCES=()

for src in "$LWJGL_SRC_DIR"/modules/lwjgl/core/src/generated/c/org_lwjgl_system_*.c; do
    NATIVE_SOURCES+=("${src#"$LWJGL_SRC_DIR"/}")
done

# Of the org.lwjgl.system.linux.* bindings, only DynamicLinkLoader (dlopen/dlsym)
# is reachable from our shipped modules (via LinuxLibrary's dynamic fallback). The
# rest are POSIX syscall wrappers added in 3.3.x/3.4.x (FCNTL, MMAN, PThread,
# Socket, Stat, UIO, UNISTD, liburing) that Minecraft/GL never call and that
# reference symbols unavailable under Emscripten (process_vm_readv, io_uring, ...).
# Compile only the one we need rather than glob-and-skip.
DL_LOADER_REL="modules/lwjgl/core/src/generated/c/linux/org_lwjgl_system_linux_DynamicLinkLoader.c"
if [ -f "$LWJGL_SRC_DIR/$DL_LOADER_REL" ]; then
    NATIVE_SOURCES+=("$DL_LOADER_REL")
else
    echo "ERROR: expected generated source not found: $DL_LOADER_REL" >&2
    exit 1
fi

for src in "$LWJGL_SRC_DIR"/modules/lwjgl/opengl/src/generated/c/org_lwjgl_opengl_*.c; do
    base="$(basename "$src")"
    # WGL (Windows) / GLX (X11) / CGL (macOS) are platform GL-context bindings that
    # include platform-only headers (e.g. WindowsLWJGL.h). The GL context is created
    # via GLFW/emscripten here and Minecraft calls none of these, so skip them.
    case "$base" in
        org_lwjgl_opengl_WGL*.c|org_lwjgl_opengl_GLX*.c|org_lwjgl_opengl_CGL*.c) continue ;;
    esac
    NATIVE_SOURCES+=("${src#"$LWJGL_SRC_DIR"/}")
done

for src in "$LWJGL_SRC_DIR"/modules/lwjgl/stb/src/generated/c/org_lwjgl_stb_*.c; do
    STB_NATIVE_SOURCES+=("${src#"$LWJGL_SRC_DIR"/}")
done

COMMON_NATIVE_FLAGS=(
    -O2
    -fPIC
    -Wno-error
    "$PTHREAD_DEFINE"
    -DLWJGL_LINUX
    -DLWJGL_x64
    -I"$JAVA_HOME_DETECTED/include"
    -I"$JAVA_HOME_DETECTED/include/linux"
    -I"$LIBFFI_INCLUDE_DIR"
    -I"$LWJGL_SRC_DIR/modules/lwjgl/core/src/main/c"
    -I"$LWJGL_SRC_DIR/modules/lwjgl/opengl/src/main/c"
    -I"$LWJGL_SRC_DIR/modules/lwjgl/core/src/main/c/linux"
    -I"$LWJGL_SRC_DIR/modules/lwjgl/stb/src/main/c"
)

NATIVE_OBJECTS=()
STB_NATIVE_OBJECTS=()

for rel in "${NATIVE_SOURCES[@]}"; do
    src="$LWJGL_SRC_DIR/$rel"
    if [ ! -f "$src" ]; then
        echo "ERROR: expected source file not found: $src" >&2
        exit 1
    fi

    obj_name="$(basename "${rel%.c}").o"
    obj="$NATIVE_BUILD_DIR/obj/$obj_name"
    emcc -c "$src" -o "$obj" "${COMMON_NATIVE_FLAGS[@]}" "${PTHREAD_FLAGS[@]}"
    NATIVE_OBJECTS+=("$obj")
done

for rel in "${STB_NATIVE_SOURCES[@]}"; do
    src="$LWJGL_SRC_DIR/$rel"
    if [ ! -f "$src" ]; then
        echo "ERROR: expected source file not found: $src" >&2
        exit 1
    fi

    obj_name="$(basename "${rel%.c}").o"
    obj="$NATIVE_BUILD_DIR/obj/$obj_name"
    emcc -c "$src" -o "$obj" "${COMMON_NATIVE_FLAGS[@]}" "${PTHREAD_FLAGS[@]}"
    STB_NATIVE_OBJECTS+=("$obj")
done

rm -f "$OUTPUT_DIR/liblwjgl3.a" "$OUTPUT_DIR/liblwjgl_stb.a"
emar rcs "$OUTPUT_DIR/liblwjgl3.a" "${NATIVE_OBJECTS[@]}"
emar rcs "$OUTPUT_DIR/liblwjgl_stb.a" "${STB_NATIVE_OBJECTS[@]}"

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
