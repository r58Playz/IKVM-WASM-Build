/* stub sys/epoll.h for Emscripten — epoll not available in WASM */
#ifndef _SYS_EPOLL_H
#define _SYS_EPOLL_H
#include <stdint.h>

#define EPOLLIN     0x001
#define EPOLLOUT    0x004
#define EPOLLERR    0x008
#define EPOLLHUP    0x010
#define EPOLLPRI    0x002
#define EPOLLET     (1u << 31)
#define EPOLLONESHOT (1u << 30)

typedef union epoll_data {
    void        *ptr;
    int          fd;
    uint32_t     u32;
    uint64_t     u64;
} epoll_data_t;

struct epoll_event {
    uint32_t     events;
    epoll_data_t data;
};

#define EPOLL_CTL_ADD 1
#define EPOLL_CTL_DEL 2
#define EPOLL_CTL_MOD 3

static inline int epoll_create(int size) { (void)size; return -1; }
static inline int epoll_ctl(int epfd, int op, int fd, struct epoll_event *ev) {
    (void)epfd; (void)op; (void)fd; (void)ev; return -1; }
static inline int epoll_wait(int epfd, struct epoll_event *evs, int maxev, int timeout) {
    (void)epfd; (void)evs; (void)maxev; (void)timeout; return -1; }
#endif
