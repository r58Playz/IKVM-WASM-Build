#!/usr/bin/env bash
# build-runtime-only.sh - rebuilds IKVM.Runtime.dll alone (no class library, no natives) and refreshes it in
# out/managed and the release bundle. For iterating on runtime changes; the full build is build-ikvm-local.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
IKVM_DIR="${IKVM_DIR:-$SCRIPT_DIR/ikvm}"
VERSION="${IKVM_VERSION:-8.14.0}"
export NUGET_PACKAGES="${NUGET_PACKAGES:-$REPO_ROOT/.nuget/packages}"
cd "$IKVM_DIR"
dotnet msbuild /m /nr:false /restore /v:m \
	/p:Configuration=Release /p:Version="$VERSION" /p:AssemblyVersion="$VERSION.0" /p:FileVersion="$VERSION.0" \
	/p:InformationalVersion="$VERSION" /p:PackageVersion="$VERSION" /p:ContinuousIntegrationBuild=true \
	/p:EnabledRuntimes=linux-x64 /p:EnabledImageRuntimes=linux-x64 /p:EnabledImageBinRuntimes=linux-x64 \
	/p:EnabledToolRuntimes=linux-x64 /p:RuntimeIdentifier=linux-x64 /p:BuildNet6JreImages=false \
	src/IKVM.Runtime/IKVM.Runtime.csproj
BUILT="$IKVM_DIR/artifacts/jdk25/bin/IKVM.Runtime/Release/net8.0/linux-x64/IKVM.Runtime.dll"
OUT="$SCRIPT_DIR/out"
cp "$BUILT" "$OUT/managed/IKVM.Runtime.dll"
(cd "$OUT/managed" && zip -q "$OUT/release/ikvm-wasm-bundle.zip" IKVM.Runtime.dll)
echo "[runtime-only] $(ls -la "$OUT/managed/IKVM.Runtime.dll")"
