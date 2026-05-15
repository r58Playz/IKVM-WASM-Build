/*
 * openal-stubs.c
 *
 * Stubs for OpenAL functions that Emscripten's library_openal.js does not
 * implement. The rest of the OpenAL surface (alcOpenDevice, alSourcePlay, ...)
 * is provided by `-lopenal` at link time and registered with the static link
 * loader via --symbol-list (see openal-symbols.txt).
 *
 * LWJGL resolves AL function pointers exclusively through alGetProcAddress
 * (see lwjgl3/.../openal/AL.java: AL.init sets up a FunctionProvider that
 * calls alGetProcAddress for every AL entry point, and AL.createCapabilities
 * throws "Core OpenAL functions could not be found" if alGetString,
 * alGetError, or alIsExtensionPresent resolve to NULL). It also calls
 * alcGetProcAddress for the device-scoped ALC extension functions enumerated
 * in ALCCapabilities (alcSetThreadContext, alc*SOFT, ...). Returning NULL
 * from either of these would break AL.createCapabilities outright.
 *
 * Implementation strategy: gen-static-libs.py emits a name -> pointer table
 * for the OpenAL pseudo-library that combines every symbol in
 * openal-symbols.txt with the stubs in this file. That table (jvm_static_libs)
 * is the single source of truth for what emscripten's library_openal.js
 * exposes, so we resolve names through it rather than maintaining a parallel
 * list here. The table is linked into the final image alongside this archive
 * via the generated statics.c, so the extern reference below is satisfied at
 * link time.
 *
 * The FAKE_PATH key matches the canonical name LWJGL feeds JVM_LoadLibrary
 * (LWJGL's SharedLibrary loader resolves "openal" against
 * org.lwjgl.librarypath, e.g. /tmp/lwjgl, producing /tmp/lwjgl/libopenal.so).
 * The default is set to match the current ikvm-wasm harness, but the
 * harness can override `openal_lib_path` before the first AL/ALC call if it
 * registers the library under a different FAKE_PATH in its
 * gen-static-libs.py invocation.
 */

#include <stddef.h>
#include <string.h>

/*
 * Mirrors the jvm_symbol_entry_t / jvm_static_lib_entry_t definitions from
 * tools/ikvm/ikvm/src/libjvm/jvm_emscripten_dynlib.h. Inlined here so this
 * stub stays compilable without an -I dependency on the libjvm tree; the
 * struct layout must match.
 */
typedef struct {
    const char *name;
    void       *ptr;
} jvm_symbol_entry_t;

typedef struct {
    const char               *path;
    const jvm_symbol_entry_t *symbols;
} jvm_static_lib_entry_t;

extern const jvm_static_lib_entry_t jvm_static_libs[];

/*
 * FAKE_PATH under which the harness registered emscripten's OpenAL surface
 * in jvm_static_libs[]. Exposed as a mutable global so the harness can
 * override it before the first AL/ALC call if it uses a different path.
 */
const char *openal_lib_path = "/tmp/lwjgl/libopenal.so";

static void *lookup_openal_symbol(const char *name) {
    if (name == NULL || openal_lib_path == NULL) {
        return NULL;
    }
    for (const jvm_static_lib_entry_t *lib = jvm_static_libs; lib->path != NULL; lib++) {
        if (strcmp(lib->path, openal_lib_path) != 0) {
            continue;
        }
        if (lib->symbols == NULL) {
            return NULL;
        }
        for (const jvm_symbol_entry_t *sym = lib->symbols; sym->name != NULL; sym++) {
            if (strcmp(sym->name, name) == 0) {
                return sym->ptr;
            }
        }
        return NULL;
    }
    return NULL;
}

void *alcGetProcAddress(void *device, const char *name) {
    (void)device;
    return lookup_openal_symbol(name);
}

void *alGetProcAddress(const char *name) {
    return lookup_openal_symbol(name);
}
