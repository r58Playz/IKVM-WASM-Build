/*
 * linux_close_st.c - Single-threaded (no-pthread) NET_* function stubs.
 *
 * In the MT build, linux_close.c provides these wrappers with thread-
 * interruption support via SIGRTMAX-2 / pthread_kill.  In the ST
 * (single-threaded) WASM build there are no blocking threads to interrupt,
 * so each NET_* wrapper delegates directly to the underlying socket syscall
 * with EINTR retry where appropriate.
 *
 * Function signatures must match the declarations in net_util_md.h.
 */

#include <errno.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/poll.h>
#include <sys/time.h>
#include <sys/uio.h>

/* --- Basic I/O --------------------------------------------------- */

int NET_Read(int s, void *buf, size_t len) {
    int ret;
    do { ret = (int)recv(s, buf, len, 0); } while (ret == -1 && errno == EINTR);
    return ret;
}

int NET_NonBlockingRead(int s, void *buf, size_t len) {
    int ret;
    do { ret = (int)recv(s, buf, len, MSG_DONTWAIT); } while (ret == -1 && errno == EINTR);
    return ret;
}

int NET_ReadV(int s, const struct iovec *vector, int count) {
    int ret;
    do { ret = (int)readv(s, vector, count); } while (ret == -1 && errno == EINTR);
    return ret;
}

int NET_Send(int s, void *msg, int len, unsigned int flags) {
    int ret;
    do { ret = (int)send(s, msg, len, (int)flags); } while (ret == -1 && errno == EINTR);
    return ret;
}

int NET_WriteV(int s, const struct iovec *vector, int count) {
    int ret;
    do { ret = (int)writev(s, vector, count); } while (ret == -1 && errno == EINTR);
    return ret;
}

int NET_SendTo(int s, const void *msg, int len, unsigned int flags,
               const struct sockaddr *to, int tolen) {
    int ret;
    do {
        ret = (int)sendto(s, msg, (size_t)len, (int)flags, to, (socklen_t)tolen);
    } while (ret == -1 && errno == EINTR);
    return ret;
}

int NET_RecvFrom(int s, void *buf, int len, unsigned int flags,
                 struct sockaddr *from, int *fromlen) {
    socklen_t socklen = (socklen_t)*fromlen;
    int ret;
    do {
        ret = (int)recvfrom(s, buf, (size_t)len, (int)flags, from, &socklen);
    } while (ret == -1 && errno == EINTR);
    *fromlen = (int)socklen;
    return ret;
}

int NET_Accept(int s, struct sockaddr *addr, int *addrlen) {
    socklen_t socklen = (socklen_t)*addrlen;
    int ret;
    do { ret = (int)accept(s, addr, &socklen); } while (ret == -1 && errno == EINTR);
    *addrlen = (int)socklen;
    return ret;
}

int NET_Connect(int s, struct sockaddr *addr, int addrlen) {
    int ret;
    do {
        ret = connect(s, addr, (socklen_t)addrlen);
    } while (ret == -1 && errno == EINTR);
    return ret;
}

/* --- fd management ----------------------------------------------- */

int NET_Dup2(int fd, int fd2) {
    if (fd < 0) { errno = EBADF; return -1; }
    return dup2(fd, fd2);
}

int NET_SocketClose(int fd) {
    return close(fd);
}

/* --- poll / timeout ---------------------------------------------- */

int NET_Poll(struct pollfd *ufds, unsigned int nfds, int timeout) {
    int ret;
    do { ret = poll(ufds, (nfds_t)nfds, timeout); } while (ret == -1 && errno == EINTR);
    return ret;
}

/*
 * NET_Timeout0 - poll fd for readability with a wall-clock timeout.
 * Simplified from linux_close.c: no thread-interruption, just retry on EINTR.
 */
int NET_Timeout0(int s, long timeout, long currentTime) {
    long prevtime = currentTime, newtime;
    struct timeval t;

    for (;;) {
        struct pollfd pfd;
        int rv;

        pfd.fd     = s;
        pfd.events = POLLIN | POLLERR;

        rv = poll(&pfd, 1, (int)timeout);

        if (rv == -1 && errno == EINTR) {
            if (timeout > 0) {
                gettimeofday(&t, NULL);
                newtime = t.tv_sec * 1000 + t.tv_usec / 1000;
                timeout -= (newtime - prevtime);
                if (timeout <= 0) return 0;
                prevtime = newtime;
            }
        } else {
            return rv;
        }
    }
}
