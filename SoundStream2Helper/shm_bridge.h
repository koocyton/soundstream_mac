#ifndef SHM_BRIDGE_H
#define SHM_BRIDGE_H

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>

static inline int shm_open_bridge(const char *name, int oflag, int mode) {
    return shm_open(name, oflag, (mode_t)mode);
}

static inline int shm_unlink_bridge(const char *name) {
    return shm_unlink(name);
}

#endif
