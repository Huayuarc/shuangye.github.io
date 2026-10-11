#import "ScriptFeatures.h"
#import <dispatch/dispatch.h>
#include <sys/sysctl.h>
#include <stdint.h>
#include <errno.h>
#include <limits.h>
#include <dlfcn.h>
/* Darwin public SDKs may omit the private libproc header. Resolve only the
 * two stable C entry points; missing symbols make cleanup fail closed. */
#ifndef CTL_MAXNAME
#define CTL_MAXNAME 12
#endif
#ifndef CTL_SYSCTL
#define CTL_SYSCTL 0
#endif
#ifndef CTLTYPE
#define CTLTYPE 0xFU
#endif
#ifndef CTLTYPE_INT
#define CTLTYPE_INT 2
#endif
#ifndef CTLTYPE_QUAD
#define CTLTYPE_QUAD 4
#endif
#define SJG_PROC_ALL_PIDS 1U
#define SJG_PROC_PATH_SIZE 4096U
#include "ScriptCacheCore.h"

#ifndef SJG_SYSCTLBYNAME
#define SJG_SYSCTLBYNAME sysctlbyname
#endif

typedef struct {
    const char *key, *name;
    int64_t target, original, written;
    size_t width;
    BOOL hasOriginal, ownsWrite;
} SJGTune;
static SJGTune SJGTunes[] = {
    {"threadTune", "kern.wq_max_threads", 2048, 0, 0, 0, NO, NO},
    {"vnodeTune", "kern.maxvnodes", 20000, 0, 0, 0, NO, NO},
    {"sysprocsIdleTune", "kern.memorystatus_sysprocs_idle_delay_time", 1, 0, 0, 0, NO, NO},
    {"appsIdleTune", "kern.memorystatus_apps_idle_delay_time", 1, 0, 0, 0, NO, NO},
    {"pressureDelayTune", "kern.memorystatus_kill_on_sustained_pressure_delay_ms", 86400000, 0, 0, 0, NO, NO},
    {"vmWorkTune", "kern.vm_max_delayed_work_limit", 64, 0, 0, 0, NO, NO}
};
static dispatch_queue_t SJGQueue;
static char SJGQueueTag;
static NSMutableDictionary *SJGStates;
static NSDictionary *SJGLastClean;
static BOOL SJGMaster;
static void SJGSync(dispatch_block_t work) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SJGQueue = dispatch_queue_create("com.sbjetsamguard.scriptfeatures", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(SJGQueue, &SJGQueueTag, &SJGQueueTag, NULL);
        SJGStates = [[NSMutableDictionary alloc] init];
    });
    if (dispatch_get_specific(&SJGQueueTag)) work();
    else dispatch_sync(SJGQueue, work);
}
static BOOL SJGBool(NSDictionary *s, NSString *key) {
    id value = [s isKindOfClass:[NSDictionary class]] ? s[key] : nil;
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}
/* Query metadata type as well as the value width; strings/opaque values with
 * accidentally matching lengths must never be treated as integers. */
static BOOL SJGRead(SJGTune *t, int64_t *value, size_t *width, int *error) {
    int mib[CTL_MAXNAME]; size_t count = CTL_MAXNAME;
    if (sysctlnametomib(t->name, mib, &count)) { *error = errno; return NO; }
    if (count == 0 || count > CTL_MAXNAME) { *error = EINVAL; return NO; }
    int query[CTL_MAXNAME + 2] = {CTL_SYSCTL, 4}; /* Darwin CTL_SYSCTL_OIDFMT */
    memcpy(query + 2, mib, count * sizeof(int));
    struct { unsigned int kind; char format[256]; } metadata = {0};
    size_t metaLength = sizeof(metadata);
    if (sysctl(query, (u_int)count + 2, &metadata, &metaLength, NULL, 0)) {
        *error = errno; return NO;
    }
    unsigned type = metadata.kind & CTLTYPE;
    if (metaLength < sizeof(metadata.kind) ||
        (type != CTLTYPE_INT && type != CTLTYPE_QUAD)) { *error = EINVAL; return NO; }
    size_t length = 0;
    if (SJG_SYSCTLBYNAME(t->name, NULL, &length, NULL, 0)) { *error = errno; return NO; }
    size_t expected = type == CTLTYPE_INT ? sizeof(int32_t) : sizeof(int64_t);
    if (length != expected) { *error = EINVAL; return NO; }
    union { int32_t i32; int64_t i64; } data = {0};
    size_t actual = length;
    if (SJG_SYSCTLBYNAME(t->name, &data, &actual, NULL, 0)) { *error = errno; return NO; }
    if (actual != length) { *error = EINVAL; return NO; }
    *width = length; *value = length == sizeof(int32_t) ? data.i32 : data.i64;
    *error = 0; return YES;
}
static BOOL SJGWrite(SJGTune *t, int64_t value, int *error) {
    int rc;
    if (t->width == sizeof(int32_t)) {
        if (value < INT32_MIN || value > INT32_MAX) { *error = ERANGE; return NO; }
        int32_t v = (int32_t)value;
        rc = SJG_SYSCTLBYNAME(t->name, NULL, NULL, &v, sizeof(v));
    } else if (t->width == sizeof(int64_t)) {
        int64_t v = value;
        rc = SJG_SYSCTLBYNAME(t->name, NULL, NULL, &v, sizeof(v));
    } else { *error = EINVAL; return NO; }
    *error = rc ? errno : 0; return rc == 0;
}
static void SJGState(SJGTune *t, NSString *state, int error) {
    NSString *key = [NSString stringWithUTF8String:t->key];
    SJGStates[key] = @{@"state": state, @"errno": @(error),
        @"name": [NSString stringWithUTF8String:t->name], @"target": @(t->target),
        @"hasOriginal": @(t->hasOriginal), @"ownsWrite": @(t->ownsWrite),
        @"width": @(t->width), @"risky": @(!strcmp(t->key, "pressureDelayTune"))};
}
static void SJGRestoreOne(SJGTune *t) {
    if (!t->ownsWrite) { SJGState(t, @"disabled", 0); return; }
    int error = 0; int64_t current = 0; size_t width = 0;
    if (!SJGRead(t, &current, &width, &error)) { SJGState(t, @"restore-read-failed", error); return; }
    if (width != t->width || current != t->written) {
        t->ownsWrite = NO;
        SJGState(t, @"restore-skipped-external-change", 0); return;
    }
    if (!SJGWrite(t, t->original, &error)) { SJGState(t, @"restore-write-failed", error); return; }
    if (!SJGRead(t, &current, &width, &error)) { SJGState(t, @"restore-verify-failed", error); return; }
    if (width != t->width || current != t->original) {
        SJGState(t, @"restore-verify-mismatch", EIO); return;
    }
    t->ownsWrite = NO; SJGState(t, @"restored", 0);
}
static void SJGApplyOne(SJGTune *t) {
    int error = 0; int64_t current = 0; size_t width = 0;
    if (!SJGRead(t, &current, &width, &error)) {
        SJGState(t, error == EINVAL ? @"unsupported-type-or-width" : @"unsupported-or-unreadable", error); return;
    }
    if (t->hasOriginal && width != t->width) { SJGState(t, @"width-changed", EINVAL); return; }
    if (t->ownsWrite && current != t->written) {
        t->ownsWrite = NO;
        SJGState(t, @"external-change-conflict", EBUSY); return;
    }
    /* Snapshot once, including across repeated Apply/restore cycles. */
    if (!t->hasOriginal) { t->original = current; t->width = width; t->hasOriginal = YES; }
    if (current == t->target) { SJGState(t, t->ownsWrite ? @"applied" : @"already-target-unowned", 0); return; }
    if (!SJGWrite(t, t->target, &error)) {
        SJGState(t, (error == EPERM || error == EACCES || error == EROFS) ? @"readonly-or-denied" : @"write-failed", error); return;
    }
    /* Keep ownership even if verification fails: Restore still compares before writing. */
    t->written = t->target; t->ownsWrite = YES;
    if (!SJGRead(t, &current, &width, &error)) { SJGState(t, @"verify-read-failed", error); return; }
    if (width != t->width || current != t->written) { SJGState(t, @"verify-mismatch", EIO); return; }
    SJGState(t, @"applied", 0);
}
void SJGApplyScriptSettings(NSDictionary *settings) {
    SJGSync(^{ @autoreleasepool {
        SJGMaster = SJGBool(settings, @"experimentalSysctls");
        for (unsigned i = 0; i < sizeof(SJGTunes)/sizeof(*SJGTunes); i++) {
            SJGTune *t = &SJGTunes[i];
            if (SJGMaster && SJGBool(settings, [NSString stringWithUTF8String:t->key])) SJGApplyOne(t);
            else SJGRestoreOne(t);
        }
    }});
}
void SJGRestoreScriptSettings(void) {
    SJGSync(^{ @autoreleasepool {
        SJGMaster = NO;
        for (unsigned i = 0; i < sizeof(SJGTunes)/sizeof(*SJGTunes); i++) SJGRestoreOne(&SJGTunes[i]);
    }});
}

static NSString *SJGReadContainerIdentifier(int fd) {
    const char *name = ".com.apple.mobile_container_manager.metadata.plist";
    int file = openat(fd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (file < 0) return nil;
    struct stat st;
    if (fstat(file, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1 ||
        st.st_size <= 0 || st.st_size > 65536) { close(file); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    size_t done = 0;
    while (done < (size_t)st.st_size) {
        ssize_t n = read(file, (char *)[data mutableBytes] + done, (size_t)st.st_size - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(file); return nil; }
        done += (size_t)n;
    }
    close(file);
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    id identifier = [plist isKindOfClass:[NSDictionary class]] ? plist[@"MCMMetadataIdentifier"] : nil;
    return [identifier isKindOfClass:[NSString class]] && [identifier length] > 0 ? identifier : nil;
}
/* Fail closed if any live process cannot be inspected or an app cannot be
 * mapped to its identifier. Only process executable paths / bundle Info.plist
 * are inspected; no arbitrary user directory scan is performed. */
static NSSet *SJGRunningApps(NSMutableSet *dataUUIDs) {
    typedef int (*SJGListPidsFn)(uint32_t, uint32_t, void *, int);
    typedef int (*SJGPidPathFn)(int, void *, uint32_t);
    static SJGListPidsFn listPids;
    static SJGPidPathFn pidPath;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        listPids = (SJGListPidsFn)dlsym(RTLD_DEFAULT, "proc_listpids");
        pidPath = (SJGPidPathFn)dlsym(RTLD_DEFAULT, "proc_pidpath");
    });
    if (!listPids || !pidPath) return nil;
    int bytes = listPids(SJG_PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0 || bytes > 4 * 1024 * 1024) return nil;
    int capacity = bytes + 4096;
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids) return nil;
    int used = listPids(SJG_PROC_ALL_PIDS, 0, pids, capacity);
    if (used <= 0 || used >= capacity) { free(pids); return nil; }
    NSMutableSet *apps = [NSMutableSet set]; BOOL okay = YES;
    for (int i = 0; i < used / (int)sizeof(pid_t); i++) {
        if (pids[i] <= 0) continue;
        char path[SJG_PROC_PATH_SIZE] = {0}; errno = 0;
        int length = pidPath(pids[i], path, (uint32_t)sizeof(path));
        if (length <= 0) { if (errno == ESRCH) continue; okay = NO; break; }
        if (length >= (int)sizeof(path) - 1) { okay = NO; break; }
        NSString *executable = [NSString stringWithUTF8String:path];
        if (!executable) { okay = NO; break; }
        NSString *marker = @"/Containers/Data/Application/";
        NSRange dataRange = [executable rangeOfString:marker options:NSCaseInsensitiveSearch];
        if (dataRange.location != NSNotFound) {
            NSString *suffix = [executable substringFromIndex:NSMaxRange(dataRange)];
            NSString *uuid = [[suffix componentsSeparatedByString:@"/"] firstObject];
            if (SJGIsUUID([uuid UTF8String])) [dataUUIDs addObject:[uuid uppercaseString]];
        }
        NSRange appRange = [executable rangeOfString:@".app/"];
        if (appRange.location == NSNotFound) continue;
        NSString *bundle = [executable substringToIndex:appRange.location + 4];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
        id identifier = info[@"CFBundleIdentifier"];
        if (![identifier isKindOfClass:[NSString class]] || ![identifier length]) { okay = NO; break; }
        [apps addObject:identifier];
    }
    free(pids); return okay ? [NSSet setWithSet:apps] : nil;
}
typedef struct { unsigned runningSkipped, unverifiedSkipped; BOOL visibilityFailed; } SJGEligibility;
static int SJGAllowContainer(const char *uuid, int fd, void *context) {
    SJGEligibility *eligibility = context;
    NSString *identifier = SJGReadContainerIdentifier(fd);
    if (!identifier) { eligibility->unverifiedSkipped++; return 0; }
    NSMutableSet *dataUUIDs = [NSMutableSet set];
    NSSet *running = SJGRunningApps(dataUUIDs);
    if (!running) { eligibility->visibilityFailed = YES; return 0; }
    NSString *uuidString = [[NSString stringWithUTF8String:uuid] uppercaseString];
    if ([running containsObject:identifier] || [dataUUIDs containsObject:uuidString]) {
        eligibility->runningSkipped++; return 0;
    }
    return 1;
}
NSDictionary *SJGCleanCaches(NSDictionary *settings) {
    __block NSDictionary *answer;
    SJGSync(^{ @autoreleasepool {
        if (!SJGBool(settings, @"cleanAppCaches")) {
            answer = @{@"state": @"disabled", @"reason": @"cleanAppCaches defaults to NO; manual cleanup was not performed.",
                @"removedBytes": @0, @"removedCount": @0};
        } else {
            NSMutableSet *dataUUIDs = [NSMutableSet set];
            if (!SJGRunningApps(dataUUIDs)) {
                answer = @{@"state": @"skipped-process-visibility", @"reason": @"Cannot reliably exclude all running apps; no files removed.",
                    @"removedBytes": @0, @"removedCount": @0};
            } else {
                SJGEligibility eligibility = {0};
                SJGCacheResult result = SJGCacheRun(SJGAllowContainer, &eligibility, time(NULL));
                NSString *state = result.rootError ? @"root-unavailable" :
                    eligibility.visibilityFailed ? @"partial-process-visibility" :
                    result.limited ? @"bounded-stop" : result.errors ? @"completed-with-errors" : @"completed";
                answer = @{@"state": state, @"removedBytes": @(result.removedBytes),
                    @"removedCount": @(result.removedCount), @"skipped": @(result.skipped),
                    @"errors": @(result.errors), @"errno": @(result.rootError),
                    @"containers": @(result.containers), @"visited": @(result.visited),
                    @"runningContainersSkipped": @(eligibility.runningSkipped),
                    @"unverifiedContainersSkipped": @(eligibility.unverifiedSkipped),
                    @"limitReached": @(result.limited),
                    @"reason": @"Manual only; inactive verified app Library/Caches regular files older than seven days. Byte count is logical file size, not guaranteed disk space reclaimed."};
            }
        }
#if !__has_feature(objc_arc)
        [SJGLastClean release];
#endif
        SJGLastClean = [answer copy];
        /* Independent immutable result survives a later cleanup under MRC too. */
        answer = [SJGLastClean copy];
    }});
#if !__has_feature(objc_arc)
    return [answer autorelease];
#else
    return answer;
#endif
}
NSDictionary *SJGScriptStatus(void) {
    __block NSDictionary *answer;
    SJGSync(^{ @autoreleasepool {
        for (unsigned i = 0; i < sizeof(SJGTunes)/sizeof(*SJGTunes); i++) {
            SJGTune *t = &SJGTunes[i];
            if (!SJGStates[[NSString stringWithUTF8String:t->key]]) SJGState(t, @"disabled", 0);
        }
        answer = @{@"experimentalSysctls": @(SJGMaster), @"sysctls": [NSDictionary dictionaryWithDictionary:SJGStates],
            @"pressureDelayWarning": @"pressureDelayTune defaults to NO. The 86400000 ms (24 hour) pressure delay is risky: prolonged memory pressure, stalls or instability are possible. Not a Jetsam priority change or kill-disable switch.",
            @"cleanup": SJGLastClean ?: @{@"state": @"not-requested", @"removedBytes": @0, @"removedCount": @0},
            @"cleanupPolicy": @"Manual notification handler only; cleanAppCaches defaults to NO. No startup/refresh/stop cleanup.",
            @"snapshots": @"In-memory per helper lifetime; preserved across repeated settings refreshes. Orderly stop must call Restore."};
#if !__has_feature(objc_arc)
        [answer retain];
#endif
    }});
#if !__has_feature(objc_arc)
    return [answer autorelease];
#else
    return answer;
#endif
}
