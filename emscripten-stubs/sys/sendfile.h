/* stub sys/sendfile.h for Emscripten — sendfile not available in WASM */
#ifndef _SYS_SENDFILE_H
#define _SYS_SENDFILE_H
#include <sys/types.h>
#include <stddef.h>
static inline ssize_t sendfile64(int out_fd, int in_fd, off_t *offset, size_t count) {
    (void)out_fd; (void)in_fd; (void)offset; (void)count;
    return -1;
}
#define sendfile sendfile64
#endif
