#!/usr/bin/env bash
# build-ikvm-native.sh — Builds IKVM WASM native static libraries for one variant.
# Assumes emcc, em++, emar are already in PATH (set up via emsdk or otherwise).
#
# Usage: build-ikvm-native.sh <ikvm-src-dir> <out-dir> <mt|st>
#   ikvm-src-dir   path to the ikvmnet/ikvm checkout
#   out-dir        output base directory; *.a files are written to <out-dir>/native/
#   variant        mt  → pthread build  → libjvm.a, libikvm.a, libiava.a
#                  st  → no-pthread     → ST-libjvm.a, ST-libikvm.a, ST-libiava.a

set -euo pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $(basename "$0") <ikvm-src-dir> <out-dir> <mt|st>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IKVM_SRC="$1"
OUT_DIR="$2"
VARIANT="$3"

case "$VARIANT" in
    mt)
        PREFIX=""
        PTHREAD_FLAGS=(-pthread)
        ;;
    st)
        PREFIX="ST-"
        PTHREAD_FLAGS=()
        ;;
    *)
        echo "ERROR: variant must be 'mt' or 'st', got '$VARIANT'" >&2
        exit 1
        ;;
esac

log() { echo "[build-ikvm-native/$VARIANT] $*"; }

LIBJVM_SRC="$IKVM_SRC/src/libjvm"
LIBIKVM_SRC="$IKVM_SRC/src/libikvm"
OPENJDK_DIR="$IKVM_SRC/ext/openjdk"

COMMON_DEFS=( -DTARGET_ARCH_x86 -DTARGET_OS_FAMILY_linux -DLINUX -D__int64='long long' )
COMMON_INCLUDES=(
    -I"$LIBJVM_SRC"
    -I"$OPENJDK_DIR/hotspot/src/share/vm"
    -I"$OPENJDK_DIR/hotspot/src/share/vm/prims"
    -I"$OPENJDK_DIR/hotspot/src/cpu/x86/vm"
    -I"$OPENJDK_DIR/hotspot/src/os/linux/vm"
    -I"$OPENJDK_DIR/jdk/src/share/javavm/export"
    -I"$OPENJDK_DIR/jdk/src/solaris/javavm/export"
    -I"$OPENJDK_DIR/jdk/src/linux/javavm/export"
)

# Variant-specific tmp subdirs to allow MT and ST to run in parallel without collisions
TMP_DIR="$OUT_DIR/native/tmp-$VARIANT"
mkdir -p "$TMP_DIR/libiava"
mkdir -p "$TMP_DIR/libjpeg"
mkdir -p "$TMP_DIR/libsunec"
mkdir -p "$TMP_DIR/libsunec/impl"
mkdir -p "$TMP_DIR/libunpack"
mkdir -p "$TMP_DIR/libunpack/pack"
mkdir -p "$TMP_DIR/libzip"
mkdir -p "$TMP_DIR/libzip/zlib"
mkdir -p "$TMP_DIR/libmanagement"
mkdir -p "$TMP_DIR/libnio"
mkdir -p "$TMP_DIR/libnet"

# ── libjvm ────────────────────────────────────────────────────────────────────

log "Building ${PREFIX}libjvm ..."
emcc -O2 -fPIC -fdeclspec "${PTHREAD_FLAGS[@]}" -c "$LIBJVM_SRC/jni.c"      -o "$TMP_DIR/jni.o"      "${COMMON_DEFS[@]}" "${COMMON_INCLUDES[@]}"
emcc -O2 -fPIC -fdeclspec "${PTHREAD_FLAGS[@]}" -c "$LIBJVM_SRC/jvm_emscripten_dynlib.c"      -o "$TMP_DIR/jvm_emscripten_dynlib.o"      "${COMMON_DEFS[@]}" "${COMMON_INCLUDES[@]}"
emcc -O2 -fPIC -fdeclspec "${PTHREAD_FLAGS[@]}" -c "$LIBJVM_SRC/jni_vargs.c" -o "$TMP_DIR/jni_vargs.o" "${COMMON_DEFS[@]}" "${COMMON_INCLUDES[@]}"
em++  -O2 -fPIC -std=c++11 -Wno-error -fdeclspec "${PTHREAD_FLAGS[@]}" -c "$LIBJVM_SRC/jvm.cpp" -o "$TMP_DIR/jvm.o" "${COMMON_DEFS[@]}" "${COMMON_INCLUDES[@]}"
emar rcs "$OUT_DIR/native/${PREFIX}libjvm.a" "$TMP_DIR/jni.o" "$TMP_DIR/jni_vargs.o" "$TMP_DIR/jvm.o" "$TMP_DIR/jvm_emscripten_dynlib.o"

# ── libikvm ───────────────────────────────────────────────────────────────────

log "Building ${PREFIX}libikvm ..."
emcc -O2 -fPIC -DLINUX "${PTHREAD_FLAGS[@]}" -c "$LIBIKVM_SRC/dl.c"  -o "$TMP_DIR/dl.o"
emcc -O2 -fPIC -DLINUX "${PTHREAD_FLAGS[@]}" -c "$LIBIKVM_SRC/sig.c" -o "$TMP_DIR/sig.o"
emar rcs "$OUT_DIR/native/${PREFIX}libikvm.a" "$TMP_DIR/dl.o" "$TMP_DIR/sig.o"

# ── libiava ───────────────────────────────────────────────────────────────────
# Source directories (linux uses solaris as the OS API dir per OpenJDK 8 convention)

LIBIAVA_SRCDIRS=(
    "$OPENJDK_DIR/jdk/src/solaris/native/java/lang"
    "$OPENJDK_DIR/jdk/src/share/native/java/lang"
    "$OPENJDK_DIR/jdk/src/share/native/java/lang/reflect"
    "$OPENJDK_DIR/jdk/src/share/native/java/lang/fdlibm/src"
    "$OPENJDK_DIR/jdk/src/share/native/java/io"
    "$OPENJDK_DIR/jdk/src/solaris/native/java/io"
    "$OPENJDK_DIR/jdk/src/share/native/java/nio"
    "$OPENJDK_DIR/jdk/src/share/native/java/security"
    "$OPENJDK_DIR/jdk/src/share/native/common"
    "$OPENJDK_DIR/jdk/src/share/native/sun/misc"
    "$OPENJDK_DIR/jdk/src/share/native/sun/reflect"
    "$OPENJDK_DIR/jdk/src/share/native/java/util"
    "$OPENJDK_DIR/jdk/src/share/native/java/util/concurrent/atomic"
    "$OPENJDK_DIR/jdk/src/solaris/native/common"
    "$OPENJDK_DIR/jdk/src/solaris/native/java/util"
    "$OPENJDK_DIR/jdk/src/solaris/native/sun/security/provider"
    "$OPENJDK_DIR/jdk/src/solaris/native/sun/io"
    "$OPENJDK_DIR/jdk/src/linux/native/jdk/internal/platform/cgroupv1"
)

# Files excluded on linux (mirrors libiava.clangproj excludes)
LIBIAVA_EXCLUDES="check_code\.c|verify_stub\.c|jspawnhelper\.c|Shutdown\.c|AccessController\.c|Throwable\.c|NativeAccessors\.c|Class\.c|Runtime\.c|Package\.c|SecurityManager\.c|Compiler\.c|Object\.c|ClassLoader\.c|Array\.c|Thread\.c|String\.c|ConstantPool\.c|URLClassPath\.c|Signal\.c|GC\.c|Field\.c|Executable\.c|VM\.c|Reflection\.c|AtomicLong\.c|ProcessImpl_md\.c|WinNTFileSystem_md\.c|dirent_md\.c|WindowsPreferences\.c|WinCAPISeedGenerator\.c|Win32ErrorMode\.c|java_props_macosx\.c"

# Per-srcdir -I flags PLUS COMMON_INCLUDES so that jni_md.h can find jni_x86.h
# (jni_md.h does `#include "jni_x86.h"` which resolves via the hotspot/src/cpu/x86/vm path)
# Also include the bundled JNI stub headers (generated by javah from the Java class files)
LIBIAVA_INCLUDES=()
for d in "${LIBIAVA_SRCDIRS[@]}"; do
    LIBIAVA_INCLUDES+=("-I$d")
done
LIBIAVA_INCLUDES+=("${COMMON_INCLUDES[@]}")
LIBIAVA_INCLUDES+=("-I$SCRIPT_DIR/jni-headers")
LIBIAVA_INCLUDES+=("-I$OPENJDK_DIR/jdk/src/share/native/java/lang/fdlibm/include")

LIBIAVA_DEFS=(
    -DTARGET_ARCH_x86 -DTARGET_OS_FAMILY_linux
    -DLINUX -D__linux__ -D_GNU_SOURCE -D_REENTRANT -D_LARGEFILE64_SOURCE
    -D_AMD64_ -Damd64
    -DJDK_MAJOR_VERSION='"1"' -DJDK_MINOR_VERSION='"8"'
    -DJDK_MICRO_VERSION='"0"' -DJDK_UPDATE_VERSION='"462"'
    -DJDK_BUILD_NUMBER='"b08"'
    '-DRELEASE="1.8.0_462-b08"'
    '-DVENDOR="IKVM"'
    '-DVENDOR_URL="https://github.com/ikvmnet/ikvm"'
    '-DVENDOR_URL_BUG="https://github.com/ikvmnet/ikvm/issues/"'
    '-DARCHPROPNAME="amd64"'
)

log "Building ${PREFIX}libiava ..."
LIBIAVA_OBJS=()
for dir in "${LIBIAVA_SRCDIRS[@]}"; do
    [ -d "$dir" ] || continue
    for src in "$dir"/*.c; do
        [ -f "$src" ] || continue
        fname="$(basename "$src")"
        if ! echo "$fname" | grep -qE "^($LIBIAVA_EXCLUDES)$"; then
            obj="$TMP_DIR/libiava/${fname%.c}.o"
            emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
                "${LIBIAVA_DEFS[@]}" "${LIBIAVA_INCLUDES[@]}" \
                -c "$src" -o "$obj"
            LIBIAVA_OBJS+=("$obj")
        fi
    done
done
emar rcs "$OUT_DIR/native/${PREFIX}libiava.a" "${LIBIAVA_OBJS[@]}"

# ── Shared defines/includes for remaining OpenJDK-derived native libraries ───
# These mirror the defines from openjdk.lib.props + lib.props for a linux-x64 target.

OPENJDK_LIB_DEFS=(
    -DLINUX -D__linux__ -D_GNU_SOURCE -D_REENTRANT -D_LARGEFILE64_SOURCE
    -D_AMD64_ -Damd64
    -DJDK_MAJOR_VERSION='"1"' -DJDK_MINOR_VERSION='"8"'
    -DJDK_MICRO_VERSION='"0"' -DJDK_UPDATE_VERSION='"462"'
    -DJDK_BUILD_NUMBER='"b08"'
)

# Base includes reused by all four libraries below.
# Use the JDK JNI export paths (not the Hotspot paths) since these libraries
# are JNI consumers, not hotspot internals.
OPENJDK_LIB_INCLUDES=(
    -I"$OPENJDK_DIR/jdk/src/share/javavm/export"
    -I"$OPENJDK_DIR/jdk/src/solaris/javavm/export"
    -I"$OPENJDK_DIR/jdk/src/linux/javavm/export"
    -I"$OPENJDK_DIR/jdk/src/share/native/common"
    -I"$OPENJDK_DIR/jdk/src/solaris/native/common"
    -I"$SCRIPT_DIR/jni-headers"
)

# ── libjpeg ───────────────────────────────────────────────────────────────────

JPEG_SRC="$OPENJDK_DIR/jdk/src/share/native/sun/awt/image/jpeg"

log "Building ${PREFIX}libjpeg ..."
LIBJPEG_OBJS=()
for src in "$JPEG_SRC"/*.c; do
    [ -f "$src" ] || continue
    fname="$(basename "$src")"
    obj="$TMP_DIR/libjpeg/${fname%.c}.o"
    emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
        "${OPENJDK_LIB_DEFS[@]}" \
        -I"$JPEG_SRC" \
        "${OPENJDK_LIB_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBJPEG_OBJS+=("$obj")
done
emar rcs "$OUT_DIR/native/${PREFIX}libjpeg.a" "${LIBJPEG_OBJS[@]}"

# ── libsunec ──────────────────────────────────────────────────────────────────

SUNEC_SRC="$OPENJDK_DIR/jdk/src/share/native/sun/security/ec"

log "Building ${PREFIX}libsunec ..."
LIBSUNEC_OBJS=()

# ECC_JNI.cpp (C++11)
em++ -O2 -fPIC -Wno-error -std=c++11 "${PTHREAD_FLAGS[@]}" \
    "${OPENJDK_LIB_DEFS[@]}" \
    -DMP_API_COMPATIBLE -DNSS_ECC_MORE_THAN_SUITE_B \
    -I"$SUNEC_SRC/impl" \
    "${OPENJDK_LIB_INCLUDES[@]}" \
    -c "$SUNEC_SRC/ECC_JNI.cpp" -o "$TMP_DIR/libsunec/ECC_JNI.o"
LIBSUNEC_OBJS+=("$TMP_DIR/libsunec/ECC_JNI.o")

# impl/*.c (C99)
for src in "$SUNEC_SRC/impl"/*.c; do
    [ -f "$src" ] || continue
    fname="$(basename "$src")"
    obj="$TMP_DIR/libsunec/impl/${fname%.c}.o"
    emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
        "${OPENJDK_LIB_DEFS[@]}" \
        -DMP_API_COMPATIBLE -DNSS_ECC_MORE_THAN_SUITE_B \
        -I"$SUNEC_SRC/impl" \
        "${OPENJDK_LIB_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBSUNEC_OBJS+=("$obj")
done

# Local jni_onload.c (C99)
emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
    "${OPENJDK_LIB_DEFS[@]}" "${OPENJDK_LIB_INCLUDES[@]}" \
    -c "$IKVM_SRC/src/libsunec/jni_onload.c" -o "$TMP_DIR/libsunec/jni_onload.o"
LIBSUNEC_OBJS+=("$TMP_DIR/libsunec/jni_onload.o")

emar rcs "$OUT_DIR/native/${PREFIX}libsunec.a" "${LIBSUNEC_OBJS[@]}"

# ── libunpack ─────────────────────────────────────────────────────────────────

PACK_SRC="$OPENJDK_DIR/jdk/src/share/native/com/sun/java/util/jar/pack"

log "Building ${PREFIX}libunpack ..."
LIBUNPACK_OBJS=()

# OpenJDK pack .cpp files (C++11), excluding main.cpp and jni.cpp
for src in "$PACK_SRC"/*.cpp; do
    [ -f "$src" ] || continue
    fname="$(basename "$src")"
    [[ "$fname" == "main.cpp" || "$fname" == "jni.cpp" ]] && continue
    obj="$TMP_DIR/libunpack/pack/${fname%.cpp}.o"
    em++ -O2 -fPIC -Wno-error -std=c++11 "${PTHREAD_FLAGS[@]}" \
        "${OPENJDK_LIB_DEFS[@]}" \
        -DNO_ZLIB -DUNPACK_JNI -DFULL \
        -I"$PACK_SRC" \
        "${OPENJDK_LIB_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBUNPACK_OBJS+=("$obj")
done

# Local jni.cpp (C++11, replaces upstream jni.cpp)
em++ -O2 -fPIC -Wno-error -std=c++11 "${PTHREAD_FLAGS[@]}" \
    "${OPENJDK_LIB_DEFS[@]}" \
    -DNO_ZLIB -DUNPACK_JNI -DFULL \
    -I"$PACK_SRC" \
    "${OPENJDK_LIB_INCLUDES[@]}" \
    -c "$IKVM_SRC/src/libunpack/jni.cpp" -o "$TMP_DIR/libunpack/jni.o"
LIBUNPACK_OBJS+=("$TMP_DIR/libunpack/jni.o")

# Local jni_onload.c (C99)
emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
    "${OPENJDK_LIB_DEFS[@]}" "${OPENJDK_LIB_INCLUDES[@]}" \
    -c "$IKVM_SRC/src/libunpack/jni_onload.c" -o "$TMP_DIR/libunpack/jni_onload.o"
LIBUNPACK_OBJS+=("$TMP_DIR/libunpack/jni_onload.o")

emar rcs "$OUT_DIR/native/${PREFIX}libunpack.a" "${LIBUNPACK_OBJS[@]}"

# ── libzip ────────────────────────────────────────────────────────────────────

ZIP_SRC="$OPENJDK_DIR/jdk/src/share/native/java/util/zip"

log "Building ${PREFIX}libzip ..."
LIBZIP_OBJS=()

# Main zip sources (excluding ZipFile.c)
for src in "$ZIP_SRC"/*.c; do
    [ -f "$src" ] || continue
    fname="$(basename "$src")"
    [ "$fname" = "ZipFile.c" ] && continue
    obj="$TMP_DIR/libzip/${fname%.c}.o"
    emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
        "${OPENJDK_LIB_DEFS[@]}" \
        -DUSE_MMAP \
        -I"$ZIP_SRC" \
        -I"$ZIP_SRC/zlib" \
        -I"$OPENJDK_DIR/jdk/src/share/native/java/io" \
        -I"$OPENJDK_DIR/jdk/src/solaris/native/java/io" \
        "${OPENJDK_LIB_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBZIP_OBJS+=("$obj")
done

# Bundled zlib sources
for src in "$ZIP_SRC/zlib"/*.c; do
    [ -f "$src" ] || continue
    fname="$(basename "$src")"
    obj="$TMP_DIR/libzip/zlib/${fname%.c}.o"
    emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
        "${OPENJDK_LIB_DEFS[@]}" \
        -I"$ZIP_SRC/zlib" \
        "${OPENJDK_LIB_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBZIP_OBJS+=("$obj")
done

emar rcs "$OUT_DIR/native/${PREFIX}libzip.a" "${LIBZIP_OBJS[@]}"

# ── libmanagement ─────────────────────────────────────────────────────────────
# Sources: local *.c glob (management.c + jni_onload.c) plus linux-specific
# OpenJDK sources from solaris/native/sun/management/.
# No library-specific preprocessor defines for linux.

MGMT_SHARE_SRC="$OPENJDK_DIR/jdk/src/share/native/sun/management"
MGMT_SOL_SRC="$OPENJDK_DIR/jdk/src/solaris/native/sun/management"
LIBMGMT_SRC="$IKVM_SRC/src/libmanagement"

LIBMGMT_INCLUDES=(
    "${OPENJDK_LIB_INCLUDES[@]}"
    -I"$MGMT_SHARE_SRC"
    -I"$MGMT_SOL_SRC"
    -I"$SCRIPT_DIR/emscripten-stubs"
)

log "Building ${PREFIX}libmanagement ..."
LIBMGMT_OBJS=()

# Local sources (management.c, jni_onload.c)
for src in "$LIBMGMT_SRC"/*.c; do
    [ -f "$src" ] || continue
    fname="$(basename "$src")"
    obj="$TMP_DIR/libmanagement/${fname%.c}.o"
    emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
        "${OPENJDK_LIB_DEFS[@]}" "${LIBMGMT_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBMGMT_OBJS+=("$obj")
done

# Linux-specific OpenJDK sources
for src in \
    "$MGMT_SOL_SRC/FileSystemImpl.c" \
    "$MGMT_SOL_SRC/OperatingSystemImpl.c" \
    "$MGMT_SOL_SRC/LinuxOperatingSystem.c"; do
    [ -f "$src" ] || continue
    fname="$(basename "$src")"
    obj="$TMP_DIR/libmanagement/${fname%.c}.o"
    emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
        "${OPENJDK_LIB_DEFS[@]}" "${LIBMGMT_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBMGMT_OBJS+=("$obj")
done

emar rcs "$OUT_DIR/native/${PREFIX}libmanagement.a" "${LIBMGMT_OBJS[@]}"

# ── libnio ────────────────────────────────────────────────────────────────────
# JoinPathsAndFiles cross-product: (solaris/java/nio, solaris/sun/nio/ch,
# solaris/sun/nio/fs) × (common files + linux-only files), only if the file
# exists on disk.

NIO_SOL_JAVA_NIO="$OPENJDK_DIR/jdk/src/solaris/native/java/nio"
NIO_SOL_CH="$OPENJDK_DIR/jdk/src/solaris/native/sun/nio/ch"
NIO_SOL_FS="$OPENJDK_DIR/jdk/src/solaris/native/sun/nio/fs"
NIO_SHARE_CH="$OPENJDK_DIR/jdk/src/share/native/sun/nio/ch"
LIBNIO_SRC="$IKVM_SRC/src/libnio"

LIBNIO_INCLUDES=(
    "${OPENJDK_LIB_INCLUDES[@]}"
    -I"$NIO_SHARE_CH"
    -I"$OPENJDK_DIR/jdk/src/share/native/java/io"
    -I"$OPENJDK_DIR/jdk/src/share/native/java/net"
    -I"$OPENJDK_DIR/jdk/src/solaris/native/java/net"
    -I"$SCRIPT_DIR/emscripten-stubs"
)

LIBNIO_DEFS=(
    "${OPENJDK_LIB_DEFS[@]}"
    -D_Included_java_lang_Long
    "-Djava_lang_Long_serialVersionUID=4290774380558885855LL"
    "-Djava_lang_Long_MIN_VALUE=-9223372036854775808LL"
    "-Djava_lang_Long_MAX_VALUE=9223372036854775807LL"
    -D__SIGRTMAX=64
)

# Full list of files to attempt (cross-product of dirs × filenames; skip if not present)
NIO_DIRS=("$NIO_SOL_JAVA_NIO" "$NIO_SOL_CH" "$NIO_SOL_FS")
NIO_FILES=(
    # common (all platforms)
    DatagramChannelImpl.c DatagramDispatcher.c FileChannelImpl.c FileDispatcherImpl.c
    FileKey.c IOUtil.c MappedByteBuffer.c Net.c ServerSocketChannelImpl.c
    SocketChannelImpl.c SocketDispatcher.c
    # linux-only
    EPoll.c EPollArrayWrapper.c EPollPort.c InheritedChannel.c NativeThread.c
    PollArrayWrapper.c UnixAsynchronousServerSocketChannelImpl.c
    UnixAsynchronousSocketChannelImpl.c GnomeFileTypeDetector.c MagicFileTypeDetector.c
    LinuxNativeDispatcher.c LinuxWatchService.c UnixCopyFile.c UnixNativeDispatcher.c
)

log "Building ${PREFIX}libnio ..."
LIBNIO_OBJS=()

for dir in "${NIO_DIRS[@]}"; do
    for fname in "${NIO_FILES[@]}"; do
        src="$dir/$fname"
        [ -f "$src" ] || continue
        obj="$TMP_DIR/libnio/${fname%.c}.o"
        # Guard against duplicate object names (first match wins)
        if [[ ! " ${LIBNIO_OBJS[*]} " =~ " $obj " ]]; then
            emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
                "${LIBNIO_DEFS[@]}" "${LIBNIO_INCLUDES[@]}" \
                -c "$src" -o "$obj"
            LIBNIO_OBJS+=("$obj")
        fi
    done
done

# Local jni_onload.c
emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
    "${LIBNIO_DEFS[@]}" "${LIBNIO_INCLUDES[@]}" \
    -c "$LIBNIO_SRC/jni_onload.c" -o "$TMP_DIR/libnio/jni_onload.o"
LIBNIO_OBJS+=("$TMP_DIR/libnio/jni_onload.o")

emar rcs "$OUT_DIR/native/${PREFIX}libnio.a" "${LIBNIO_OBJS[@]}"

# ── libnet ────────────────────────────────────────────────────────────────────

NET_SHARE_SRC="$OPENJDK_DIR/jdk/src/share/native/java/net"
NET_SOL_SRC="$OPENJDK_DIR/jdk/src/solaris/native/java/net"
LIBNET_SRC="$IKVM_SRC/src/libnet"

LIBNET_INCLUDES=(
    "${OPENJDK_LIB_INCLUDES[@]}"
    -I"$NET_SHARE_SRC"
    -I"$NET_SOL_SRC"
    -I"$OPENJDK_DIR/jdk/src/share/native/java/io"
    -I"$SCRIPT_DIR/emscripten-stubs"
)

LIBNET_DEFS=(
    "${OPENJDK_LIB_DEFS[@]}"
    -D__SIGRTMAX=64
)

log "Building ${PREFIX}libnet ..."
LIBNET_OBJS=()

# Share sources
for fname in net_util.c InetAddress.c Inet4Address.c Inet6Address.c DatagramPacket.c; do
    src="$NET_SHARE_SRC/$fname"
    [ -f "$src" ] || continue
    obj="$TMP_DIR/libnet/${fname%.c}.o"
    emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
        "${LIBNET_DEFS[@]}" "${LIBNET_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBNET_OBJS+=("$obj")
done

# Solaris/Linux sources
for fname in net_util_md.c Inet4AddressImpl.c Inet6AddressImpl.c InetAddressImplFactory.c \
             NetworkInterface.c PlainDatagramSocketImpl.c PlainSocketImpl.c \
             SocketInputStream.c SocketOutputStream.c; do
    src="$NET_SOL_SRC/$fname"
    [ -f "$src" ] || continue
    obj="$TMP_DIR/libnet/${fname%.c}.o"
    emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
        "${LIBNET_DEFS[@]}" "${LIBNET_INCLUDES[@]}" \
        -c "$src" -o "$obj"
    LIBNET_OBJS+=("$obj")
done

# linux_close.c requires pthreads — only include in MT variant
if [ "$VARIANT" = "mt" ]; then
    src="$NET_SOL_SRC/linux_close.c"
    if [ -f "$src" ]; then
        obj="$TMP_DIR/libnet/linux_close.o"
        emcc -O2 -fPIC -Wno-error -std=c99 "${PTHREAD_FLAGS[@]}" \
            "${LIBNET_DEFS[@]}" "${LIBNET_INCLUDES[@]}" \
            -c "$src" -o "$obj"
        LIBNET_OBJS+=("$obj")
    fi
fi

emar rcs "$OUT_DIR/native/${PREFIX}libnet.a" "${LIBNET_OBJS[@]}"

log "Done! Artifacts written to $OUT_DIR/native/"
ls -lh "$OUT_DIR/native/${PREFIX}"*.a
