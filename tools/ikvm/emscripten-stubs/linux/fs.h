/* stub linux/fs.h for Emscripten */
#ifndef _LINUX_FS_H
#define _LINUX_FS_H
#include <sys/ioctl.h>
/* the size of a block device (JDK 25's UnixFileDispatcherImpl.c); emscripten has none, so the ioctl fails */
#ifndef BLKGETSIZE64
#define BLKGETSIZE64 _IOR(0x12, 114, size_t)
#endif
#endif
