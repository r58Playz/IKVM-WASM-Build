#include <string.h>
#include <sys/sysinfo.h>

int sysinfo(struct sysinfo* info) {
    if (info == 0) {
        return -1;
    }

    memset(info, 0, sizeof(*info));
    info->mem_unit = 1;
    return 0;
}
