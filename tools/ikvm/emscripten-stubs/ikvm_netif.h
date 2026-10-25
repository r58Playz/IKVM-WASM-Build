/* ikvm_netif.h -- included (-include) into JDK 25's libnet NetworkInterface.c by build-ikvm-native.sh.

   NetworkInterface enumerates interfaces with the Linux ioctls (SIOCGIFCONF, SIOCGIFFLAGS, ...) on a datagram socket.
   emscripten has neither: socket() fails with ENOSYS, so getNetworkInterfaces threw "Socket creation failed" and
   anything that looks for a MAC address (a hardware ID, say) failed with it. A browser reaches the network only
   through a proxy, so answer as a machine behind a NAT would: a loopback and one Ethernet interface, at the addresses
   QEMU's user-mode networking gives its guest. The Ethernet interface's MAC is read from sysfs, where Linux keeps it
   (/sys/class/net/<name>/address); the embedder provides that file, and without it the interface has no hardware
   address. IPv6 enumeration reads /proc/net/if_inet6, which does not exist here, so there are no IPv6 addresses. */

#ifndef IKVM_NETIF_H
#define IKVM_NETIF_H

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct {
    const char *name;
    int index;
    int flags;
    int mtu;
    int hwtype;
    uint32_t addr;      /* host byte order */
    uint32_t brdcast;   /* host byte order, 0 for none */
    uint32_t netmask;   /* host byte order */
} ikvm_netif;

/* in SIOCGIFCONF's order; NetworkInterface.c prepends each, so getNetworkInterfaces lists eth0 first, as Linux does */
static const ikvm_netif ikvm_netifs[] = {
    { "lo", 1, IFF_UP | IFF_LOOPBACK | IFF_RUNNING, 65536, ARPHRD_LOOPBACK,
      0x7f000001 /* 127.0.0.1 */, 0, 0xff000000 },
    { "eth0", 2, IFF_UP | IFF_BROADCAST | IFF_RUNNING | IFF_MULTICAST, 1500, ARPHRD_ETHER,
      0x0a00020f /* 10.0.2.15 */, 0x0a0002ff, 0xffffff00 },
};

#define IKVM_NETIF_COUNT (sizeof(ikvm_netifs) / sizeof(ikvm_netifs[0]))

static const ikvm_netif *ikvm_find_netif(const char *name)
{
    size_t i;
    for (i = 0; i < IKVM_NETIF_COUNT; i++) {
        if (strncmp(ikvm_netifs[i].name, name, IFNAMSIZ) == 0)
            return &ikvm_netifs[i];
    }
    errno = ENODEV;
    return NULL;
}

static void ikvm_set_inet(struct sockaddr *sa, uint32_t addr)
{
    struct sockaddr_in *sin = (struct sockaddr_in *)sa;
    memset(sin, 0, sizeof(*sin));
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = htonl(addr);
}

/* sysfs' "aa:bb:cc:dd:ee:ff"; all zeros, which NetworkInterface takes for no hardware address, if it is missing */
static void ikvm_read_hwaddr(const char *name, unsigned char *mac)
{
    char path[sizeof("/sys/class/net//address") + IFNAMSIZ];
    unsigned int b[6];
    FILE *f;
    int i;

    memset(mac, 0, 6);
    snprintf(path, sizeof(path), "/sys/class/net/%s/address", name);
    if ((f = fopen(path, "r")) == NULL)
        return;
    if (fscanf(f, "%2x:%2x:%2x:%2x:%2x:%2x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) == 6) {
        for (i = 0; i < 6; i++)
            mac[i] = (unsigned char)b[i];
    }
    fclose(f);
}

/* The ioctls below need no socket, but the JDK's code opens one for them and closes it after: any descriptor will do. */
static int ikvm_socket(int domain, int type, int protocol)
{
    (void)type; (void)protocol;
    if (domain != AF_INET && domain != AF_INET6) {
        errno = EAFNOSUPPORT;
        return -1;
    }
    return open("/dev/null", O_RDONLY | O_CLOEXEC);
}

static int ikvm_ioctl(int fd, int req, ...)
{
    va_list ap;
    va_start(ap, req);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    if (req == SIOCGIFCONF) {
        struct ifconf *ifc = (struct ifconf *)arg;
        size_t i, n = IKVM_NETIF_COUNT;
        /* no buffer asks for the size */
        if (ifc->ifc_buf == NULL) {
            ifc->ifc_len = (int)(n * sizeof(struct ifreq));
            return 0;
        }
        if ((size_t)ifc->ifc_len / sizeof(struct ifreq) < n)
            n = (size_t)ifc->ifc_len / sizeof(struct ifreq);
        for (i = 0; i < n; i++) {
            struct ifreq *ifr = &ifc->ifc_req[i];
            memset(ifr, 0, sizeof(*ifr));
            strncpy(ifr->ifr_name, ikvm_netifs[i].name, IFNAMSIZ - 1);
            ikvm_set_inet(&ifr->ifr_addr, ikvm_netifs[i].addr);
        }
        ifc->ifc_len = (int)(n * sizeof(struct ifreq));
        return 0;
    }

    struct ifreq *ifr = (struct ifreq *)arg;
    const ikvm_netif *nif;
    switch (req) {
    case SIOCGIFFLAGS:
    case SIOCGIFBRDADDR:
    case SIOCGIFNETMASK:
    case SIOCGIFINDEX:
    case SIOCGIFHWADDR:
    case SIOCGIFMTU:
        if ((nif = ikvm_find_netif(ifr->ifr_name)) == NULL)
            return -1;
        break;
    default:
        return ioctl(fd, req, arg);
    }

    switch (req) {
    case SIOCGIFFLAGS:
        ifr->ifr_flags = (short)nif->flags;
        return 0;
    case SIOCGIFBRDADDR:
        if (nif->brdcast == 0) {
            errno = EADDRNOTAVAIL;
            return -1;
        }
        ikvm_set_inet(&ifr->ifr_broadaddr, nif->brdcast);
        return 0;
    case SIOCGIFNETMASK:
        ikvm_set_inet(&ifr->ifr_netmask, nif->netmask);
        return 0;
    case SIOCGIFINDEX:
        ifr->ifr_ifindex = nif->index;
        return 0;
    case SIOCGIFHWADDR:
        memset(&ifr->ifr_hwaddr, 0, sizeof(ifr->ifr_hwaddr));
        ifr->ifr_hwaddr.sa_family = (sa_family_t)nif->hwtype;
        ikvm_read_hwaddr(nif->name, (unsigned char *)ifr->ifr_hwaddr.sa_data);
        return 0;
    default: /* SIOCGIFMTU */
        ifr->ifr_mtu = nif->mtu;
        return 0;
    }
}

#define socket(domain, type, protocol) ikvm_socket(domain, type, protocol)
#define ioctl(fd, ...) ikvm_ioctl(fd, __VA_ARGS__)

#endif
