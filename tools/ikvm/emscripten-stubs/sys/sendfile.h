/* stub sys/sendfile.h for Emscripten — sendfile not available in WASM.

   Fails with EINVAL, which both of libnio's callers take as "unsupported for these files" and fall back on copying
   through a buffer: LinuxNativeDispatcher.directCopy0 (Files.copy) and FileDispatcherImpl.transferTo0
   (FileChannel.transferTo). Failing without setting errno left them to throw a UnixException of whatever errno held,
   so Files.copy of a non-empty file failed with a bare FileSystemException. */
#ifndef _SYS_SENDFILE_H
#define _SYS_SENDFILE_H
#include <sys/types.h>
#include <stddef.h>
#include <errno.h>
static inline ssize_t sendfile64(int out_fd, int in_fd, off_t *offset, size_t count) {
    (void)out_fd; (void)in_fd; (void)offset; (void)count;
    errno = EINVAL;
    return -1;
}
#define sendfile sendfile64
#endif
