/* stub sys/eventfd.h for Emscripten — eventfd not available in WASM (JDK 25's EventFD.c, the EPoll selector's
   wakeup) */
#ifndef _SYS_EVENTFD_H
#define _SYS_EVENTFD_H
#include <stdint.h>
#include <errno.h>

typedef uint64_t eventfd_t;

#define EFD_SEMAPHORE 1
#define EFD_CLOEXEC   02000000
#define EFD_NONBLOCK  04000

static inline int eventfd(unsigned int initval, int flags) { (void)initval; (void)flags; errno = ENOSYS; return -1; }
static inline int eventfd_read(int fd, eventfd_t *value) { (void)fd; (void)value; errno = ENOSYS; return -1; }
static inline int eventfd_write(int fd, eventfd_t value) { (void)fd; (void)value; errno = ENOSYS; return -1; }
#endif
