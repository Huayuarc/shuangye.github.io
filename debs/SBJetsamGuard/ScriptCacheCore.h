/* Internal portable filesystem core, included by ScriptFeatures.m and tests.
 * No shell, path-based recursive removal, directory removal or symlink following. */
#ifndef SJG_SCRIPT_CACHE_CORE_H
#define SJG_SCRIPT_CACHE_CORE_H
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <limits.h>

#define SJG_CACHE_ROOT "/var/mobile/Containers/Data/Application"
#define SJG_CACHE_CANONICAL_ROOT "/private/var/mobile/Containers/Data/Application"
#if defined(SJG_SCRIPT_TEST_ROOT) && !defined(SJG_SCRIPT_TESTING)
#error "Root override is allowed only in an explicit test build"
#endif
#define SJG_CACHE_MAX_FILES 1000U
#define SJG_CACHE_MAX_BYTES (128ULL * 1024ULL * 1024ULL)
#define SJG_CACHE_MAX_VISITS 20000U
#define SJG_CACHE_MAX_DEPTH 16U
#define SJG_CACHE_MIN_AGE (7 * 24 * 60 * 60)

typedef struct {
    uint64_t removedBytes;
    unsigned removedCount, skipped, errors, visited, containers;
    int rootError, limited;
    time_t now;
} SJGCacheResult;
typedef int (*SJGContainerAllowed)(const char *uuid, int fd, void *context);

static int SJGIsUUID(const char *s) {
    if (!s || strlen(s) != 36) return 0;
    for (unsigned i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (s[i] != '-') return 0;
        } else if (!((s[i] >= '0' && s[i] <= '9') ||
                     (s[i] >= 'a' && s[i] <= 'f') ||
                     (s[i] >= 'A' && s[i] <= 'F'))) return 0;
    }
    return 1;
}
static int SJGSameFile(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
/* Absolute descriptor walk: even ancestors must not be symlinks. */
static int SJGOpenAbsoluteDirectory(const char *path) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX) {
        errno = EINVAL; return -1;
    }
    char copy[PATH_MAX]; memcpy(copy, path, strlen(path) + 1);
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    char *save = NULL;
    for (char *part = strtok_r(copy, "/", &save); part;
         part = strtok_r(NULL, "/", &save)) {
        if (!strcmp(part, ".") || !strcmp(part, "..")) {
            close(fd); errno = EINVAL; return -1;
        }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        int e = errno; close(fd); fd = next;
        if (fd < 0) { errno = e; return -1; }
    }
    return fd;
}
static int SJGCacheRootFD(void) {
    char resolved[PATH_MAX];
#ifdef SJG_SCRIPT_TEST_ROOT
    const char *root = SJG_SCRIPT_TEST_ROOT;
#else
    const char *root = SJG_CACHE_ROOT;
#endif
    if (!realpath(root, resolved)) return -1;
#ifdef SJG_SCRIPT_TEST_ROOT
    /* The fixture itself must be an absolute canonical path. */
    if (strcmp(resolved, root)) { errno = EPERM; return -1; }
#else
    /* /var is an OS alias on iOS; no other redirects are accepted. */
    if (strcmp(resolved, SJG_CACHE_ROOT) &&
        strcmp(resolved, SJG_CACHE_CANONICAL_ROOT)) { errno = EPERM; return -1; }
#endif
    struct stat before, after;
    if (lstat(resolved, &before) || !S_ISDIR(before.st_mode)) {
        errno = ENOTDIR; return -1;
    }
    int fd = SJGOpenAbsoluteDirectory(resolved);
    if (fd < 0) return -1;
    if (fstat(fd, &after) || !SJGSameFile(&before, &after)) {
        int e = errno ? errno : ESTALE; close(fd); errno = e; return -1;
    }
    return fd;
}
static int SJGCacheAtLimit(SJGCacheResult *r) {
    if (r->removedCount >= SJG_CACHE_MAX_FILES ||
        r->removedBytes >= SJG_CACHE_MAX_BYTES || r->visited >= SJG_CACHE_MAX_VISITS) {
        r->limited = 1; return 1;
    }
    return 0;
}
static void SJGCacheWalk(int parent, unsigned depth, SJGCacheResult *r) {
    int copy = dup(parent);
    if (copy < 0) { r->errors++; return; }
    DIR *dir = fdopendir(copy);
    if (!dir) { close(copy); r->errors++; return; }
    for (;;) {
        if (SJGCacheAtLimit(r)) break;
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) r->errors++; break; }
        const char *name = entry->d_name;
        if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
        r->visited++;
        struct stat st, opened, current, parentStat;
        if (fstat(parent, &parentStat)) { r->errors++; break; }
        if (fstatat(parent, name, &st, AT_SYMLINK_NOFOLLOW)) { r->errors++; continue; }
        if (st.st_dev != parentStat.st_dev) { r->skipped++; continue; }
        if (S_ISDIR(st.st_mode)) {
            if (depth >= SJG_CACHE_MAX_DEPTH) { r->skipped++; r->limited = 1; continue; }
            int child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
            if (child < 0) { r->errors++; continue; }
            if (!fstat(child, &opened) && SJGSameFile(&st, &opened) &&
                opened.st_dev == st.st_dev) SJGCacheWalk(child, depth + 1, r);
            else r->errors++;
            close(child); continue; /* Never remove directories. */
        }
        if (!S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < 0 ||
            st.st_mtime >= r->now - SJG_CACHE_MIN_AGE ||
            st.st_ctime >= r->now - SJG_CACHE_MIN_AGE ||
            (uint64_t)st.st_size > SJG_CACHE_MAX_BYTES - r->removedBytes) {
            r->skipped++; continue;
        }
        int file = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
        if (file < 0) { r->errors++; continue; }
        /* Verify both the held file and the directory entry immediately before unlink. */
        if (fstat(file, &opened) || !SJGSameFile(&st, &opened) ||
            !S_ISREG(opened.st_mode) || opened.st_nlink != 1 ||
            opened.st_size != st.st_size || opened.st_mtime != st.st_mtime ||
            opened.st_ctime != st.st_ctime ||
            fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) ||
            !SJGSameFile(&opened, &current) || current.st_size != opened.st_size ||
            current.st_mtime != opened.st_mtime || current.st_ctime != opened.st_ctime ||
            current.st_nlink != 1 || !S_ISREG(current.st_mode)) r->skipped++;
        else if (unlinkat(parent, name, 0)) r->errors++;
        else { r->removedCount++; r->removedBytes += (uint64_t)opened.st_size; }
        close(file);
    }
    closedir(dir);
}
static SJGCacheResult SJGCacheRun(SJGContainerAllowed allowed, void *context, time_t now) {
    SJGCacheResult r = {0}; r.now = now;
    if (!allowed || now < SJG_CACHE_MIN_AGE) { r.rootError = EINVAL; return r; }
    int root = SJGCacheRootFD();
    if (root < 0) { r.rootError = errno; return r; }
    struct stat rootStat;
    if (fstat(root, &rootStat)) { r.rootError = errno; close(root); return r; }
    int copy = dup(root);
    DIR *dir = copy >= 0 ? fdopendir(copy) : NULL;
    if (!dir) { r.rootError = errno; if (copy >= 0) close(copy); close(root); return r; }
    for (;;) {
        if (SJGCacheAtLimit(&r)) break;
        errno = 0; struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) r.errors++; break; }
        const char *name = entry->d_name;
        if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
        r.visited++;
        if (!SJGIsUUID(name)) { r.skipped++; continue; }
        struct stat st, check;
        if (fstatat(root, name, &st, AT_SYMLINK_NOFOLLOW) || !S_ISDIR(st.st_mode) ||
            st.st_dev != rootStat.st_dev) { r.skipped++; continue; }
        int container = openat(root, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (container < 0) { r.skipped++; continue; }
        if (fstat(container, &check) || !SJGSameFile(&st, &check) ||
            !allowed(name, container, context)) { close(container); r.skipped++; continue; }
        int library = openat(container, "Library", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        int cache = library < 0 ? -1 : openat(library, "Caches", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        struct stat libStat, cacheStat;
        if (cache >= 0 && !fstat(library, &libStat) && !fstat(cache, &cacheStat) &&
            libStat.st_dev == rootStat.st_dev && cacheStat.st_dev == rootStat.st_dev) {
            r.containers++; SJGCacheWalk(cache, 0, &r);
        } else r.skipped++;
        if (cache >= 0) close(cache);
        if (library >= 0) close(library);
        close(container);
    }
    closedir(dir); close(root); return r;
}
#endif
