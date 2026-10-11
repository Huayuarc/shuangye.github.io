#ifndef SJG_PATHS_H
#define SJG_PATHS_H

/* No Foundation / libroot dependency: use this exact resolver in every process. */
#include <dirent.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif
#ifndef SJG_APPGROUP_ROOT
#define SJG_APPGROUP_ROOT "/var/mobile/Containers/Shared/AppGroup"
#endif
#ifndef SJG_ROOTLESS_ROOT
#define SJG_ROOTLESS_ROOT "/var/jb"
#endif
#ifndef SJG_REAL_PREFS_ROOT
#define SJG_REAL_PREFS_ROOT "/var/mobile/Library/Preferences"
#endif
#define SJG_PREFS_FILENAME "com.huayuarc.sbjetsamguard.plist"
#define SJG_STATUS_FILENAME "com.huayuarc.sbjetsamguard.status.plist"
#define SJG_SETTINGS_CHANGED "com.huayuarc.sbjetsamguard.settingschanged"
#define SJG_CLEAN_CACHES "com.huayuarc.sbjetsamguard.cleanCaches"
#define SJG_PREFS_SUFFIX "/var/mobile/Library/Preferences"

typedef void (*SJGRootVisitor)(const char *root, void *context);

static inline bool SJGJoinPath(char *out, size_t capacity,
                               const char *root, const char *suffix) {
    if (!out || !capacity || !root || !suffix) return false;
    int n = snprintf(out, capacity, "%s%s", root, suffix);
    if (n < 0 || (size_t)n >= capacity) { out[0] = '\0'; return false; }
    return true;
}

static inline bool SJGIsDirectory(const char *path) {
    struct stat st;
    return path && stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

/* Secondary AppGroup roots own var; .jbroot points to the primary binary root. */
static inline void SJGVisitRootHideRoots(SJGRootVisitor visitor, void *context) {
    if (!visitor) return;
    DIR *dir = opendir(SJG_APPGROUP_ROOT);
    if (!dir) return;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strncmp(entry->d_name, ".jbroot-", 8) || !entry->d_name[8]) continue;
        char path[PATH_MAX];
        int n = snprintf(path, sizeof(path), "%s/%s", SJG_APPGROUP_ROOT, entry->d_name);
        if (n > 0 && (size_t)n < sizeof(path) && SJGIsDirectory(path)) visitor(path, context);
    }
    closedir(dir);
}

static inline bool SJGRootHasItem(const char *root, const char *suffix, bool regular) {
    char path[PATH_MAX];
    struct stat st;
    return SJGJoinPath(path, sizeof(path), root, suffix) && stat(path, &st) == 0 &&
           (regular ? S_ISREG(st.st_mode) : S_ISDIR(st.st_mode));
}

typedef struct {
    char path[PATH_MAX];
    int score;
    time_t modified;
} SJGRootSelection;

static inline void SJGScoreRoot(const char *root, void *context) {
    SJGRootSelection *best = (SJGRootSelection *)context;
    struct stat st;
    if (stat(root, &st)) return;
    int score = 1;
    if (SJGRootHasItem(root, "/usr/libexec/sbjetsamguard", true) ||
        SJGRootHasItem(root, "/.jbroot/usr/libexec/sbjetsamguard", true)) score = 100;
    else if (SJGRootHasItem(root, "/.jbroot/usr/lib", false) ||
             SJGRootHasItem(root, "/usr/lib", false)) score = 10;
    if (score > best->score || (score == best->score &&
        (st.st_mtime > best->modified || (st.st_mtime == best->modified &&
         strcmp(root, best->path) < 0)))) {
        if (SJGJoinPath(best->path, sizeof(best->path), root, "")) {
            best->score = score;
            best->modified = st.st_mtime;
        }
    }
}

/* Deliberately uncached: survives RootHide UUID changes without restarting Settings. */
static inline bool SJGCopySharedRoot(char *out, size_t capacity) {
    SJGRootSelection best = { .path = "", .score = 0, .modified = 0 };
    SJGVisitRootHideRoots(SJGScoreRoot, &best);
    return SJGJoinPath(out, capacity, best.score ? best.path : SJG_ROOTLESS_ROOT, "");
}

static inline bool SJGCopyPreferencesDirectory(char *out, size_t capacity) {
    char root[PATH_MAX];
    return SJGCopySharedRoot(root, sizeof(root)) &&
           SJGJoinPath(out, capacity, root, SJG_PREFS_SUFFIX);
}

static inline bool SJGCopyPreferencesPath(char *out, size_t capacity) {
    char dir[PATH_MAX];
    return SJGCopyPreferencesDirectory(dir, sizeof(dir)) &&
           SJGJoinPath(out, capacity, dir, "/" SJG_PREFS_FILENAME);
}

static inline bool SJGCopyStatusPath(char *out, size_t capacity) {
    char dir[PATH_MAX];
    return SJGCopyPreferencesDirectory(dir, sizeof(dir)) &&
           SJGJoinPath(out, capacity, dir, "/" SJG_STATUS_FILENAME);
}
#endif
