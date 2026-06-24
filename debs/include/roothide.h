#ifndef CPUTHERMAL_ROOTHIDE_COMPAT_H
#define CPUTHERMAL_ROOTHIDE_COMPAT_H

#include <rootless.h>

static inline const char *jbroot(const char *path) {
    return ROOT_PATH_VAR(path);
}

static inline const char *rootfs(const char *path) {
    return path;
}

#endif
