/* ikvm_linux_errno.h -- included (-include) into JDK 25's libnio UnixNativeDispatcher.c by build-ikvm-native.sh.

   The JDK's sun.nio.fs tells errors apart by comparing UnixException's errno with UnixConstants, which its build
   generated from Linux's headers; emscripten's errno has its own (wasi) numbering, under which EEXIST is 20, not 17, so
   createDirectories did not see FileAlreadyExistsException. throwUnixException is where the natives hand an errno to
   Java: its UnixException gets the Linux number. Generated from <errno.h> under emscripten 3.1.56 and glibc. */

#ifndef IKVM_LINUX_ERRNO_H
#define IKVM_LINUX_ERRNO_H

#include <jni.h>
#include "jni_util.h"

static inline int ikvm_linux_errno(int e)
{
    switch (e) {
    case 1: return 7; /* E2BIG */
    case 2: return 13; /* EACCES */
    case 3: return 98; /* EADDRINUSE */
    case 4: return 99; /* EADDRNOTAVAIL */
    case 5: return 97; /* EAFNOSUPPORT */
    case 6: return 11; /* EAGAIN */
    case 7: return 114; /* EALREADY */
    case 8: return 9; /* EBADF */
    case 9: return 74; /* EBADMSG */
    case 10: return 16; /* EBUSY */
    case 11: return 125; /* ECANCELED */
    case 12: return 10; /* ECHILD */
    case 13: return 103; /* ECONNABORTED */
    case 14: return 111; /* ECONNREFUSED */
    case 15: return 104; /* ECONNRESET */
    case 16: return 35; /* EDEADLK */
    case 17: return 89; /* EDESTADDRREQ */
    case 18: return 33; /* EDOM */
    case 19: return 122; /* EDQUOT */
    case 20: return 17; /* EEXIST */
    case 21: return 14; /* EFAULT */
    case 22: return 27; /* EFBIG */
    case 23: return 113; /* EHOSTUNREACH */
    case 24: return 43; /* EIDRM */
    case 25: return 84; /* EILSEQ */
    case 26: return 115; /* EINPROGRESS */
    case 27: return 4; /* EINTR */
    case 28: return 22; /* EINVAL */
    case 29: return 5; /* EIO */
    case 30: return 106; /* EISCONN */
    case 31: return 21; /* EISDIR */
    case 32: return 40; /* ELOOP */
    case 33: return 24; /* EMFILE */
    case 34: return 31; /* EMLINK */
    case 35: return 90; /* EMSGSIZE */
    case 36: return 72; /* EMULTIHOP */
    case 37: return 36; /* ENAMETOOLONG */
    case 38: return 100; /* ENETDOWN */
    case 39: return 102; /* ENETRESET */
    case 40: return 101; /* ENETUNREACH */
    case 41: return 23; /* ENFILE */
    case 42: return 105; /* ENOBUFS */
    case 43: return 19; /* ENODEV */
    case 44: return 2; /* ENOENT */
    case 45: return 8; /* ENOEXEC */
    case 46: return 37; /* ENOLCK */
    case 47: return 67; /* ENOLINK */
    case 48: return 12; /* ENOMEM */
    case 49: return 42; /* ENOMSG */
    case 50: return 92; /* ENOPROTOOPT */
    case 51: return 28; /* ENOSPC */
    case 52: return 38; /* ENOSYS */
    case 53: return 107; /* ENOTCONN */
    case 54: return 20; /* ENOTDIR */
    case 55: return 39; /* ENOTEMPTY */
    case 56: return 131; /* ENOTRECOVERABLE */
    case 57: return 88; /* ENOTSOCK */
    case 59: return 25; /* ENOTTY */
    case 60: return 6; /* ENXIO */
    case 61: return 75; /* EOVERFLOW */
    case 62: return 130; /* EOWNERDEAD */
    case 63: return 1; /* EPERM */
    case 64: return 32; /* EPIPE */
    case 65: return 71; /* EPROTO */
    case 66: return 93; /* EPROTONOSUPPORT */
    case 67: return 91; /* EPROTOTYPE */
    case 68: return 34; /* ERANGE */
    case 69: return 30; /* EROFS */
    case 70: return 29; /* ESPIPE */
    case 71: return 3; /* ESRCH */
    case 72: return 116; /* ESTALE */
    case 73: return 110; /* ETIMEDOUT */
    case 74: return 26; /* ETXTBSY */
    case 75: return 18; /* EXDEV */
    case 100: return 60; /* ENOSTR */
    case 101: return 59; /* EBFONT */
    case 102: return 57; /* EBADSLT */
    case 103: return 56; /* EBADRQC */
    case 104: return 55; /* ENOANO */
    case 105: return 15; /* ENOTBLK */
    case 106: return 44; /* ECHRNG */
    case 107: return 46; /* EL3HLT */
    case 108: return 47; /* EL3RST */
    case 109: return 48; /* ELNRNG */
    case 110: return 49; /* EUNATCH */
    case 111: return 50; /* ENOCSI */
    case 112: return 51; /* EL2HLT */
    case 113: return 52; /* EBADE */
    case 114: return 53; /* EBADR */
    case 115: return 54; /* EXFULL */
    case 116: return 61; /* ENODATA */
    case 117: return 62; /* ETIME */
    case 118: return 63; /* ENOSR */
    case 119: return 64; /* ENONET */
    case 120: return 65; /* ENOPKG */
    case 121: return 66; /* EREMOTE */
    case 122: return 68; /* EADV */
    case 123: return 69; /* ESRMNT */
    case 124: return 70; /* ECOMM */
    case 125: return 73; /* EDOTDOT */
    case 126: return 76; /* ENOTUNIQ */
    case 127: return 77; /* EBADFD */
    case 128: return 78; /* EREMCHG */
    case 129: return 79; /* ELIBACC */
    case 130: return 80; /* ELIBBAD */
    case 131: return 81; /* ELIBSCN */
    case 132: return 82; /* ELIBMAX */
    case 133: return 83; /* ELIBEXEC */
    case 134: return 85; /* ERESTART */
    case 135: return 86; /* ESTRPIPE */
    case 136: return 87; /* EUSERS */
    case 137: return 94; /* ESOCKTNOSUPPORT */
    case 138: return 95; /* EOPNOTSUPP */
    case 139: return 96; /* EPFNOSUPPORT */
    case 140: return 108; /* ESHUTDOWN */
    case 141: return 109; /* ETOOMANYREFS */
    case 142: return 112; /* EHOSTDOWN */
    case 143: return 117; /* EUCLEAN */
    case 144: return 118; /* ENOTNAM */
    case 145: return 119; /* ENAVAIL */
    case 146: return 120; /* EISNAM */
    case 147: return 121; /* EREMOTEIO */
    case 148: return 123; /* ENOMEDIUM */
    case 149: return 124; /* EMEDIUMTYPE */
    case 150: return 126; /* ENOKEY */
    case 151: return 127; /* EKEYEXPIRED */
    case 152: return 128; /* EKEYREVOKED */
    case 153: return 129; /* EKEYREJECTED */
    case 154: return 132; /* ERFKILL */
    case 155: return 133; /* EHWPOISON */
    case 156: return 45; /* EL2NSYNC */
    default: return e;
    }
}

#define JNU_NewObjectByName(env, cls, sig, e) JNU_NewObjectByName(env, cls, sig, ikvm_linux_errno(e))

#endif
