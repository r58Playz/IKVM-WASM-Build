#!/usr/bin/env python3
"""
gen-static-libs.py

Generates a C source file that defines the jvm_static_libs[] registry used by
jvm_emscripten_dynlib.c.

Each library is specified as a FAKE_PATH:ARCHIVE pair:
  FAKE_PATH  - the exact string Java passes to JVM_LoadLibrary, e.g. "libjava.so"
  ARCHIVE    - the .a (or .o) file whose symbols should back that library

The script runs llvm-nm (or a user-specified nm tool) on every archive to
collect its globally-defined symbols, then generates:
  - one extern declaration per symbol
  - one static symbol table per library
  - the jvm_static_libs[] registry array

Because all addresses are resolved via forward declarations at compile time,
no dlsym() / -sMAIN_MODULE is required.

Usage
-----
  # Pairs as positional arguments:
  python3 gen-static-libs.py \\
      -o jvm_static_libs.c \\
      "libjava.so:/path/to/libjava_jni.a" \\
      "libzip.so:/path/to/libzip_jni.a"

  # Pairs from a file (one FAKE_PATH:ARCHIVE per line; # comments ignored):
  python3 gen-static-libs.py -o jvm_static_libs.c --list libs.txt

  # Mix both; specify a custom nm binary:
  python3 gen-static-libs.py --nm llvm-nm-18 --list libs.txt "libextra.so:/tmp/extra.a"

  # Write to stdout (omit -o):
  python3 gen-static-libs.py "libjava.so:/path/to/libjava.a"

List file format (--list)
--------------------------
  # comment
  libjava.so:/path/to/libjava_jni.a
  libzip.so:/path/to/libzip_jni.a

Build snippet (extends build-local.sh step 9)
----------------------------------------------
  python3 "$WORKSPACE/gen-static-libs.py" \\
      --nm llvm-nm \\
      -o "$WORKSPACE/out/native/tmp/jvm_static_libs.c" \\
      "libjava.so:$WORKSPACE/out/native/libjava_jni.a" \\
      "libzip.so:$WORKSPACE/out/native/libzip_jni.a"

  emcc -O2 -fPIC -fdeclspec -pthread \\
       -I"$LIBJVM_SRC" "${COMMON_DEFS[@]}" "${COMMON_INCLUDES[@]}" \\
       -c "$LIBJVM_SRC/jvm_emscripten_dynlib.c" \\
       -o "$WORKSPACE/out/native/tmp/jvm_emscripten_dynlib.o"

  emcc -O2 -fPIC -fdeclspec -pthread \\
       -I"$LIBJVM_SRC" \\
       -c "$WORKSPACE/out/native/tmp/jvm_static_libs.c" \\
       -o "$WORKSPACE/out/native/tmp/jvm_static_libs.o"

  emar rcs "$WORKSPACE/out/native/libjvm.a" \\
      jni.o jni_vargs.o jvm.o \\
      jvm_emscripten_dynlib.o jvm_static_libs.o
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
from collections import OrderedDict


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _is_valid_c_ident(name: str) -> bool:
    """Return True if name is a legal C identifier (letters, digits, _; no leading digit)."""
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", name))


def _c_str(s: str) -> str:
    """Return s escaped for use inside a C double-quoted string literal."""
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _find_nm(hint: str | None) -> str:
    """Locate an nm binary.  Tries the user hint first, then a list of candidates."""
    candidates = []
    if hint:
        candidates.append(hint)
    # Prefer versioned llvm-nm; fall back to plain nm
    for ver in ("", "-20", "-19", "-18", "-17"):
        candidates.append(f"llvm-nm{ver}")
    candidates.append("nm")

    for name in candidates:
        found = shutil.which(name)
        if found:
            return found

    raise FileNotFoundError(
        "No nm tool found.  Install llvm-nm or pass --nm /path/to/nm."
    )


# ---------------------------------------------------------------------------
# Symbol extraction
# ---------------------------------------------------------------------------


def _get_symbols(archive: str, nm_exe: str) -> list[str]:
    """
    Run `nm_exe --defined-only --extern-only archive` and return a list of
    globally-defined symbol names that are valid C identifiers.

    nm output format (both GNU nm and llvm-nm):
        [address]  TYPE  name
    Lines without a type column (archive-member headers, blank lines) are
    silently skipped.  Only uppercase TYPE letters are kept (lowercase = local
    scope), and U/u (undefined) are discarded even though --defined-only should
    already exclude them.
    """
    try:
        proc = subprocess.run(
            [nm_exe, "--defined-only", "--extern-only", archive],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        # Some old nm versions exit non-zero for empty archives; treat as empty.
        stderr = exc.stderr.strip()
        if "no symbols" in stderr.lower() or exc.returncode == 1:
            return []
        raise RuntimeError(
            f"nm failed on {archive!r} (exit {exc.returncode}):\n{exc.stderr}"
        ) from exc

    symbols: list[str] = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line or line.endswith(":"):
            # blank line or archive-member header ("foo.a[obj.o]:")
            continue

        parts = line.split()
        # Standard format:  "address  TYPE  name"   (3 tokens)
        # Undefined format:  "         TYPE  name"   may collapse to 2 tokens
        if len(parts) == 3:
            _, sym_type, sym_name = parts
        elif len(parts) == 2:
            sym_type, sym_name = parts
        else:
            continue

        # Keep only globally-defined function symbols (type 'T' = text/code)
        if sym_type != "T":
            continue

        if _is_valid_c_ident(sym_name):
            symbols.append(sym_name)

    return symbols


# ---------------------------------------------------------------------------
# Pair parsing
# ---------------------------------------------------------------------------


def _parse_pair(token: str) -> tuple[str, str]:
    """
    Parse a "fake_path:archive" token.

    The split is on the LAST colon so that Windows absolute paths
    ("C:\\foo\\bar.a") and Unix paths with multiple colons are handled.
    Raises ValueError for malformed input.
    """
    idx = token.rfind(":")
    if idx <= 0:
        raise ValueError(f"Invalid library spec {token!r}: expected FAKE_PATH:ARCHIVE")
    return token[:idx], token[idx + 1 :]


def _read_list_file(path: str) -> list[str]:
    """Read FAKE_PATH:ARCHIVE tokens from a file, one per line."""
    tokens: list[str] = []
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            tokens.append(line)
    return tokens


# ---------------------------------------------------------------------------
# Code generation
# ---------------------------------------------------------------------------

_FILE_HEADER = """\
/* Auto-generated by gen-static-libs.py — DO NOT EDIT.
 *
 * Regenerate with:
 *   python3 gen-static-libs.py {args_repr}
 *
 * Defines jvm_static_libs[], the registry used by jvm_emscripten_dynlib.c to
 * implement JVM_LoadLibrary / JVM_FindLibraryEntry without dlsym() or
 * -sMAIN_MODULE.  Each per-library symbol table was produced by running:
 *   {nm_exe} --defined-only --extern-only <archive>
 *
 * To add a library, re-run gen-static-libs.py with the new FAKE_PATH:ARCHIVE
 * pair.  To add symbols to an existing library, recompile the archive and
 * re-run the script.
 */

"""


def generate(
    libraries: list[tuple[str, list[str]]],  # [(fake_path, [sym, ...]), ...]
    args_repr: str,
    nm_exe: str,
) -> str:
    out: list[str] = []

    with open("ikvm/src/libjvm/jvm_emscripten_dynlib.h", "r") as file:
        jvm_emscripten_dynlib = file.read()

    out.append(_FILE_HEADER.format(args_repr=args_repr, nm_exe=nm_exe))
    out.append("#include <stddef.h>  /* NULL */\n")
    out.append("\n\n")
    out.append(jvm_emscripten_dynlib)
    out.append("\n\n")

    # --- Collect all symbols (deduped across libraries for the extern block) --
    all_syms: dict[str, None] = {}  # ordered set
    for _, syms in libraries:
        for s in syms:
            all_syms[s] = None

    if all_syms:
        out.append(
            "/* Forward declarations of every symbol referenced below.\n"
            " * Using empty parameter lists (K&R style) so the declarations\n"
            " * are compatible with any actual JNI signature without needing\n"
            " * prototypes.  The cast to void* is done in the tables below. */\n"
        )
        # Suppress the pedantic function-pointer → void* warning emitted by
        # -Wpedantic / -Wstrict-prototypes; the cast is intentional here and
        # is the same pattern used by POSIX dlsym().
        out.append("#pragma clang diagnostic push\n")
        out.append('#pragma clang diagnostic ignored "-Wpedantic"\n')
        out.append('#pragma clang diagnostic ignored "-Wstrict-prototypes"\n\n')
        for sym in all_syms:
            out.append(f"extern void {sym}();\n")
        out.append("\n")

    # --- Per-library symbol tables -------------------------------------------
    for fake_path, syms in libraries:
        # Build a C-safe identifier for the table variable name from the path.
        # Strip leading path components and replace non-ident chars with _.
        basename = os.path.basename(fake_path)
        table_id = re.sub(r"[^A-Za-z0-9_]", "_", basename)

        if syms:
            out.append(
                f'/* Symbol table for "{_c_str(fake_path)}" '
                f"({len(syms)} symbol{'s' if len(syms) != 1 else ''}) */\n"
            )
            out.append(f"static const jvm_symbol_entry_t _syms_{table_id}[] = {{\n")
            for sym in syms:
                # If the symbol follows the __lib<NAME>_JNI_OnLoad pattern,
                # expose it under the canonical "JNI_OnLoad" key so that
                # JVM_FindLibraryEntry("JNI_OnLoad") still works per-library.
                if re.match(r"^__[A-Za-z0-9_]+_JNI_OnLoad$", sym):
                    key = "JNI_OnLoad"
                else:
                    key = sym
                out.append(f'    {{ "{_c_str(key)}", (void*){sym} }},\n')
            out.append("    { NULL, NULL }  /* sentinel */\n")
            out.append("};\n\n")
        else:
            out.append(
                f'/* No symbols found for "{_c_str(fake_path)}" */\n'
                f"static const jvm_symbol_entry_t _syms_{table_id}[] = {{\n"
                "    { NULL, NULL }  /* sentinel */\n"
                "};\n\n"
            )

    if all_syms:
        out.append("#pragma clang diagnostic pop\n\n")

    # --- Main registry --------------------------------------------------------
    out.append(
        "/* Registry of statically-linked libraries.\n"
        " * JVM_LoadLibrary returns &jvm_static_libs[i] when path matches;\n"
        " * JVM_FindLibraryEntry then searches that entry's symbol table. */\n"
    )
    out.append("const jvm_static_lib_entry_t jvm_static_libs[] = {\n")
    for fake_path, _ in libraries:
        basename = os.path.basename(fake_path)
        table_id = re.sub(r"[^A-Za-z0-9_]", "_", basename)
        out.append(f'    {{ "{_c_str(fake_path)}", _syms_{table_id} }},\n')
    out.append("    { NULL, NULL }  /* sentinel */\n")
    out.append("};\n\n")

    out.append(f"const int jvm_static_libs_count = {len(libraries)};\n")

    return "".join(out)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Generate jvm_static_libs.c for the Emscripten JVM_LoadLibrary "
            "static registry."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "pairs",
        nargs="*",
        metavar="FAKE_PATH:ARCHIVE",
        help=(
            "Library spec: FAKE_PATH is the path Java passes to "
            "JVM_LoadLibrary; ARCHIVE is the .a/.o to extract symbols from."
        ),
    )
    parser.add_argument(
        "-o",
        "--output",
        default="-",
        metavar="FILE",
        help="Output .c file path.  Use '-' (default) to write to stdout.",
    )
    parser.add_argument(
        "--list",
        metavar="FILE",
        help=(
            "Text file with additional FAKE_PATH:ARCHIVE specs, one per line. "
            "Blank lines and lines starting with # are ignored."
        ),
    )
    parser.add_argument(
        "--nm",
        metavar="TOOL",
        default=None,
        help=(
            "nm binary to use (default: auto-detect llvm-nm or nm on PATH). "
            "E.g. --nm llvm-nm-18"
        ),
    )

    args = parser.parse_args()

    # Collect all raw pair tokens
    raw_tokens: list[str] = list(args.pairs)
    if args.list:
        try:
            raw_tokens.extend(_read_list_file(args.list))
        except OSError as exc:
            print(f"error: cannot read --list file: {exc}", file=sys.stderr)
            return 1

    if not raw_tokens:
        print(
            "warning: no library specs given — the registry will be empty.",
            file=sys.stderr,
        )

    # Parse all tokens into (fake_path, archive) pairs
    pairs: list[tuple[str, str]] = []
    for token in raw_tokens:
        try:
            pairs.append(_parse_pair(token))
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1

    # Deduplicate fake paths (keep first occurrence)
    seen_paths: set[str] = set()
    unique_pairs: list[tuple[str, str]] = []
    for fake_path, archive in pairs:
        if fake_path not in seen_paths:
            seen_paths.add(fake_path)
            unique_pairs.append((fake_path, archive))
        else:
            print(
                f"warning: duplicate fake path {fake_path!r} ignored",
                file=sys.stderr,
            )
    pairs = unique_pairs

    # Locate nm
    try:
        nm_exe = _find_nm(args.nm)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"Using nm: {nm_exe}", file=sys.stderr)

    # Extract symbols from each archive
    libraries: list[tuple[str, list[str]]] = []
    total_syms = 0
    for fake_path, archive in pairs:
        if not os.path.exists(archive):
            print(
                f"error: archive not found: {archive!r} (for {fake_path!r})",
                file=sys.stderr,
            )
            return 1
        print(f"  Scanning {archive} ...", file=sys.stderr)
        try:
            syms = _get_symbols(archive, nm_exe)
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1

        # Deduplicate symbols within a single library (should be rare)
        seen: set[str] = set()
        unique_syms = [s for s in syms if not (s in seen or seen.add(s))]  # type: ignore[func-returns-value]

        print(
            f"    {fake_path}: {len(unique_syms)} symbol"
            f"{'s' if len(unique_syms) != 1 else ''}",
            file=sys.stderr,
        )
        libraries.append((fake_path, unique_syms))
        total_syms += len(unique_syms)

    # Build a compact args_repr for the file header comment
    repr_parts: list[str] = []
    if args.nm:
        repr_parts.append(f"--nm {args.nm}")
    if args.output != "-":
        repr_parts.append(f"-o {args.output}")
    if args.list:
        repr_parts.append(f"--list {args.list}")
    repr_parts.extend(args.pairs)
    args_repr = " ".join(repr_parts) if repr_parts else "(no arguments)"

    source = generate(libraries, args_repr, nm_exe)

    if args.output == "-":
        sys.stdout.write(source)
    else:
        out_dir = os.path.dirname(args.output)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(args.output, "w") as fh:
            fh.write(source)
        print(
            f"Generated: {args.output}  "
            f"({len(libraries)} librar{'y' if len(libraries) == 1 else 'ies'}, "
            f"{total_syms} symbol{'s' if total_syms != 1 else ''})",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
