#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR/lwjgl3}"
OUTPUT_FILE="${OUTPUT_FILE:-$SCRIPT_DIR/lwjgl3.patch}"

usage() {
    cat <<'EOF'
Usage: gen-lwjgl3-patch.sh [options]

Generates lwjgl3.patch from tools/native-deps/lwjgl3 while excluding generated files.

Options:
  --repo-dir=<path>     LWJGL git checkout (default: tools/native-deps/lwjgl3)
  --output=<path>       Patch output path (default: tools/native-deps/lwjgl3.patch)
  -h, --help            Show this help message.

Environment overrides:
  REPO_DIR
  OUTPUT_FILE
EOF
}

for arg in "$@"; do
    case "$arg" in
        --repo-dir=*) REPO_DIR="${arg#*=}" ;;
        --output=*) OUTPUT_FILE="${arg#*=}" ;;
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

if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: required command 'git' not found" >&2
    exit 1
fi

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "ERROR: LWJGL repository not found at: $REPO_DIR" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"

TMP_PATCH="$(mktemp "${TMPDIR:-/tmp}/lwjgl3-patch.XXXXXX")"
cleanup() {
    rm -f "$TMP_PATCH"
}
trap cleanup EXIT

append_untracked_patch() {
    local file_path="$1"
    local status=0

    (
        cd "$REPO_DIR"
        git diff --no-index -- /dev/null "$file_path"
    ) >> "$TMP_PATCH" || status=$?

    if [ "$status" -gt 1 ]; then
        return "$status"
    fi
}

declare -a PATHSPECS=(
    .
    ":(glob,exclude)**/generated/**"
    ":(glob,exclude)bin/**"
    ":(glob,exclude).idea/**"
)

declare -a UNTRACKED_FILES=()
while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    UNTRACKED_FILES+=("$file_path")
done < <(git -C "$REPO_DIR" ls-files --others --exclude-standard -- "${PATHSPECS[@]}")

git -C "$REPO_DIR" diff -- "${PATHSPECS[@]}" > "$TMP_PATCH"

for file_path in "${UNTRACKED_FILES[@]}"; do
    append_untracked_patch "$file_path"
done

mv "$TMP_PATCH" "$OUTPUT_FILE"

TRACKED_FILE_COUNT="$(git -C "$REPO_DIR" diff --name-only -- "${PATHSPECS[@]}" | wc -l | tr -d '[:space:]')"
FILE_COUNT="$((TRACKED_FILE_COUNT + ${#UNTRACKED_FILES[@]}))"
if [ "$FILE_COUNT" = "0" ]; then
    echo "[gen-lwjgl3-patch] No non-generated changes found. Wrote empty patch: $OUTPUT_FILE"
else
    echo "[gen-lwjgl3-patch] Wrote $OUTPUT_FILE with $FILE_COUNT file(s)."
fi
