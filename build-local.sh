#!/usr/bin/env bash
# build-local.sh - Builds IKVM managed libraries locally
# Based on .github/workflows/ikvm-wasm-build.yml

set -euo pipefail

IKVM_REF="8.14.0"
NATIVE_SDK_VERSION="20251124.1"
WORKSPACE="$(cd "$(dirname "$0")" && pwd)"

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[build-local] $*"; }

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: required command '$1' not found" >&2
        exit 1
    fi
}

# ── Prerequisites ─────────────────────────────────────────────────────────────

require_cmd git
require_cmd mono
require_cmd java
require_cmd curl

# Locate clang/llvm-ar: prefer versioned (clang-20, llvm-ar-20), fall back to unversioned
CLANG_EXE=""
LLVM_AR_EXE=""
for ver in 20 19 18 17 ""; do
    suffix="${ver:+-$ver}"
    if command -v "clang${suffix}" &>/dev/null; then
        CLANG_EXE="$(command -v "clang${suffix}")"
        break
    fi
done
for ver in 20 19 18 17 ""; do
    suffix="${ver:+-$ver}"
    if command -v "llvm-ar${suffix}" &>/dev/null; then
        LLVM_AR_EXE="$(command -v "llvm-ar${suffix}")"
        break
    fi
done
if [ -z "$CLANG_EXE" ] || [ -z "$LLVM_AR_EXE" ]; then
    echo "ERROR: clang and llvm-ar are required" >&2
    exit 1
fi
log "Using clang:   $CLANG_EXE"
log "Using llvm-ar: $LLVM_AR_EXE"

# Locate JDK 8 (workflow sets JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64)
if [ -z "${JAVA_HOME:-}" ]; then
    for candidate in \
        /usr/lib/jvm/java-8-openjdk-amd64 \
        /usr/lib/jvm/java-8-openjdk \
        /usr/lib/jvm/java-1.8.0-openjdk-amd64 \
        /usr/lib/jvm/java-1.8.0-openjdk; do
        if [ -d "$candidate" ]; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi
if [ -z "${JAVA_HOME:-}" ]; then
    echo "ERROR: could not locate JDK 8. Set JAVA_HOME manually." >&2
    exit 1
fi
log "Using JAVA_HOME: $JAVA_HOME"

# ── .NET SDK setup ────────────────────────────────────────────────────────────
# IKVM's global.json requires .NET 9.0.x (rollForward: latestFeature).
# Install it locally via dotnet-install.sh if the system doesn't have it.

DOTNET_INSTALL_DIR="$WORKSPACE/.dotnet"
DOTNET_INSTALL_SCRIPT="$WORKSPACE/.dotnet-install.sh"

_dotnet_has_sdk() {
    # returns 0 if a 9.x SDK is already reachable
    dotnet --list-sdks 2>/dev/null | grep -q "^9\."
}

if ! _dotnet_has_sdk; then
    log "No .NET 9 SDK found – installing to $DOTNET_INSTALL_DIR ..."
    mkdir -p "$DOTNET_INSTALL_DIR"
    if [ ! -f "$DOTNET_INSTALL_SCRIPT" ]; then
        curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$DOTNET_INSTALL_SCRIPT"
        chmod +x "$DOTNET_INSTALL_SCRIPT"
    fi
    # Install the specific versions the workflow uses
    for ver in 6.0 7.0 8.0 9.0 10.0; do
        if ! dotnet --list-sdks 2>/dev/null | grep -q "^${ver}\."; then
            log "  Installing .NET $ver SDK ..."
            "$DOTNET_INSTALL_SCRIPT" --channel "$ver" --install-dir "$DOTNET_INSTALL_DIR" --no-path
        fi
    done
    export DOTNET_ROOT="$DOTNET_INSTALL_DIR"
    export PATH="$DOTNET_INSTALL_DIR:$PATH"
else
    log "System .NET SDKs: $(dotnet --list-sdks 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
fi

if ! command -v dotnet &>/dev/null; then
    echo "ERROR: 'dotnet' not found even after local install" >&2
    exit 1
fi

# ── Step 1: Clone IKVM source ─────────────────────────────────────────────────

if [ ! -d "$WORKSPACE/ikvm/.git" ]; then
    log "Cloning ikvmnet/ikvm @ $IKVM_REF ..."
    git clone \
        --recurse-submodules \
        --branch "$IKVM_REF" \
        https://github.com/ikvmnet/ikvm.git \
        "$WORKSPACE/ikvm"
else
    log "IKVM source already present, skipping clone."
fi

# ── Step 2: Apply patch ───────────────────────────────────────────────────────

cd "$WORKSPACE/ikvm"
if git apply --check "$WORKSPACE/ikvm.patch" 2>/dev/null; then
    log "Applying ikvm.patch ..."
    git apply "$WORKSPACE/ikvm.patch"
else
    log "ikvm.patch already applied or cannot be applied cleanly, skipping."
fi
cd "$WORKSPACE"

# ── Step 3: Version environment variables ─────────────────────────────────────

VERSION="$IKVM_REF"
export GitVersion_FullSemVer="$VERSION"
export GitVersion_SemVer="$VERSION"
export GitVersion_AssemblySemVer="${VERSION}.0"
export GitVersion_AssemblySemFileVer="${VERSION}.0"
export GitVersion_InformationalVersion="$VERSION"
export GitVersion_PreReleaseLabel=""
export GitVersion_WeightedPreReleaseNumber="0"

# ── Step 4: Build JTReg (OpenJDK Test Harness) ───────────────────────────────
# build-all.sh uses `git rev-parse --show-toplevel` to find its root, so it
# must be run from within the jtreg submodule directory.

JTREG_DIR="$WORKSPACE/ikvm/ext/jtreg"
JTREG_STAMP="$JTREG_DIR/build/stamp"

if [ -f "$JTREG_STAMP" ]; then
    log "JTReg already built, skipping."
else
    # If a partial build dir exists (no stamp), remove it so build-all.sh can start clean
    if [ -d "$JTREG_DIR/build" ]; then
        log "Removing incomplete JTReg build dir ..."
        rm -rf "$JTREG_DIR/build"
    fi
    log "Building JTReg (running from $JTREG_DIR) ..."
    (cd "$JTREG_DIR" && WGET_OPTS='-U Mozilla/5.0' bash make/build-all.sh "$JAVA_HOME")
    touch "$JTREG_STAMP"
fi

# ── Step 5: Download Native SDKs ─────────────────────────────────────────────

NATIVE_SDK_DIR="$WORKSPACE/ikvm/ext/ikvm-native-sdk"
NATIVE_SDK_STAMP="$NATIVE_SDK_DIR/.downloaded"
mkdir -p "$NATIVE_SDK_DIR"

if [ -f "$NATIVE_SDK_STAMP" ]; then
    log "Native SDKs already downloaded, skipping."
else
    log "Downloading Native SDKs (tag $NATIVE_SDK_VERSION) ..."
    RELEASE_BASE="https://github.com/ikvmnet/ikvm-native-sdk/releases/download/${NATIVE_SDK_VERSION}"
    ASSETS=(
        linux-arm.tar.gz
        linux-arm64.tar.gz
        linux-musl-arm.tar.gz
        linux-musl-arm64.tar.gz
        linux-musl-x64.tar.gz
        linux-x64.tar.gz
        osx.tar.gz
        win.tar.gz
    )
    for asset in "${ASSETS[@]}"; do
        log "  Downloading $asset ..."
        curl -fsSL -o "$NATIVE_SDK_DIR/$asset" "$RELEASE_BASE/$asset"
        tar xzf "$NATIVE_SDK_DIR/$asset" -C "$NATIVE_SDK_DIR"
        rm "$NATIVE_SDK_DIR/$asset"
    done
    touch "$NATIVE_SDK_STAMP"
fi

# ── Step 6: NuGet Restore ─────────────────────────────────────────────────────

export NUGET_PACKAGES="${NUGET_PACKAGES:-$WORKSPACE/.nuget/packages}"
log "Using NuGet package cache: $NUGET_PACKAGES"

cd "$WORKSPACE/ikvm"
log "Running NuGet restore ..."
dotnet restore IKVM.sln

# ── Step 7: Build Artifacts ───────────────────────────────────────────────────

log "Building IKVM artifacts (this will take a while) ..."
dotnet msbuild /m /bl \
    /p:Configuration="Release" \
    /p:Platform="Any CPU" \
    /p:PreReleaseLabel="${GitVersion_PreReleaseLabel}" \
    /p:PreReleaseNumber="${GitVersion_WeightedPreReleaseNumber}" \
    /p:Version="${GitVersion_FullSemVer}" \
    /p:AssemblyVersion="${GitVersion_AssemblySemVer}" \
    /p:InformationalVersion="${GitVersion_InformationalVersion}" \
    /p:FileVersion="${GitVersion_AssemblySemFileVer}" \
    /p:PackageVersion="${GitVersion_FullSemVer}" \
    /p:RepositoryUrl="https://github.com/ikvmnet/ikvm.git" \
    /p:PackageProjectUrl="https://github.com/ikvmnet/ikvm" \
    /p:BuildInParallel=true \
    /p:CreateHardLinksForAdditionalFilesIfPossible=true \
    /p:CreateHardLinksForCopyAdditionalFilesIfPossible=true \
    /p:CreateHardLinksForCopyFilesToOutputDirectoryIfPossible=true \
    /p:CreateHardLinksForCopyLocalIfPossible=true \
    /p:CreateHardLinksForPublishFilesIfPossible=true \
    /p:ContinuousIntegrationBuild=true \
    /p:ClangToolExe="$CLANG_EXE" \
    /p:LlvmArToolExe="$LLVM_AR_EXE" \
    /p:EnableOSXCodeSign=false \
    IKVM.dist.msbuildproj

# ── Step 8: Package Managed DLLs ─────────────────────────────────────────────

log "Packaging managed DLLs ..."
mkdir -p "$WORKSPACE/out/managed"

BYTECODE_DLL=$(find "$NUGET_PACKAGES/ikvm.bytecode" -name "IKVM.ByteCode.dll" -path "*/net8.0/*" | head -1)
if [ -z "$BYTECODE_DLL" ]; then
    echo "ERROR: Could not find IKVM.ByteCode.dll in NuGet package cache." >&2
    exit 1
fi

cp "$WORKSPACE/ikvm/src/IKVM.Runtime/bin/Release/net8.0/IKVM.Runtime.dll"   "$WORKSPACE/out/managed/"
cp "$WORKSPACE/ikvm/src/IKVM.CoreLib/bin/Release/net8.0/IKVM.CoreLib.dll"   "$WORKSPACE/out/managed/"
cp "$WORKSPACE/ikvm/src/IKVM.Java/bin/Release/net8.0/IKVM.Java.dll"         "$WORKSPACE/out/managed/"
cp "$BYTECODE_DLL"                                                            "$WORKSPACE/out/managed/"

log "Done! Managed DLLs are in $WORKSPACE/out/managed/"
ls -lh "$WORKSPACE/out/managed/"
