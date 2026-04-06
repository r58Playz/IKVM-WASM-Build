#!/usr/bin/env bash
# build-ikvm-local.sh - Builds IKVM managed libraries and WASM native artifacts.
# Shared by local runs and GitHub Actions.

set -euo pipefail

IKVM_REF="${IKVM_REF:-8.14.0}"
NATIVE_SDK_VERSION="${NATIVE_SDK_VERSION:-20251124.1}"
EMSDK_VERSION="${EMSDK_VERSION:-3.1.56}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_RUNTIME="${BUILD_RUNTIME:-linux-x64}"
ENABLED_RUNTIMES="${ENABLED_RUNTIMES:-$BUILD_RUNTIME}"
ENABLED_IMAGE_RUNTIMES="${ENABLED_IMAGE_RUNTIMES:-$BUILD_RUNTIME}"
ENABLED_IMAGE_BIN_RUNTIMES="${ENABLED_IMAGE_BIN_RUNTIMES:-$BUILD_RUNTIME}"
ENABLED_TOOL_RUNTIMES="${ENABLED_TOOL_RUNTIMES:-$BUILD_RUNTIME}"
CLANG_COMPAT_FLAGS="${CLANG_COMPAT_FLAGS:-}"

# ── Argument parsing ──────────────────────────────────────────────────────────

SKIP_MANAGED=false
SKIP_NATIVE=false
SKIP_BUNDLE=false
CLEAN_NATIVE=false
NATIVE_VARIANT="both"
for arg in "$@"; do
    case "$arg" in
        --skip-managed) SKIP_MANAGED=true ;;
        --skip-native) SKIP_NATIVE=true ;;
        --skip-bundle) SKIP_BUNDLE=true ;;
        --managed-only)
            SKIP_NATIVE=true
            SKIP_BUNDLE=true
            ;;
        --native-only)
            SKIP_MANAGED=true
            SKIP_BUNDLE=true
            ;;
        --native-variant=mt) NATIVE_VARIANT="mt" ;;
        --native-variant=st) NATIVE_VARIANT="st" ;;
        --native-variant=both) NATIVE_VARIANT="both" ;;
        --clean-native) CLEAN_NATIVE=true ;;
        *) echo "ERROR: unknown argument '$arg'" >&2; exit 1 ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[build-ikvm-local] $*"; }

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: required command '$1' not found" >&2
        exit 1
    fi
}

apply_patch_once() {
    local repo_dir="$1"
    local patch_file="$2"
    local patch_name="$3"

    if git -C "$repo_dir" apply --check "$patch_file" >/dev/null 2>&1; then
        log "Applying $patch_name ..."
        git -C "$repo_dir" apply "$patch_file"
    elif git -C "$repo_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        log "$patch_name already applied, skipping."
    else
        echo "ERROR: $patch_name cannot be applied cleanly in $repo_dir" >&2
        exit 1
    fi
}

add_unique_asset() {
    local asset="$1"
    if [ -z "${NATIVE_SDK_ASSET_SEEN[$asset]+x}" ]; then
        NATIVE_SDK_ASSETS+=("$asset")
        NATIVE_SDK_ASSET_SEEN["$asset"]=1
    fi
}

collect_native_sdk_assets() {
    local runtime_list="$1"
    local tokenized
    local runtime

    NATIVE_SDK_ASSETS=()
    declare -gA NATIVE_SDK_ASSET_SEEN=()

    tokenized="${runtime_list//,/;}"
    IFS=';' read -r -a _runtimes <<< "$tokenized"
    for runtime in "${_runtimes[@]}"; do
        runtime="${runtime//[[:space:]]/}"
        [ -n "$runtime" ] || continue
        case "$runtime" in
            linux-arm) add_unique_asset "linux-arm.tar.gz" ;;
            linux-arm64) add_unique_asset "linux-arm64.tar.gz" ;;
            linux-musl-arm) add_unique_asset "linux-musl-arm.tar.gz" ;;
            linux-musl-arm64) add_unique_asset "linux-musl-arm64.tar.gz" ;;
            linux-musl-x64) add_unique_asset "linux-musl-x64.tar.gz" ;;
            linux-x64) add_unique_asset "linux-x64.tar.gz" ;;
            osx*|macos*) add_unique_asset "osx.tar.gz" ;;
            win*|windows*) add_unique_asset "win.tar.gz" ;;
        esac
    done

    if [ "${#NATIVE_SDK_ASSETS[@]}" -eq 0 ]; then
        NATIVE_SDK_ASSETS=(
            linux-arm.tar.gz
            linux-arm64.tar.gz
            linux-musl-arm.tar.gz
            linux-musl-arm64.tar.gz
            linux-musl-x64.tar.gz
            linux-x64.tar.gz
            osx.tar.gz
            win.tar.gz
        )
    fi
}

java_version_from_home() {
    local home="$1"
    local version_line=""

    if [ ! -x "$home/bin/java" ]; then
        return 1
    fi

    version_line="$("$home/bin/java" -version 2>&1 | sed -n 's/.* version "\([^"]*\)".*/\1/p' | head -n 1 || true)"
    printf '%s' "$version_line"
}

java_home_is_8() {
    local home="$1"
    local version

    version="$(java_version_from_home "$home" || true)"
    [[ "$version" == 1.8* ]]
}

if [ "$SKIP_NATIVE" = "true" ] && [ "$CLEAN_NATIVE" = "true" ]; then
    log "Ignoring --clean-native because native build is skipped."
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────

require_cmd git
require_cmd curl
require_cmd zip
require_cmd tar

if [ "$SKIP_MANAGED" = "false" ]; then
    require_cmd mono
    require_cmd java

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

    CLANG_MAJOR="$($CLANG_EXE -dumpversion 2>/dev/null | cut -d. -f1 || true)"
    if [ -z "$CLANG_COMPAT_FLAGS" ] && [[ "$CLANG_MAJOR" =~ ^[0-9]+$ ]] && [ "$CLANG_MAJOR" -ge 22 ]; then
        CLANG_COMPAT_FLAGS="-Wno-incompatible-pointer-types"
    fi
    if [ -n "$CLANG_COMPAT_FLAGS" ]; then
        log "Using additional Clang compile options: $CLANG_COMPAT_FLAGS"
    fi

    # Locate JDK 8. Some CI runners set JAVA_HOME to a newer JDK by default.
    JAVA8_CANDIDATES=()
    if [ -n "${JAVA8_HOME:-}" ]; then
        JAVA8_CANDIDATES+=("$JAVA8_HOME")
    fi
    if [ -n "${JAVA_HOME_8_X64:-}" ]; then
        JAVA8_CANDIDATES+=("$JAVA_HOME_8_X64")
    fi
    if [ -n "${JAVA_HOME:-}" ]; then
        JAVA8_CANDIDATES+=("$JAVA_HOME")
    fi
    JAVA8_CANDIDATES+=(
        /usr/lib/jvm/java-8-openjdk-amd64
        /usr/lib/jvm/java-8-openjdk
        /usr/lib/jvm/java-1.8.0-openjdk-amd64
        /usr/lib/jvm/java-1.8.0-openjdk
    )

    JAVA_HOME=""
    for candidate in "${JAVA8_CANDIDATES[@]}"; do
        [ -d "$candidate" ] || continue
        if java_home_is_8 "$candidate"; then
            JAVA_HOME="$candidate"
            break
        fi
    done

    if [ -z "$JAVA_HOME" ]; then
        echo "ERROR: could not locate a JDK 8 home. Configure JAVA8_HOME, JAVA_HOME_8_X64, or JAVA_HOME to a JDK 8 path." >&2
        exit 1
    fi

    export JAVA_HOME
    JAVA_VERSION_DETECTED="$(java_version_from_home "$JAVA_HOME" || true)"
    log "Using JAVA_HOME: $JAVA_HOME (Java $JAVA_VERSION_DETECTED)"
fi

# ── .NET SDK setup ────────────────────────────────────────────────────────────
# IKVM's global.json requires .NET 9.0.x (rollForward: latestFeature).
# Install it locally via dotnet-install.sh if the system doesn't have it.

if [ "$SKIP_MANAGED" = "false" ]; then

DOTNET_INSTALL_DIR="$REPO_ROOT/.dotnet"
DOTNET_INSTALL_SCRIPT="$REPO_ROOT/.dotnet-install.sh"

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
    log "  Installing .NET 9 SDK ..."
    "$DOTNET_INSTALL_SCRIPT" --channel "9.0" --install-dir "$DOTNET_INSTALL_DIR" --no-path
    export DOTNET_ROOT="$DOTNET_INSTALL_DIR"
    export PATH="$DOTNET_INSTALL_DIR:$PATH"
else
    log "System .NET SDKs: $(dotnet --list-sdks 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
fi

if ! command -v dotnet &>/dev/null; then
    echo "ERROR: 'dotnet' not found even after local install" >&2
    exit 1
fi

fi # end SKIP_MANAGED=false

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

log "Updating IKVM submodules ..."
git -C "$WORKSPACE/ikvm" submodule update --init --recursive

# ── Step 2: Apply patch ───────────────────────────────────────────────────────

apply_patch_once "$WORKSPACE/ikvm" "$WORKSPACE/ikvm.patch" "ikvm.patch"
apply_patch_once "$WORKSPACE/ikvm/ext/openjdk" "$WORKSPACE/openjdk.patch" "openjdk.patch"

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

if [ "$SKIP_MANAGED" = "false" ]; then

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
mkdir -p "$NATIVE_SDK_DIR"

collect_native_sdk_assets "$ENABLED_RUNTIMES"
log "Native SDK runtime filters: $ENABLED_RUNTIMES"

RELEASE_BASE="https://github.com/ikvmnet/ikvm-native-sdk/releases/download/${NATIVE_SDK_VERSION}"
downloaded_any=false
for asset in "${NATIVE_SDK_ASSETS[@]}"; do
    marker="$NATIVE_SDK_DIR/.asset-${NATIVE_SDK_VERSION}-${asset}.ok"
    if [ -f "$marker" ]; then
        continue
    fi

    downloaded_any=true
    log "  Downloading $asset (tag $NATIVE_SDK_VERSION) ..."
    curl -fsSL -o "$NATIVE_SDK_DIR/$asset" "$RELEASE_BASE/$asset"
    tar xzf "$NATIVE_SDK_DIR/$asset" -C "$NATIVE_SDK_DIR"
    rm "$NATIVE_SDK_DIR/$asset"
    touch "$marker"
done

if [ "$downloaded_any" = "false" ]; then
    log "Native SDKs already downloaded for current runtime filters, skipping."
fi

# ── Step 6: NuGet Restore ─────────────────────────────────────────────────────

export NUGET_PACKAGES="${NUGET_PACKAGES:-$REPO_ROOT/.nuget/packages}"
log "Using NuGet package cache: $NUGET_PACKAGES"
log "Managed runtime filters: Enabled=$ENABLED_RUNTIMES Image=$ENABLED_IMAGE_RUNTIMES ImageBin=$ENABLED_IMAGE_BIN_RUNTIMES Tool=$ENABLED_TOOL_RUNTIMES"

RUNTIME_BUILD_PROPS=(
    "/p:EnabledRuntimes=$ENABLED_RUNTIMES"
    "/p:EnabledImageRuntimes=$ENABLED_IMAGE_RUNTIMES"
    "/p:EnabledImageBinRuntimes=$ENABLED_IMAGE_BIN_RUNTIMES"
    "/p:EnabledToolRuntimes=$ENABLED_TOOL_RUNTIMES"
    "/p:RuntimeIdentifier=$BUILD_RUNTIME"
)

if [ -n "$CLANG_COMPAT_FLAGS" ]; then
    RUNTIME_BUILD_PROPS+=("/p:AdditionalCompileOptions=$CLANG_COMPAT_FLAGS")
fi

cd "$WORKSPACE/ikvm"
log "Running NuGet restore ..."
dotnet restore IKVM.sln "${RUNTIME_BUILD_PROPS[@]}"

# ── Step 7: Build Artifacts ───────────────────────────────────────────────────

log "Building IKVM artifacts (this will take a while) ..."
dotnet msbuild /m /bl /nr:false \
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
    "${RUNTIME_BUILD_PROPS[@]}" \
    /p:ClangToolExe="$CLANG_EXE" \
    /p:LlvmArToolExe="$LLVM_AR_EXE" \
    /p:EnableOSXCodeSign=false \
    IKVM.dist.msbuildproj

# ── Step 8: Package Managed Outputs ──────────────────────────────────────────

log "Packaging managed outputs ..."
mkdir -p "$WORKSPACE/out/managed"

cp "$WORKSPACE/ikvm/dist/jre/net8.0/$BUILD_RUNTIME/bin/IKVM."{ByteCode,CoreLib,Java,Runtime}.dll "$WORKSPACE/out/managed/"

IKVM_TOOLS_DIST_DIR="$WORKSPACE/ikvm/dist/tools/net8.0/$BUILD_RUNTIME"
if [ ! -d "$IKVM_TOOLS_DIST_DIR" ]; then
    echo "ERROR: IKVM tools directory not found at: $IKVM_TOOLS_DIST_DIR" >&2
    exit 1
fi

rm -rf "$WORKSPACE/out/managed/ikvm-tools"
mkdir -p "$WORKSPACE/out/managed/ikvm-tools"
cp -r "$IKVM_TOOLS_DIST_DIR/." "$WORKSPACE/out/managed/ikvm-tools/"

log "Done! Managed outputs are in $WORKSPACE/out/managed/"
ls -lh "$WORKSPACE/out/managed/"

fi # end SKIP_MANAGED=false (Steps 4-8)

if [ "$SKIP_NATIVE" = "true" ]; then
    log "Skipping WASM native build."
else
    # ── Step 9: Build WASM Native ─────────────────────────────────────────────

    # ── emsdk setup ───────────────────────────────────────────────────────────

    EMSDK_DIR="$WORKSPACE/.emsdk"

    if emcc --version 2>/dev/null | grep -q "$EMSDK_VERSION"; then
        log "emsdk $EMSDK_VERSION already active."
    else
        log "Setting up emsdk $EMSDK_VERSION in $EMSDK_DIR ..."
        if [ ! -d "$EMSDK_DIR/.git" ]; then
            git clone https://github.com/emscripten-core/emsdk.git "$EMSDK_DIR"
        fi
        "$EMSDK_DIR/emsdk" install "$EMSDK_VERSION"
        "$EMSDK_DIR/emsdk" activate "$EMSDK_VERSION"
    fi

    if [ -f "$EMSDK_DIR/emsdk_env.sh" ]; then
        # shellcheck source=/dev/null
        source "$EMSDK_DIR/emsdk_env.sh"
    fi

    require_cmd emcc
    require_cmd em++
    require_cmd emar

    if [ "$CLEAN_NATIVE" = "true" ]; then
        log "Cleaning native output directory ..."
        rm -rf "$WORKSPACE/out/native/"*
    fi

    mkdir -p "$WORKSPACE/out/native"

    case "$NATIVE_VARIANT" in
        mt)
            log "Building WASM native artifacts (mt) ..."
            bash "$WORKSPACE/build-ikvm-native.sh" "$WORKSPACE/ikvm" "$WORKSPACE/out" mt
            ;;
        st)
            log "Building WASM native artifacts (st) ..."
            bash "$WORKSPACE/build-ikvm-native.sh" "$WORKSPACE/ikvm" "$WORKSPACE/out" st
            ;;
        both)
            log "Building WASM native artifacts (mt + st in parallel) ..."
            bash "$WORKSPACE/build-ikvm-native.sh" "$WORKSPACE/ikvm" "$WORKSPACE/out" mt &
            pid_mt=$!
            bash "$WORKSPACE/build-ikvm-native.sh" "$WORKSPACE/ikvm" "$WORKSPACE/out" st &
            pid_st=$!
            wait "$pid_mt"
            wait "$pid_st"
            ;;
    esac

    log "Done! WASM native artifacts are in $WORKSPACE/out/native/"
fi

# ── Step 10: Bundle Release Zips ──────────────────────────────────────────────

if [ "$SKIP_BUNDLE" = "true" ]; then
    log "Skipping bundle step."
elif [ ! -f "$WORKSPACE/out/managed/IKVM.Runtime.dll" ]; then
    log "Skipping bundle step: managed DLLs not present in out/managed/ (run without --skip-managed to build them)."
else
    log "Bundling release zips ..."

    IMAGE_DIR="$WORKSPACE/ikvm/src/IKVM.Image/bin/Release/net8.0/ikvm/$BUILD_RUNTIME/"
    if [ ! -d "$IMAGE_DIR" ]; then
        echo "ERROR: $BUILD_RUNTIME JRE image not found at: $IMAGE_DIR" >&2
        exit 1
    fi

    mkdir -p "$WORKSPACE/out/release"
    rm -rf "$WORKSPACE/out/bundle-staging"
    mkdir -p "$WORKSPACE/out/bundle-staging/image"

    # Copy image files into staging area
    cp -r "$IMAGE_DIR/." "$WORKSPACE/out/bundle-staging/image/"

    IKVM_TOOLS_SRC="$WORKSPACE/out/managed/ikvm-tools"
    if [ ! -d "$IKVM_TOOLS_SRC" ] && [ -d "$WORKSPACE/ikvm/dist/tools/net8.0/$BUILD_RUNTIME" ]; then
        log "ikvm-tools not found in out/managed, using dist/tools fallback."
        IKVM_TOOLS_SRC="$WORKSPACE/ikvm/dist/tools/net8.0/$BUILD_RUNTIME"
    fi
    if [ ! -d "$IKVM_TOOLS_SRC" ]; then
        echo "ERROR: ikvm-tools directory not found for bundling." >&2
        exit 1
    fi
    cp -r "$IKVM_TOOLS_SRC" "$WORKSPACE/out/bundle-staging/ikvm-tools"

    rm -f "$WORKSPACE/out/release/ikvm-wasm-bundle.zip"
    rm -f "$WORKSPACE/out/release/ikvm-wasm-ST-bundle.zip"
    # MT bundle (ikvm-wasm-bundle.zip)
    log "  Creating ikvm-wasm-bundle.zip ..."
    (
        cd "$WORKSPACE/out/bundle-staging"
        zip -j "$WORKSPACE/out/release/ikvm-wasm-bundle.zip" \
            "$WORKSPACE/out/managed/IKVM.Runtime.dll" \
            "$WORKSPACE/out/managed/IKVM.CoreLib.dll" \
            "$WORKSPACE/out/managed/IKVM.Java.dll" \
            "$WORKSPACE/out/managed/IKVM.ByteCode.dll" \
            "$WORKSPACE/out/native/libjvm.a" \
            "$WORKSPACE/out/native/libikvm.a" \
            "$WORKSPACE/out/native/libiava.a" \
            "$WORKSPACE/out/native/libjpeg.a" \
            "$WORKSPACE/out/native/libsunec.a" \
            "$WORKSPACE/out/native/libunpack.a" \
            "$WORKSPACE/out/native/libzip.a" \
            "$WORKSPACE/out/native/libmanagement.a" \
            "$WORKSPACE/out/native/libnio.a" \
            "$WORKSPACE/out/native/libnet.a"
        zip -r "$WORKSPACE/out/release/ikvm-wasm-bundle.zip" image
        zip -r "$WORKSPACE/out/release/ikvm-wasm-bundle.zip" ikvm-tools
    )

    # ST bundle (ikvm-wasm-ST-bundle.zip)
    log "  Creating ikvm-wasm-ST-bundle.zip ..."
    (
        mkdir -p "$WORKSPACE/out/st-native"
        cp "$WORKSPACE/out/native/ST-libjvm.a" "$WORKSPACE/out/st-native/libjvm.a"
        cp "$WORKSPACE/out/native/ST-libikvm.a" "$WORKSPACE/out/st-native/libikvm.a"
        cp "$WORKSPACE/out/native/ST-libiava.a" "$WORKSPACE/out/st-native/libiava.a"
        cp "$WORKSPACE/out/native/ST-libjpeg.a" "$WORKSPACE/out/st-native/libjpeg.a"
        cp "$WORKSPACE/out/native/ST-libsunec.a" "$WORKSPACE/out/st-native/libsunec.a"
        cp "$WORKSPACE/out/native/ST-libunpack.a" "$WORKSPACE/out/st-native/libunpack.a"
        cp "$WORKSPACE/out/native/ST-libzip.a" "$WORKSPACE/out/st-native/libzip.a"
        cp "$WORKSPACE/out/native/ST-libmanagement.a" "$WORKSPACE/out/st-native/libmanagement.a"
        cp "$WORKSPACE/out/native/ST-libnio.a" "$WORKSPACE/out/st-native/libnio.a"
        cp "$WORKSPACE/out/native/ST-libnet.a" "$WORKSPACE/out/st-native/libnet.a"
        cd "$WORKSPACE/out/bundle-staging"
        zip -j "$WORKSPACE/out/release/ikvm-wasm-ST-bundle.zip" \
            "$WORKSPACE/out/managed/IKVM.Runtime.dll" \
            "$WORKSPACE/out/managed/IKVM.CoreLib.dll" \
            "$WORKSPACE/out/managed/IKVM.Java.dll" \
            "$WORKSPACE/out/managed/IKVM.ByteCode.dll" \
            "$WORKSPACE/out/st-native/libjvm.a" \
            "$WORKSPACE/out/st-native/libikvm.a" \
            "$WORKSPACE/out/st-native/libiava.a" \
            "$WORKSPACE/out/st-native/libjpeg.a" \
            "$WORKSPACE/out/st-native/libsunec.a" \
            "$WORKSPACE/out/st-native/libunpack.a" \
            "$WORKSPACE/out/st-native/libzip.a" \
            "$WORKSPACE/out/st-native/libmanagement.a" \
            "$WORKSPACE/out/st-native/libnio.a" \
            "$WORKSPACE/out/st-native/libnet.a"
        zip -r "$WORKSPACE/out/release/ikvm-wasm-ST-bundle.zip" image
        zip -r "$WORKSPACE/out/release/ikvm-wasm-ST-bundle.zip" ikvm-tools
    )
    rm -rf "$WORKSPACE/out/st-native"

    rm -rf "$WORKSPACE/out/bundle-staging"

    log "Done! Release zips are in $WORKSPACE/out/release/"
    ls -lh "$WORKSPACE/out/release/"
fi
