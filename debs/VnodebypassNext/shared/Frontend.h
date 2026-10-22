#ifndef VB_FRONTEND_H
#define VB_FRONTEND_H
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

#define VB_HELPER_PATH "/var/jb/usr/bin/vnodebypass"
#define VB_STATE_DARWIN "kr.xsf1re.vnodebypass.next.statechange"
#define VB_FRONTEND_UPDATED @"VBFrontendUpdated"

@interface VBResult : NSObject
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *message;
@property(nonatomic) NSUInteger hidden;
@property(nonatomic) NSUInteger total;
@property(nonatomic) int exitCode;
@property(nonatomic) BOOL success;
@end

// Public methods and properties are main-thread-only. All process work runs on
// one private serial queue. No preferences, kernel code or filesystem probes
// are used to infer the hiding state.
@interface VBFrontend : NSObject
@property(nonatomic, readonly) VBResult *result;
@property(nonatomic, readonly, getter=isBusy) BOOL busy;
@property(nonatomic, readonly, copy) NSString *lastOperationMessage;
+ (instancetype)shared;
- (void)query;
- (void)performCommand:(NSString *)command;
@end

static inline NSString *VBStateTitle(NSString *state) {
    if ([state isEqual:@"enabled"]) return @"已启用 · 全局隐藏";
    if ([state isEqual:@"disabled"]) return @"已关闭 · 未隐藏";
    if ([state isEqual:@"mixed"]) return @"部分隐藏 · 状态不一致";
    if ([state isEqual:@"legacy"]) return @"旧版状态 · 需要检查";
    if ([state isEqual:@"busy"]) return @"Helper 正忙";
    return @"状态错误 / 无法读取";
}
static inline NSString *VBEnableWarning(void) {
    return @"vnodebypass 会全局隐藏越狱相关文件，可能影响其他插件、工具和应用。仅在需要时启用；使用后请自行点击关闭。本程序不会自动恢复。是否明确启用？";
}

#ifdef VB_FRONTEND_IMPLEMENTATION
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <math.h>

extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *, gid_t);

@implementation VBResult
@end

static VBResult *VBError(NSString *message, int code) {
    VBResult *r = [VBResult new];
    r.state = @"error"; r.message = message; r.exitCode = code; r.success = NO;
    return r;
}
static VBResult *VBErrno(NSString *stage, int code) {
    return VBError([NSString stringWithFormat:@"%@: %s (%d)", stage, strerror(code), code], code);
}
static BOOL VBValidCount(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double d = [value doubleValue];
    return isfinite(d) && d >= 0 && d <= (double)NSIntegerMax && floor(d) == d;
}
// Keep all child descriptors away from standard descriptors, even if a host
// process happened to launch with stdin/stdout/stderr closed.
static int VBMoveFD(int fd) {
    if (fd < 0) return -1;
    if (fd >= 3) {
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) == 0) return fd;
        int e = errno; close(fd); errno = e; return -1;
    }
    int n = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    int e = errno; close(fd); errno = e; return n;
}
static VBResult *VBRunHelper(NSString *command) {
    @autoreleasepool {
        if (![@[@"status", @"enable", @"disable"] containsObject:command])
            return VBError(@"拒绝未知 helper 命令", EINVAL);
        struct stat st;
        if (stat(VB_HELPER_PATH, &st) != 0) return VBErrno(@"无法访问固定 helper 路径", errno);
        if (!S_ISREG(st.st_mode)) return VBError(@"helper 不是普通可执行文件", EINVAL);
        if (access(VB_HELPER_PATH, X_OK) != 0) return VBErrno(@"helper 不可执行", errno);
        int p[2];
        if (pipe(p) != 0) return VBErrno(@"创建 stdout 管道失败", errno);
        int rd = VBMoveFD(p[0]), e = errno;
        if (rd < 0) { close(p[1]); return VBErrno(@"配置管道失败", e); }
        int wr = VBMoveFD(p[1]); e = errno;
        if (wr < 0) { close(rd); return VBErrno(@"配置管道失败", e); }
        int nullfd = VBMoveFD(open("/dev/null", O_RDWR)); e = errno;
        if (nullfd < 0) { close(rd); close(wr); return VBErrno(@"打开 /dev/null 失败", e); }
        posix_spawnattr_t attr;
        posix_spawn_file_actions_t actions;
        BOOL attrOK = NO, actionsOK = NO;
        int rc = posix_spawnattr_init(&attr);
        if (rc == 0) {
            attrOK = YES;
            rc = posix_spawnattr_set_persona_np(&attr, 99, 1 /* OVERRIDE */);
        }
        if (rc == 0) rc = posix_spawnattr_set_persona_uid_np(&attr, 0);
        if (rc == 0) rc = posix_spawnattr_set_persona_gid_np(&attr, 0);
        if (rc == 0) { rc = posix_spawn_file_actions_init(&actions); actionsOK = (rc == 0); }
        if (rc == 0) rc = posix_spawn_file_actions_adddup2(&actions, wr, STDOUT_FILENO);
        if (rc == 0) rc = posix_spawn_file_actions_adddup2(&actions, nullfd, STDIN_FILENO);
        if (rc == 0) rc = posix_spawn_file_actions_adddup2(&actions, nullfd, STDERR_FILENO);
        if (rc == 0) rc = posix_spawn_file_actions_addclose(&actions, rd);
        if (rc == 0) rc = posix_spawn_file_actions_addclose(&actions, wr);
        if (rc == 0) rc = posix_spawn_file_actions_addclose(&actions, nullfd);
        pid_t pid = -1;
        char *argv[] = { (char *)VB_HELPER_PATH, (char *)command.UTF8String, NULL };
        // Do not inherit DYLD or caller environment variables into the root child.
        char *envp[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", NULL };
        if (rc == 0) rc = posix_spawn(&pid, VB_HELPER_PATH, &actions, &attr, argv, envp);
        if (actionsOK) posix_spawn_file_actions_destroy(&actions);
        if (attrOK) posix_spawnattr_destroy(&attr);
        close(wr); close(nullfd);
        if (rc != 0) { close(rd); return VBErrno(@"persona 99/root 启动 helper 失败", rc); }
        NSMutableData *data = [NSMutableData data];
        char buffer[4096]; BOOL overflow = NO; int readError = 0;
        for (;;) {
            ssize_t n = read(rd, buffer, sizeof(buffer));
            if (n < 0 && errno == EINTR) continue;
            if (n < 0) { readError = errno; break; }
            if (n == 0) break;
            if (data.length + (NSUInteger)n <= 1024 * 1024 && !overflow)
                [data appendBytes:buffer length:(NSUInteger)n];
            else overflow = YES; // Keep draining to avoid a full-pipe deadlock.
        }
        close(rd);
        int status = 0; pid_t waited;
        do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
        if (waited < 0) return VBErrno(@"waitpid 失败", errno);
        if (readError) return VBErrno(@"读取 helper stdout 失败", readError);
        int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) :
                       (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1);
        if (overflow) return VBError(@"helper 输出超过 1 MiB", exitCode ?: EOVERFLOW);
        NSError *error = nil; NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
        id plist = [NSPropertyListSerialization propertyListWithData:data
            options:NSPropertyListImmutable format:&format error:&error];
        if (![plist isKindOfClass:NSDictionary.class] || format != NSPropertyListXMLFormat_v1_0)
            return VBError([NSString stringWithFormat:@"helper 未输出 XML 字典 (exit=%d): %@", exitCode,
                            error.localizedDescription ?: @"输出格式不匹配"], exitCode ?: EPROTO);
        NSDictionary *d = plist;
        if (![@[@"disabled", @"enabled", @"mixed", @"error", @"legacy", @"busy"] containsObject:d[@"state"] ?: @""] ||
            ![d[@"message"] isKindOfClass:NSString.class] || !VBValidCount(d[@"hidden"]) ||
            !VBValidCount(d[@"total"]) || [d[@"hidden"] unsignedLongLongValue] > [d[@"total"] unsignedLongLongValue])
            return VBError(@"helper plist 字段无效", exitCode ?: EPROTO);
        VBResult *r = [VBResult new];
        r.state = d[@"state"]; r.message = d[@"message"];
        r.hidden = [d[@"hidden"] unsignedIntegerValue]; r.total = [d[@"total"] unsignedIntegerValue];
        r.exitCode = exitCode;
        r.success = exitCode == 0 && ![r.state isEqual:@"error"] && ![r.state isEqual:@"busy"];
        if (exitCode != 0) r.message = [NSString stringWithFormat:@"%@ (helper exit=%d)", r.message, exitCode];
        return r;
    }
}

@interface VBFrontend ()
@property(nonatomic, readwrite) VBResult *result;
@property(nonatomic, readwrite, getter=isBusy) BOOL busy;
@property(nonatomic, readwrite, copy) NSString *lastOperationMessage;
@property(nonatomic) dispatch_queue_t worker;
@property(nonatomic) BOOL queryPending;
@end

static void VBDarwinChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef info) {
    VBFrontend *client = (__bridge VBFrontend *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [client query]; });
}
@implementation VBFrontend
+ (instancetype)shared {
    static VBFrontend *instance; static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [VBFrontend new]; }); return instance;
}
- (instancetype)init {
    if ((self = [super init])) {
        _worker = dispatch_queue_create("kr.xsf1re.vnodebypass.next.frontend", DISPATCH_QUEUE_SERIAL);
        _result = VBError(@"尚未查询", 0); _lastOperationMessage = @"";
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge void *)self,
            VBDarwinChanged, CFSTR(VB_STATE_DARWIN), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        dispatch_async(dispatch_get_main_queue(), ^{ [self query]; });
    } return self;
}
- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge void *)self,
                                      CFSTR(VB_STATE_DARWIN), NULL);
}
- (void)publish {
    [[NSNotificationCenter defaultCenter] postNotificationName:VB_FRONTEND_UPDATED object:self];
}
- (void)query {
    NSAssert(NSThread.isMainThread, @"Frontend must be called on the main thread");
    if (self.busy) { self.queryPending = YES; return; }
    self.busy = YES; [self publish];
    dispatch_async(self.worker, ^{
        VBResult *r = VBRunHelper(@"status");
        dispatch_async(dispatch_get_main_queue(), ^{
            self.result = r; self.busy = NO; [self publish];
            if (self.queryPending) { self.queryPending = NO; [self query]; }
        });
    });
}
- (void)performCommand:(NSString *)command {
    NSAssert(NSThread.isMainThread, @"Frontend must be called on the main thread");
    if (self.busy || ![@[@"enable", @"disable"] containsObject:command]) return;
    self.busy = YES; self.lastOperationMessage = @""; [self publish];
    dispatch_async(self.worker, ^{
        VBResult *operation = VBRunHelper(command);
        VBResult *current = VBRunHelper(@"status"); // Never optimistically flip UI.
        NSString *verb = [command isEqual:@"enable"] ? @"启用" : @"关闭";
        NSString *message = [NSString stringWithFormat:@"%@%@：%@", verb,
                             operation.success ? @"完成" : @"未成功", operation.message];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.result = current; self.lastOperationMessage = message;
            self.busy = NO; self.queryPending = NO; [self publish];
            // All receivers, including this instance, only issue a status query.
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                  CFSTR(VB_STATE_DARWIN), NULL, NULL, true);
        });
    });
}
@end
#endif // VB_FRONTEND_IMPLEMENTATION
#endif // VB_FRONTEND_H
