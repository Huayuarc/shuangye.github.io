#define _GNU_SOURCE 1
#define SJG_SCRIPT_TESTING 1
static char fixtureRoot[4096];
#define SJG_SCRIPT_TEST_ROOT fixtureRoot
#include "../ScriptCacheCore.h"
#include <assert.h>
#include <stdio.h>

static void makeDirectory(const char *path) { assert(mkdir(path, 0700) == 0); }
static void makeFile(const char *path, size_t bytes) {
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0); assert(ftruncate(fd, (off_t)bytes) == 0); close(fd);
}
static int allow(const char *uuid, int fd, void *context) {
    (void)fd; (void)context;
    return !strcmp(uuid, "11111111-1111-1111-1111-111111111111");
}
static void path(char *out, const char *suffix) {
    assert(snprintf(out, 8192, "%s/%s", fixtureRoot, suffix) < 8192);
}
static void subdir(const char *suffix) { char p[8192]; path(p, suffix); makeDirectory(p); }
static void file(const char *suffix, size_t bytes) { char p[8192]; path(p, suffix); makeFile(p, bytes); }
static int exists(const char *suffix) { char p[8192]; struct stat s; path(p, suffix); return lstat(p, &s) == 0; }
#define APP "11111111-1111-1111-1111-111111111111"
#define OTHER "22222222-2222-2222-2222-222222222222"
#define CACHE APP "/Library/Caches/"
int main(void) {
    char temp[] = "/tmp/sjg-script-cache-XXXXXX";
    char *root = mkdtemp(temp); assert(root);
    assert(realpath(root, fixtureRoot));
    assert(SJGIsUUID(APP)); assert(!SJGIsUUID("../foo"));
    subdir(APP); subdir(APP "/Library"); subdir(APP "/Library/Caches");
    subdir(APP "/Documents"); subdir(APP "/Library/Preferences");
    subdir(OTHER); subdir(OTHER "/Library"); subdir(OTHER "/Library/Caches");
    subdir("not-a-uuid"); subdir("not-a-uuid/Library"); subdir("not-a-uuid/Library/Caches");
    file(CACHE "old", 123); file(APP "/Documents/keep", 7);
    file(APP "/Library/Preferences/keep", 7); file(OTHER "/Library/Caches/keep", 7);
    file("not-a-uuid/Library/Caches/keep", 7);
    char linkPath[8192], target[8192];
    path(linkPath, CACHE "link"); path(target, APP "/Documents/keep");
    assert(symlink(target, linkPath) == 0);
    path(linkPath, CACHE "linked-directory"); path(target, APP "/Documents");
    assert(symlink(target, linkPath) == 0);
    SJGCacheResult fresh = SJGCacheRun(allow, NULL, time(NULL));
    assert(fresh.removedCount == 0 && exists(CACHE "old"));
    /* Advance only the mock clock: also satisfies the ctime safety rule. */
    time_t now = time(NULL) + 8 * 24 * 60 * 60;
    SJGCacheResult old = SJGCacheRun(allow, NULL, now);
    assert(old.rootError == 0 && old.removedCount == 1 && old.removedBytes == 123);
    assert(!exists(CACHE "old") && exists(CACHE "link") && exists(CACHE "linked-directory"));
    assert(exists(APP "/Documents/keep") && exists(APP "/Library/Preferences/keep"));
    assert(exists(OTHER "/Library/Caches/keep") && exists("not-a-uuid/Library/Caches/keep"));
    file(CACHE "oversize", (size_t)SJG_CACHE_MAX_BYTES + 1);
    subdir(CACHE "nested"); file(CACHE "nested/old", 17);
    SJGCacheResult nested = SJGCacheRun(allow, NULL, now);
    assert(nested.removedCount == 1 && nested.removedBytes == 17);
    assert(exists(CACHE "oversize") && exists(CACHE "nested"));
    for (int i = 0; i < 1001; i++) {
        char suffix[128]; snprintf(suffix, sizeof(suffix), CACHE "many-%04d", i); file(suffix, 1);
    }
    SJGCacheResult bounded = SJGCacheRun(allow, NULL, now);
    assert(bounded.removedCount == 1000 && bounded.removedBytes == 1000 && bounded.limited);
    /* Teardown only this generated fixture, by explicit known names. */
    for (int i = 0; i < 1001; i++) {
        char suffix[128]; snprintf(suffix, sizeof(suffix), CACHE "many-%04d", i);
        path(target, suffix); unlink(target);
    }
    const char *files[] = {CACHE "oversize", CACHE "link", CACHE "linked-directory", APP "/Documents/keep",
        APP "/Library/Preferences/keep", OTHER "/Library/Caches/keep", "not-a-uuid/Library/Caches/keep"};
    for (unsigned i = 0; i < sizeof(files)/sizeof(*files); i++) { path(target, files[i]); assert(unlink(target) == 0); }
    const char *dirs[] = {CACHE "nested", APP "/Library/Caches", APP "/Library/Preferences", APP "/Documents",
        APP "/Library", APP, OTHER "/Library/Caches", OTHER "/Library", OTHER,
        "not-a-uuid/Library/Caches", "not-a-uuid/Library", "not-a-uuid"};
    for (unsigned i = 0; i < sizeof(dirs)/sizeof(*dirs); i++) { path(target, dirs[i]); assert(rmdir(target) == 0); }
    assert(rmdir(fixtureRoot) == 0);
    puts("PASS: fresh/old, UUID whitelist, inactive filter, symlinks, Documents/Preferences, nested directories, 128MiB/1000-file caps");
    return 0;
}
