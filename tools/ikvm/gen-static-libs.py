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

    # Manually add symbols to a library:
    python3 gen-static-libs.py --add-symbol "libjava.so:my_custom_func" \\
        --add-symbol "libjava.so:another_func" "libjava.so:/path/to/libjava.a"

    # Bulk-add symbols from a file (one symbol per line, # comments allowed):
    python3 gen-static-libs.py --symbol-list "openal:/path/to/openal-symbols.txt" \\
        "openal:/path/to/openal-stubs.a"

    # Add alternate library names that resolve to the same archive:
    python3 gen-static-libs.py --add-alias "libjava.so:libjava" \\
        --add-alias "libjava.so:java" "libjava.so:/path/to/libjava.a"

    # Rename symbol keys in a library's lookup table:
    python3 gen-static-libs.py --rename-symbol "libjava.so:old_name:new_name" \\
        "libjava.so:/path/to/libjava.a"

   # Combine everything:
   python3 gen-static-libs.py --nm llvm-nm-18 --list libs.txt \\
       --add-symbol "libjava.so:extra_symbol" \\
       --rename-symbol "libjava.so:old_name:new_name" -o output.c

List file format (--list)
--------------------------
   # comment
   libjava.so:/path/to/libjava_jni.a
   libzip.so:/path/to/libzip_jni.a

Add symbol format (--add-symbol)
--------------------------------
    --add-symbol FAKE_PATH:SYMBOL
    --add-symbol FAKE_PATH:DECLARATION

    Manually add a symbol to a library's symbol table. Can be specified multiple
    times. Merged with symbols extracted from archives.

    SYMBOL is a bare C identifier (e.g. "myFunc"); the generated extern uses
    `extern void myFunc();` (K&R style, empty parameter list).

    DECLARATION is a full C function declaration containing `(` (e.g.
    "void* alcOpenDevice(const char* devicename)"); it is emitted verbatim as
    `extern <DECLARATION>;`. This matters in wasm: indirect calls
    (`call_indirect`) dispatch on the signature the function was declared
    with, so a K&R extern for a function called through a pointer (the
    `(void*)sym` in the per-library tables here) traps when the table entry
    was registered with the real signature.

Symbol list format (--symbol-list)
----------------------------------
    --symbol-list FAKE_PATH:FILE

    Bulk-add symbols from a text file (one entry per line; blank lines and
    lines starting with # are ignored). Each entry is either a bare identifier
    or a full C function declaration, exactly as in --add-symbol. Equivalent
    to repeating --add-symbol for every entry. Useful for JS-backed emscripten
    libraries (e.g. -lopenal) where there is no .a archive to nm-scan: pair a
    tiny stub archive that provides any missing real symbols with a
    --symbol-list that names every function the JS lib exports — preferably
    with signatures, so the wasm function-table sigs match.

Library alias format (--add-alias)
----------------------------------
    --add-alias FAKE_PATH:ALIAS

    Add an alternate library name to the registry. Aliases are emitted as extra
    rows in jvm_static_libs[] that point at the same symbol table as the canonical
    FAKE_PATH entry. Can be specified multiple times.

Rename symbol format (--rename-symbol)
--------------------------------------
   --rename-symbol FAKE_PATH:OLD_SYMBOL:NEW_SYMBOL

   Rename the lookup key for a symbol in a library's table without changing the
   underlying C symbol reference. Can be specified multiple times.

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
import tempfile


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


def _find_tool(hint: str | None, candidates: list[str]) -> str | None:
    """Locate one of several tool binaries.  Returns None if none are found."""
    if hint:
        found = shutil.which(hint)
        if found:
            return found
    for name in candidates:
        found = shutil.which(name)
        if found:
            return found
    return None


# ---------------------------------------------------------------------------
# WASM signature extraction
# ---------------------------------------------------------------------------


# Map WASM value types to portable C scalar types. We pick types whose wasm32
# ABI lowering matches the type byte exactly. The function signature emitted
# into statics.c is consumed by clang/wasm-ld; what matters for call_indirect
# is the wasm-level shape, not the C-level type name.
_WASM_TYPE_TO_C: dict[str, str] = {
    "i32": "int",
    "i64": "long long",
    "f32": "float",
    "f64": "double",
}


def _wasm_decl(ret: str, params: list[str], name: str) -> str | None:
    """Build a C declaration from a parsed WASM signature.  Returns None if any
    type is unsupported (vector, reference types, etc.)."""
    c_ret = "void" if ret in ("", "nil") else _WASM_TYPE_TO_C.get(ret)
    if c_ret is None:
        return None
    if not params:
        c_params = "void"
    else:
        c_params_list = []
        for i, p in enumerate(params):
            cp = _WASM_TYPE_TO_C.get(p)
            if cp is None:
                return None
            c_params_list.append(f"{cp} a{i}")
        c_params = ", ".join(c_params_list)
    return f"{c_ret} {name}({c_params})"


# Match a Type[N] entry: "type[N] (i32, i32) -> i32" or "type[N] () -> nil"
_TYPE_RE = re.compile(
    r"\s*-\s+type\[(\d+)\]\s+\(([^)]*)\)\s+->\s+(\S+)"
)
# Match a defined Function[N] entry: "func[X] sig=N <name>"
_FUNC_RE = re.compile(
    r"\s*-\s+func\[(\d+)\]\s+sig=(\d+)\s+<([^>]+)>"
)


def _parse_wasm_objdump(text: str) -> dict[str, str]:
    """Parse `wasm-objdump -x` output for one module. Returns {symbol: c_decl}
    for every locally-defined function whose signature we can lower to C."""
    types: dict[int, tuple[list[str], str]] = {}
    funcs: list[tuple[int, str]] = []  # (sig_idx, name)
    section: str | None = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line:
            continue
        # Section markers look like "Type[N]:", "Import[N]:", "Function[N]:" etc.
        if re.match(r"^[A-Za-z]+\[\d+\]:$", line):
            section = line.split("[")[0]
            continue
        if section == "Type":
            m = _TYPE_RE.match(line)
            if m:
                idx = int(m.group(1))
                params_str = m.group(2).strip()
                params = [p.strip() for p in params_str.split(",")] if params_str else []
                ret = m.group(3).strip()
                types[idx] = (params, ret)
        elif section == "Function":
            m = _FUNC_RE.match(line)
            if m:
                sig_idx = int(m.group(2))
                name = m.group(3).strip()
                # Skip imports of the form "env.foo" — Function[] section in a
                # relocatable .o lists only locally-defined functions, but defend
                # against unexpected formats from older toolchains.
                if "." in name and name.startswith("env."):
                    continue
                funcs.append((sig_idx, name))

    out: dict[str, str] = {}
    for sig_idx, name in funcs:
        sig = types.get(sig_idx)
        if not sig:
            continue
        params, ret = sig
        decl = _wasm_decl(ret, params, name)
        if decl is not None:
            out[name] = decl
    return out


def _get_wasm_signatures(
    archive: str,
    objdump_exe: str,
    ar_exe: str,
) -> dict[str, str]:
    """Extract C declarations for every locally-defined function in archive.

    Extracts each .o member of the archive (via llvm-ar/ar) into a tempdir,
    runs wasm-objdump -x on each, and aggregates parsed signatures.
    """
    sigs: dict[str, str] = {}
    with tempfile.TemporaryDirectory(prefix="genstaticlibs_wasm_") as tmp:
        # List members; output one per line.
        try:
            listing = subprocess.run(
                [ar_exe, "t", archive],
                capture_output=True,
                text=True,
                check=True,
            ).stdout
        except subprocess.CalledProcessError as exc:
            print(
                f"warn: cannot list {archive!r} with {ar_exe!r} "
                f"(exit {exc.returncode}); skipping WASM signature extraction",
                file=sys.stderr,
            )
            return sigs

        members = [m.strip() for m in listing.splitlines() if m.strip()]
        # Extract everything in one shot; members are written into cwd
        if members:
            try:
                subprocess.run(
                    [ar_exe, "x", os.path.abspath(archive)],
                    cwd=tmp,
                    capture_output=True,
                    text=True,
                    check=True,
                )
            except subprocess.CalledProcessError as exc:
                print(
                    f"warn: cannot extract {archive!r}: {exc.stderr}",
                    file=sys.stderr,
                )
                return sigs

        for member in members:
            obj_path = os.path.join(tmp, member)
            if not os.path.isfile(obj_path):
                continue
            try:
                dump = subprocess.run(
                    [objdump_exe, "-x", obj_path],
                    capture_output=True,
                    text=True,
                    check=True,
                ).stdout
            except subprocess.CalledProcessError:
                # Non-WASM members in a mixed archive (rare) — skip them.
                continue
            for name, decl in _parse_wasm_objdump(dump).items():
                # First definition wins; one .a shouldn't redefine the same
                # symbol but tolerate gracefully if it does.
                sigs.setdefault(name, decl)
    return sigs


# ---------------------------------------------------------------------------
# Symbol extraction
# ---------------------------------------------------------------------------


def _get_symbols(archive: str, nm_exe: str) -> list[tuple[str, str]]:
    """
    Run `nm_exe --defined-only --extern-only archive` and return a list of
    `(symbol_name, symbol_type)` pairs for globally-defined symbols that are
    valid C identifiers.

    nm output format (both GNU nm and llvm-nm):
        [address]  TYPE  name
    Lines without a type column (archive-member headers, blank lines) are
    silently skipped.  Only a subset of uppercase TYPE letters is kept:
      - T: function symbols
      - B/D/G/R/S/C/V: globally-defined data symbols (V = weak object)
    Lowercase symbols (local scope), U/u (undefined), and ambiguous weak
    symbols (W) are discarded.
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

    symbols: list[tuple[str, str]] = []
    allowed_types = {"T", "B", "D", "G", "R", "S", "C", "V"}
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

        if sym_type not in allowed_types:
            continue

        if _is_valid_c_ident(sym_name):
            symbols.append((sym_name, sym_type))

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


def _parse_rename_spec(token: str) -> tuple[str, str, str]:
    """Parse a 'fake_path:old_symbol:new_symbol' token."""
    parts = token.rsplit(":", 2)
    if len(parts) != 3 or not parts[0] or not parts[1] or not parts[2]:
        raise ValueError(
            f"Invalid rename spec {token!r}: expected FAKE_PATH:OLD_SYMBOL:NEW_SYMBOL"
        )
    return parts[0], parts[1], parts[2]


def _parse_alias_spec(token: str) -> tuple[str, str]:
    """Parse a 'fake_path:alias' token."""
    idx = token.rfind(":")
    if idx <= 0 or idx == len(token) - 1:
        raise ValueError(f"Invalid alias spec {token!r}: expected FAKE_PATH:ALIAS")
    return token[:idx], token[idx + 1 :]


def _parse_symbol_entry(entry: str) -> tuple[str, str | None]:
    """
    Parse a manual-symbol entry (used by --add-symbol payloads and --symbol-list
    file lines).

    Two forms are accepted:

      1. Bare identifier:    "alcOpenDevice"
         → ("alcOpenDevice", None)
         The generated extern falls back to `extern void <sym>();` (K&R style).

      2. Full C declaration: "void* alcOpenDevice(const char* devicename)"
         → ("alcOpenDevice", "void* alcOpenDevice(const char* devicename)")
         The declaration is emitted verbatim as `extern <decl>;`, so the
         wasm function-table signature matches the linked implementation.

    The symbol name in form (2) is the identifier immediately preceding `(`.
    """
    if "(" not in entry:
        return entry, None
    decl = entry.rstrip(";").rstrip()
    match = re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", decl)
    if not match:
        raise ValueError(f"could not extract symbol name from declaration {entry!r}")
    return match.group(1), decl


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
    libraries: list[tuple[str, list[tuple[str, str]]]],  # [(fake_path, [(sym, type), ...]), ...]
    library_aliases: dict[str, list[str]],
    rename_symbols: dict[str, dict[str, str]],
    signatures: dict[str, str],
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
    all_syms: dict[str, str] = {}  # ordered map: symbol -> type
    for _, syms in libraries:
        for s, sym_type in syms:
            if s not in all_syms:
                all_syms[s] = sym_type

    if all_syms:
        out.append(
            "/* Forward declarations of every symbol referenced below.\n"
            " * Function symbols default to empty parameter lists (K&R style)\n"
            " * for compatibility with direct JNI calls, but a --symbol-list\n"
            " * or --add-symbol entry can supply a full C declaration, which\n"
            " * is emitted verbatim. That matters in wasm: indirect calls\n"
            " * (call_indirect) dispatch on the signature the function was\n"
            " * declared with, so a K&R extern for a function reached through\n"
            " * the (void*) entries below traps when the table entry was\n"
            " * registered with the real signature.\n"
            " * The cast to void* is done in the tables below. */\n"
        )
        # Suppress the pedantic function-pointer → void* warning emitted by
        # -Wpedantic / -Wstrict-prototypes; the cast is intentional here and
        # is the same pattern used by POSIX dlsym().
        out.append("#pragma clang diagnostic push\n")
        out.append('#pragma clang diagnostic ignored "-Wpedantic"\n')
        out.append('#pragma clang diagnostic ignored "-Wstrict-prototypes"\n\n')
        for sym, sym_type in all_syms.items():
            if sym in signatures:
                out.append(f"extern {signatures[sym]};\n")
            elif sym_type == "T":
                out.append(f"extern void {sym}();\n")
            else:
                out.append(f"extern char {sym};\n")
        out.append("\n")

    # --- Per-library symbol tables -------------------------------------------
    registry_entries: list[tuple[str, str]] = []
    seen_registry_names: set[str] = set()

    for fake_path, syms in libraries:
        # Build a C-safe identifier for the table variable name from the path.
        # Strip leading path components and replace non-ident chars with _.
        basename = os.path.basename(fake_path)
        table_id = re.sub(r"[^A-Za-z0-9_]", "_", basename)

        def add_registry_name(name: str) -> None:
            if name in seen_registry_names:
                print(
                    f"warning: duplicate registry name {name!r} ignored",
                    file=sys.stderr,
                )
                return
            seen_registry_names.add(name)
            registry_entries.append((name, table_id))

        if syms:
            renames = rename_symbols.get(fake_path, {})
            out.append(
                f'/* Symbol table for "{_c_str(fake_path)}" '
                f"({len(syms)} symbol{'s' if len(syms) != 1 else ''}) */\n"
            )
            out.append(f"static const jvm_symbol_entry_t _syms_{table_id}[] = {{\n")
            for sym, sym_type in syms:
                # Renames override the built-in JNI_OnLoad/JNI_OnUnload aliasing.
                if sym in renames:
                    key = renames[sym]
                # If the symbol follows the __lib<NAME>_JNI_OnLoad pattern,
                # expose it under the canonical "JNI_OnLoad" key so that
                # JVM_FindLibraryEntry("JNI_OnLoad") still works per-library.
                elif re.match(r"^__[A-Za-z0-9_]+_JNI_OnLoad$", sym):
                    key = "JNI_OnLoad"
                elif re.match(r"^__[A-Za-z0-9_]+_JNI_OnUnload$", sym):
                    key = "JNI_OnUnload"
                else:
                    key = sym
                if sym_type == "T":
                    out.append(f'    {{ "{_c_str(key)}", (void*){sym} }},\n')
                else:
                    out.append(f'    {{ "{_c_str(key)}", (void*)&{sym} }},\n')
            out.append("    { NULL, NULL }  /* sentinel */\n")
            out.append("};\n\n")
        else:
            out.append(
                f'/* No symbols found for "{_c_str(fake_path)}" */\n'
                f"static const jvm_symbol_entry_t _syms_{table_id}[] = {{\n"
                "    { NULL, NULL }  /* sentinel */\n"
                "};\n\n"
            )

        add_registry_name(fake_path)
        for alias in library_aliases.get(fake_path, []):
            add_registry_name(alias)

    if all_syms:
        out.append("#pragma clang diagnostic pop\n\n")

    # --- Main registry --------------------------------------------------------
    out.append(
        "/* Registry of statically-linked libraries.\n"
        " * JVM_LoadLibrary returns &jvm_static_libs[i] when path matches;\n"
        " * JVM_FindLibraryEntry then searches that entry's symbol table. */\n"
    )
    out.append("const jvm_static_lib_entry_t jvm_static_libs[] = {\n")
    for name, table_id in registry_entries:
        out.append(f'    {{ "{_c_str(name)}", _syms_{table_id} }},\n')
    out.append("    { NULL, NULL }  /* sentinel */\n")
    out.append("};\n\n")

    out.append(f"const int jvm_static_libs_count = {len(registry_entries)};\n")

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
    parser.add_argument(
        "--wasm-objdump",
        metavar="TOOL",
        default=None,
        help=(
            "wasm-objdump (wabt) or llvm-objdump binary used to extract per-"
            "function WASM signatures from each archive. When found, signatures "
            "are emitted as proper C prototypes instead of K&R `extern void f();` "
            "— which is required for call_indirect to dispatch correctly. Pass "
            "--no-wasm-objdump to disable. Default: auto-detect."
        ),
    )
    parser.add_argument(
        "--no-wasm-objdump",
        action="store_true",
        help="Skip WASM signature extraction even if a tool is available.",
    )
    parser.add_argument(
        "--ar",
        metavar="TOOL",
        default=None,
        help="ar binary used to extract .o members from archives for WASM "
             "signature extraction. Default: auto-detect llvm-ar or ar.",
    )
    parser.add_argument(
        "--add-symbol",
        action="append",
        dest="add_symbols",
        metavar="FAKE_PATH:SYMBOL_OR_DECL",
        default=[],
        help=(
            "Manually add a symbol to a library's symbol table. Format: "
            "FAKE_PATH:SYMBOL or FAKE_PATH:DECLARATION. A bare identifier emits "
            "`extern void <sym>();` (K&R style); a full C declaration "
            "(containing `(`) is emitted verbatim as `extern <decl>;` so the "
            "wasm function-table signature matches the real implementation. "
            "Can be specified multiple times. Merged with symbols extracted "
            "from archives."
        ),
    )
    parser.add_argument(
        "--symbol-list",
        action="append",
        dest="symbol_lists",
        metavar="FAKE_PATH:FILE",
        default=[],
        help=(
            "Bulk-add symbols from a file. Format: FAKE_PATH:FILE. Each line "
            "is either a bare identifier or a full C function declaration "
            "(see --add-symbol). Blank lines and # comments are ignored. "
            "Equivalent to repeating --add-symbol for every entry. Can be "
            "specified multiple times."
        ),
    )
    parser.add_argument(
        "--add-alias",
        action="append",
        dest="library_aliases",
        metavar="FAKE_PATH:ALIAS",
        default=[],
        help=(
            "Add an alternate library name to the registry. Can be specified "
            "multiple times. Aliases point at the same symbol table as the "
            "canonical FAKE_PATH entry."
        ),
    )
    parser.add_argument(
        "--rename-symbol",
        action="append",
        dest="rename_symbols",
        metavar="FAKE_PATH:OLD_SYMBOL:NEW_SYMBOL",
        default=[],
        help=(
            "Rename a symbol key in a library's table. Format: FAKE_PATH:OLD_SYMBOL:NEW_SYMBOL. "
            "Can be specified multiple times. Renames apply after extraction and before emission."
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

    # Parse manually added symbols. Each value maps symbol -> signature (or
    # None for "no signature, use K&R extern decl"). Signatures matter for
    # wasm indirect calls — see _parse_symbol_entry.
    manual_symbols: dict[str, dict[str, str | None]] = {}
    for spec in args.add_symbols:
        try:
            fake_path, payload = _parse_pair(spec)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        try:
            symbol, signature = _parse_symbol_entry(payload)
        except ValueError as exc:
            print(f"error: --add-symbol {spec!r}: {exc}", file=sys.stderr)
            return 1
        if not _is_valid_c_ident(symbol):
            print(
                f"error: invalid symbol name {symbol!r}: must be a valid C identifier",
                file=sys.stderr,
            )
            return 1
        manual_symbols.setdefault(fake_path, {})[symbol] = signature

    # Parse --symbol-list files (bulk equivalent of --add-symbol)
    for spec in args.symbol_lists:
        try:
            fake_path, list_path = _parse_pair(spec)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        try:
            with open(list_path) as fh:
                for lineno, raw in enumerate(fh, 1):
                    line = raw.strip()
                    if not line or line.startswith("#"):
                        continue
                    try:
                        symbol, signature = _parse_symbol_entry(line)
                    except ValueError as exc:
                        print(
                            f"error: {list_path}:{lineno}: {exc}",
                            file=sys.stderr,
                        )
                        return 1
                    if not _is_valid_c_ident(symbol):
                        print(
                            f"error: invalid symbol {symbol!r} in "
                            f"{list_path}:{lineno}: must be a valid C identifier",
                            file=sys.stderr,
                        )
                        return 1
                    manual_symbols.setdefault(fake_path, {})[symbol] = signature
        except OSError as exc:
            print(
                f"error: cannot read --symbol-list file {list_path!r}: {exc}",
                file=sys.stderr,
            )
            return 1

    # Parse library aliases
    library_aliases: dict[str, list[str]] = {}
    for spec in args.library_aliases:
        try:
            fake_path, alias = _parse_alias_spec(spec)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        if not alias:
            print(
                "error: invalid alias name '': aliases must be non-empty",
                file=sys.stderr,
            )
            return 1
        library_aliases.setdefault(fake_path, []).append(alias)

    # Parse rename mappings
    rename_symbols: dict[str, dict[str, str]] = {}
    for spec in args.rename_symbols:
        try:
            fake_path, old_symbol, new_symbol = _parse_rename_spec(spec)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        if not _is_valid_c_ident(old_symbol):
            print(
                f"error: invalid old symbol name {old_symbol!r}: must be a valid C identifier",
                file=sys.stderr,
            )
            return 1
        if not _is_valid_c_ident(new_symbol):
            print(
                f"error: invalid new symbol name {new_symbol!r}: must be a valid C identifier",
                file=sys.stderr,
            )
            return 1
        rename_symbols.setdefault(fake_path, {})[old_symbol] = new_symbol

    # Locate nm
    try:
        nm_exe = _find_nm(args.nm)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(f"Using nm: {nm_exe}", file=sys.stderr)

    # Locate wasm-objdump (or llvm-objdump fallback) and ar for WASM signature
    # extraction. Without these we emit K&R `extern void f();` which silently
    # mismatches call_indirect signatures in wasm — only viable for data
    # symbols and rarely-called functions.
    wasm_objdump_exe: str | None = None
    wasm_ar_exe: str | None = None
    if not args.no_wasm_objdump:
        wasm_objdump_exe = _find_tool(
            args.wasm_objdump, ["wasm-objdump", "llvm-objdump"]
        )
        wasm_ar_exe = _find_tool(args.ar, ["llvm-ar", "ar"])
        if wasm_objdump_exe and wasm_ar_exe:
            print(
                f"Using wasm-objdump: {wasm_objdump_exe} (ar: {wasm_ar_exe}) "
                f"for signature extraction",
                file=sys.stderr,
            )
        else:
            missing = []
            if not wasm_objdump_exe:
                missing.append("wasm-objdump/llvm-objdump")
            if not wasm_ar_exe:
                missing.append("llvm-ar/ar")
            print(
                f"warning: skipping WASM signature extraction; missing tools: "
                f"{', '.join(missing)} (extern decls will be K&R, which silently "
                f"breaks call_indirect under wasm legalization)",
                file=sys.stderr,
            )
            wasm_objdump_exe = None

    # Extract symbols from each archive
    libraries: list[tuple[str, list[tuple[str, str]]]] = []
    auto_signatures: dict[str, str] = {}  # symbol -> declaration from wasm-objdump
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

        if wasm_objdump_exe and wasm_ar_exe:
            extracted = _get_wasm_signatures(archive, wasm_objdump_exe, wasm_ar_exe)
            for sym, decl in extracted.items():
                auto_signatures.setdefault(sym, decl)
            print(
                f"    extracted {len(extracted)} WASM signature"
                f"{'s' if len(extracted) != 1 else ''} from {archive}",
                file=sys.stderr,
            )

        # Deduplicate symbols within a single library (should be rare)
        seen: set[str] = set()
        unique_syms = [s for s in syms if not (s[0] in seen or seen.add(s[0]))]  # type: ignore[func-returns-value]

        # Merge manually added symbols for this library
        if fake_path in manual_symbols:
            for manual_sym in manual_symbols[fake_path]:
                if manual_sym not in seen:
                    unique_syms.append((manual_sym, "T"))
                    seen.add(manual_sym)

        if fake_path in rename_symbols:
            for old_symbol in rename_symbols[fake_path]:
                if old_symbol not in seen:
                    print(
                        f"warning: rename target {old_symbol!r} not found for {fake_path!r}",
                        file=sys.stderr,
                    )

        print(
            f"    {fake_path}: {len(unique_syms)} symbol"
            f"{'s' if len(unique_syms) != 1 else ''}",
            file=sys.stderr,
        )
        libraries.append((fake_path, unique_syms))
        total_syms += len(unique_syms)

    # Ignore aliases for libraries that were dropped during pair deduplication.
    known_paths = {fake_path for fake_path, _ in libraries}
    for fake_path in list(library_aliases):
        if fake_path not in known_paths:
            print(
                f"warning: alias spec for unknown library {fake_path!r} ignored",
                file=sys.stderr,
            )
            del library_aliases[fake_path]

    # Build a compact args_repr for the file header comment
    repr_parts: list[str] = []
    if args.nm:
        repr_parts.append(f"--nm {args.nm}")
    if args.output != "-":
        repr_parts.append(f"-o {args.output}")
    if args.list:
        repr_parts.append(f"--list {args.list}")
    repr_parts.extend(f"--add-symbol {spec}" for spec in args.add_symbols)
    repr_parts.extend(f"--symbol-list {spec}" for spec in args.symbol_lists)
    repr_parts.extend(f"--add-alias {spec}" for spec in args.library_aliases)
    repr_parts.extend(f"--rename-symbol {spec}" for spec in args.rename_symbols)
    repr_parts.extend(args.pairs)
    args_repr = " ".join(repr_parts) if repr_parts else "(no arguments)"

    # Flatten manual_symbols into a single name → declaration map for
    # generate(). First non-None signature wins if a symbol appears in
    # multiple libraries (rare). Manual signatures override auto-extracted
    # ones (--add-symbol / --symbol-list lets the user fix up odd cases).
    signatures: dict[str, str] = {}
    for sym, decl in auto_signatures.items():
        signatures[sym] = decl
    for sym_map in manual_symbols.values():
        for sym, sig in sym_map.items():
            if sig is not None:
                signatures[sym] = sig

    source = generate(
        libraries, library_aliases, rename_symbols, signatures, args_repr, nm_exe
    )

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
