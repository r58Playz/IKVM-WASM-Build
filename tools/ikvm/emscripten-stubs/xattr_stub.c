/* stub extended attributes for Emscripten, which has the declarations (sys/xattr.h) but not the functions; JDK 25's
   UnixNativeDispatcher.c calls them for UserDefinedFileAttributeView. No file system here has extended attributes. */
#include <errno.h>
#include <sys/types.h>
#include <sys/xattr.h>

ssize_t fgetxattr(int fd, const char *name, void *value, size_t size) {
    (void)fd; (void)name; (void)value; (void)size;
    errno = ENOTSUP;
    return -1;
}

int fsetxattr(int fd, const char *name, const void *value, size_t size, int flags) {
    (void)fd; (void)name; (void)value; (void)size; (void)flags;
    errno = ENOTSUP;
    return -1;
}

int fremovexattr(int fd, const char *name) {
    (void)fd; (void)name;
    errno = ENOTSUP;
    return -1;
}

ssize_t flistxattr(int fd, char *list, size_t size) {
    (void)fd; (void)list; (void)size;
    errno = ENOTSUP;
    return -1;
}
