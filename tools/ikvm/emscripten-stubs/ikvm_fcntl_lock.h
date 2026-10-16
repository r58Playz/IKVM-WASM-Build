/* ikvm_fcntl_lock.h -- included (-include) into JDK 25's libnio UnixFileDispatcherImpl.c by build-ikvm-native.sh.

   FileChannel.lock and tryLock are fcntl byte-range locks (lock0, release0). WASMFS fails every one with EACCES "until
   we implement byte-range locks", which lock0 reports as held by someone else: tryLock returns null for every file, so
   Minecraft lists each world as "Locked by another running instance" and cannot open one. A browser tab is a single
   process, and a lock only excludes other processes (the JVM's own overlaps are FileLockTable's), so granting every
   lock is the semantics; JDK 8's IKVM FileChannel, which never reached fcntl, behaved the same way. */

#ifndef IKVM_FCNTL_LOCK_H
#define IKVM_FCNTL_LOCK_H

#include <fcntl.h>
#include <stdarg.h>

static int ikvm_fcntl(int fd, int cmd, ...)
{
    va_list ap;
    va_start(ap, cmd);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    switch (cmd) {
    case F_SETLK:
    case F_SETLKW:
        return 0;
    case F_GETLK:
        ((struct flock *)arg)->l_type = F_UNLCK;
        return 0;
    default:
        return fcntl(fd, cmd, arg);
    }
}

#define fcntl ikvm_fcntl

#endif
