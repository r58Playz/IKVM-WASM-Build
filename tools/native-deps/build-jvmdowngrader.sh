#!/usr/bin/env bash
# build-jvmdowngrader.sh - Builds patched JvmDowngrader jars for the IKVM WASM loader.
#
# Produces two jars (the same two ikvmcraft bundles under statics/):
#   jvmdowngrader.jar    - the CLI/core shadow jar (bundles java-api under META-INF/lib/)
#   jvmdg-java-api.jar   - the java-api shadow jar (the downgrade stubs; our patch lives here)
#
# The patch (jvmdowngrader.patch) fixes J_L_ScopedValue's static initializer, which stored a
# java.util.Random into a java.util.random.RandomGenerator-typed field. That interface only exists
# (and Random only implements it) on JDK 17+, so on IKVM's OpenJDK-8 runtime the store throws a
# message-less IncompatibleClassChangeError. Typing the field as java.util.Random (all we use is
# nextInt()) is Java-8-safe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR"

JVMDG_REPO="${JVMDG_REPO:-https://github.com/unimined/JvmDowngrader.git}"
# Pin to the exact commit the bundled jars were built from (1.3.6-20-gd007d16).
JVMDG_REF="${JVMDG_REF:-d007d167be065675cba949379854c4e003bae5d8}"
JVMDG_PATCH="${JVMDG_PATCH:-$SCRIPT_DIR/jvmdowngrader.patch}"

OUTPUT_DIR="${OUTPUT_DIR:-$WORKSPACE/out}"
KEEP_SRC="${KEEP_SRC:-true}"
# Directory scanned for a 17+ JDK when JAVA_HOME isn't already one (Gradle needs a modern JVM).
JVM_DIR="${JVM_DIR:-/usr/lib/jvm}"

usage() {
    cat <<'EOF'
Usage: build-jvmdowngrader.sh [options]

Options:
  --output-dir=<path>          Output directory (default: tools/native-deps/out).
  --jvmdg-ref=<ref>            JvmDowngrader git ref/commit (default: pinned commit).
  --jvmdg-patch=<path>         Patch to apply to the clone (default: jvmdowngrader.patch).
  --fresh                      Remove the existing clone and re-clone.
  -h, --help                   Show this help message.

Environment overrides:
  OUTPUT_DIR, JVMDG_REPO, JVMDG_REF, JVMDG_PATCH, JAVA_HOME, JVM_DIR

Notes:
  Gradle (9.x) needs a Java 17+ runtime. If JAVA_HOME isn't already 17+, the script picks a
  17+ JDK from JVM_DIR (default /usr/lib/jvm), preferring java-21 then java-17. The build then
  provisions the per-stub JDK toolchains (java 7..26) via the foojay resolver on first run.
EOF
}

FRESH="false"
for arg in "$@"; do
    case "$arg" in
        --output-dir=*) OUTPUT_DIR="${arg#*=}" ;;
        --jvmdg-ref=*) JVMDG_REF="${arg#*=}" ;;
        --jvmdg-patch=*) JVMDG_PATCH="${arg#*=}" ;;
        --fresh) FRESH="true" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument '$arg'" >&2; usage; exit 1 ;;
    esac
done

log() { echo "[build-jvmdowngrader] $*"; }

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

# Major Java version of a JDK home (e.g. 8, 17, 21). Prefers the `release` file, falls back to
# `java -version`. Handles both "1.8.0_x" (-> 8) and "21.0.x" (-> 21). Echoes 0 if undetermined.
jdk_major() {
    local home="$1" ver=""
    if [ -r "$home/release" ]; then
        ver="$(sed -n 's/^JAVA_VERSION="\([0-9._]*\)".*/\1/p' "$home/release" | head -1)"
    fi
    if [ -z "$ver" ] && [ -x "$home/bin/java" ]; then
        ver="$("$home/bin/java" -version 2>&1 | head -1 | grep -oE '[0-9]+([._][0-9]+)*' | head -1)"
    fi
    case "$ver" in
        1.*) ver="${ver#1.}"; echo "${ver%%[._]*}" ;;
        "")  echo 0 ;;
        *)   echo "${ver%%[._]*}" ;;
    esac
}

is_jdk17plus() {
    local m
    m="$(jdk_major "$1" 2>/dev/null)"
    [ "${m:-0}" -ge 17 ] 2>/dev/null
}

# Picks a Java 17+ home for running Gradle and exports JAVA_HOME/PATH. Honors an existing 17+
# JAVA_HOME; otherwise prefers java-21 then java-17 under JVM_DIR, else the lowest 17+ found
# (keeps us off bleeding-edge JDKs that a given Gradle may refuse to run on).
select_java_home() {
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ] && is_jdk17plus "$JAVA_HOME"; then
        log "JAVA_HOME already points at a 17+ JDK: $JAVA_HOME"
    else
        local chosen="" h m bestv=0
        for h in "$JVM_DIR/java-21-openjdk" "$JVM_DIR/java-17-openjdk"; do
            if [ -x "$h/bin/java" ] && is_jdk17plus "$h"; then chosen="$h"; break; fi
        done
        if [ -z "$chosen" ]; then
            for h in "$JVM_DIR"/*; do
                [ -x "$h/bin/java" ] || continue
                m="$(jdk_major "$h")"
                [ "${m:-0}" -ge 17 ] 2>/dev/null || continue
                if [ "$bestv" -eq 0 ] || [ "$m" -lt "$bestv" ]; then bestv="$m"; chosen="$h"; fi
            done
        fi
        if [ -z "$chosen" ]; then
            echo "ERROR: no Java 17+ JDK found (checked \$JAVA_HOME and $JVM_DIR/*). Gradle 9.x needs one." >&2
            echo "       Set JAVA_HOME to a JDK 17+ (or point JVM_DIR at where your JDKs live) and re-run." >&2
            exit 1
        fi
        JAVA_HOME="$chosen"
    fi
    export JAVA_HOME
    export PATH="$JAVA_HOME/bin:$PATH"
}

require_cmd git
require_cmd unzip

# /usr/bin/java may be Java 8; Gradle needs 17+. Detect and use a 17+ JDK for the build.
select_java_home
log "Running Gradle with JAVA_HOME=$JAVA_HOME (Java $(jdk_major "$JAVA_HOME"))"

SRC_DIR="$WORKSPACE/jvmdowngrader"

if [ "$FRESH" = "true" ]; then
    log "Removing existing clone (--fresh)"
    rm -rf "$SRC_DIR"
fi

if [ ! -d "$SRC_DIR/.git" ]; then
    log "Fetching JvmDowngrader @ $JVMDG_REF"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    git -C "$SRC_DIR" init -q
    git -C "$SRC_DIR" remote add origin "$JVMDG_REPO"
    # Fetch the exact commit (GitHub allows fetching a reachable SHA directly).
    if ! git -C "$SRC_DIR" fetch --depth 1 origin "$JVMDG_REF" >/dev/null 2>&1; then
        log "Direct SHA fetch failed; falling back to a full fetch."
        git -C "$SRC_DIR" fetch origin
    fi
    git -C "$SRC_DIR" checkout -q FETCH_HEAD
else
    log "JvmDowngrader source already present, skipping fetch (use --fresh to re-clone)."
fi

apply_patch_once "$SRC_DIR" "$JVMDG_PATCH" "$(basename "$JVMDG_PATCH")"

log "Building shadow jars with Gradle (this provisions toolchains on first run)"
(
    cd "$SRC_DIR"
    chmod +x ./gradlew
    ./gradlew --no-daemon --stacktrace :shadowJar :java-api:shadowJar
)

# CLI/core shadow jar: the one that embeds the java-api jar under META-INF/lib/java-api.jar.
CLI_JAR=""
for j in "$SRC_DIR"/build/libs/*.jar; do
    [ -f "$j" ] || continue
    if unzip -l "$j" 2>/dev/null | grep -q "META-INF/lib/java-api.jar"; then
        CLI_JAR="$j"
        break
    fi
done
if [ -z "$CLI_JAR" ]; then
    echo "ERROR: CLI shadow jar (containing META-INF/lib/java-api.jar) not found under $SRC_DIR/build/libs" >&2
    exit 1
fi

# java-api shadow jar (classifier "all"). The custom ShadowJar plugin writes it under
# build/tmp/shadowJar/ (not build/libs/); accept either, and if neither is present fall back to
# the identical copy the CLI jar embeds under META-INF/lib/java-api.jar.
JAVA_API_JAR=""
for j in \
    "$SRC_DIR"/java-api/build/libs/*-all.jar \
    "$SRC_DIR"/java-api/build/tmp/shadowJar/*-all.jar; do
    [ -f "$j" ] && JAVA_API_JAR="$j" && break
done
if [ -z "$JAVA_API_JAR" ]; then
    log "Standalone java-api shadow jar not found; extracting it from the CLI jar."
    API_EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jvmdg-api.XXXXXX")"
    unzip -o -q "$CLI_JAR" "META-INF/lib/java-api.jar" -d "$API_EXTRACT_DIR"
    JAVA_API_JAR="$API_EXTRACT_DIR/META-INF/lib/java-api.jar"
fi
if [ ! -f "$JAVA_API_JAR" ]; then
    echo "ERROR: could not locate or extract the java-api shadow jar" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cp "$CLI_JAR" "$OUTPUT_DIR/jvmdowngrader.jar"
cp "$JAVA_API_JAR" "$OUTPUT_DIR/jvmdg-java-api.jar"

log "Artifacts written to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR/jvmdowngrader.jar" "$OUTPUT_DIR/jvmdg-java-api.jar"
