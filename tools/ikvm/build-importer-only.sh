#!/usr/bin/env bash
# build-importer-only.sh - rebuilds IKVM.Tools.Importer.dll (ikvmc's compiler: IKVM.Runtime's sources built for the
# importer) and refreshes it in out/managed/ikvm-tools and the release bundle. The runtime's counterpart is
# build-runtime-only.sh; a compiler fix in IKVM.Runtime usually needs both.
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
	src/IKVM.Tools.Importer/IKVM.Tools.Importer.csproj
BUILT="$(ls -t "$IKVM_DIR"/artifacts/jdk25/bin/IKVM.Tools.Importer/Release/*/linux-x64/IKVM.Tools.Importer.dll 2>/dev/null | head -1)"
[ -n "$BUILT" ] || BUILT="$(ls -t "$IKVM_DIR"/artifacts/jdk25/bin/IKVM.Tools.Importer/Release/*/IKVM.Tools.Importer.dll | head -1)"
OUT="$SCRIPT_DIR/out"
cp "$BUILT" "$OUT/managed/ikvm-tools/IKVM.Tools.Importer.dll"
(cd "$OUT/managed" && zip -q "$OUT/release/ikvm-wasm-bundle.zip" ikvm-tools/IKVM.Tools.Importer.dll)
echo "[importer-only] $BUILT -> $(ls -la "$OUT/managed/ikvm-tools/IKVM.Tools.Importer.dll")"
