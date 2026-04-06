/*
 * pthread_stubs.c - Minimal pthread_kill stub for single-threaded WASM builds.
 *
 * NativeThread.c (sun/nio/ch) calls pthread_kill to deliver an interrupt
 * signal to a blocked thread.  In the ST WASM build there are no other
 * threads, so we provide a stub that returns ESRCH (no such thread).
 * The Java caller (NativeThread.signal) will propagate an IOException that
 * can be caught by the application.
 *
 * pthread_t is typedef'd to unsigned long in Emscripten / glibc headers.
 * We declare it independently here to avoid pulling in <pthread.h> (which
 * is not available without -pthread in Emscripten).
 */

#include <errno.h>

typedef unsigned long pthread_t;

int pthread_kill(pthread_t thread, int sig) {
    (void)thread;
    (void)sig;
    errno = ESRCH;
    return ESRCH;
}
