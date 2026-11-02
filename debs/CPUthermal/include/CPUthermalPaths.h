#ifndef CPUTHERMAL_PATHS_H
#define CPUTHERMAL_PATHS_H

#import <Foundation/Foundation.h>
#import <notify.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <roothide.h>

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kCPUthermalPrefRootFSPathC = "/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist";
static const char *kCPUthermalOldJBPrefRelativePathC = "Library/Preferences/com.huayuarc.cputhermal.plist";
// isolation.18: live preferences live inside the jailbreak root (same model as Hello 120Hz),
// so var-cleaner / blacklist tools scanning the real /var/mobile/Library/Preferences do not see it.
static const char *kCPUthermalPrefJBRelativePathC = "var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist";
static const char *kCPUthermalSettingsChangedNotifC = "com.huayuarc.cputhermal/settingsChanged";
static const char *kCPUthermalSmartChargeCutoffNotifC = "com.huayuarc.cputhermal/smartChargeCutoffState";

static inline void CPUthermalPostSmartChargeCutoffState(BOOL active) {
    int token = 0;
    if (notify_register_check(kCPUthermalSmartChargeCutoffNotifC, &token) != NOTIFY_STATUS_OK) return;
    notify_set_state(token, active ? 1 : 0);
    notify_post(kCPUthermalSmartChargeCutoffNotifC);
    notify_cancel(token);
}

static inline BOOL CPUthermalSmartChargeCutoffState(void) {
    int token = 0;
    uint64_t state = 0;
    if (notify_register_check(kCPUthermalSmartChargeCutoffNotifC, &token) != NOTIFY_STATUS_OK) return NO;
    int result = notify_get_state(token, &state);
    notify_cancel(token);
    return result == NOTIFY_STATUS_OK && state == 1;
}

static inline NSString *CPUthermalStringFromCPath(const char *path) {
    return path ? [NSString stringWithUTF8String:path] : nil;
}

static inline NSString *CPUthermalJBRootPathForRootFSPath(const char *path) {
    if (!path) return nil;

    // 优先尝试通过 jbroot 转换路径
    const char *jbPath = jbroot(path);
    if (jbPath && strlen(jbPath) > 0) {
        NSString *converted = [NSString stringWithUTF8String:jbPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:converted]) {
            return converted;
        }
    }

    // 兜底 1: 检查 /var/jb 相对路径
    NSString *varJBPath = [S("/var/jb") stringByAppendingPathComponent:[NSString stringWithUTF8String:path]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:varJBPath]) {
        return varJBPath;
    }

    // 兜底 2: 返回原始路径
    return [NSString stringWithUTF8String:path];
}

// ============================================================================
// isolation.15 偏好持久化加固
//   rootless（Dopamine）链路根因：① 兼容层路径探测让偏好落点漂移（写入可能落到
//   /var/jb/var/mobile/... 这类镜像/别名路径，Settings 进程写入静默失败）；
//   ② "清理旧副本"用字符串比较，把与当前路径互为别名（同一 inode）的有效文件删除；
//   ③ writeToFile 返回 YES 并不保证内容真的落盘/可读回。
//   加固：路径判定数据锚定、删除加"同文件 + RootHide 闸门"、写入读回校验 + 重试 + 规范路径回退。
// ============================================================================

// 同一文件判定：stat() 比较 st_dev + st_ino；任一不存在返回 NO（两文件都存在才可能为同一文件）。
static inline BOOL CPUthermalSameFile(NSString *a, NSString *b) {
    if (!a || !b || a.length == 0 || b.length == 0) return NO;
    struct stat infoA;
    struct stat infoB;
    if (stat(a.fileSystemRepresentation, &infoA) != 0) return NO;
    if (stat(b.fileSystemRepresentation, &infoB) != 0) return NO;
    return infoA.st_dev == infoB.st_dev && infoA.st_ino == infoB.st_ino;
}

// RootHide 根内的偏好路径（<root>/var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist）。
static inline NSString *CPUthermalRootHidePrefPathForRoot(NSString *root) {
    if (root.length == 0) return nil;
    return [[root stringByAppendingPathComponent:S("var/mobile/Library/Preferences")]
        stringByAppendingPathComponent:S("com.huayuarc.cputhermal.plist")];
}

// 当前 .jbroot-UUID 根选择（数据锚定评分）：
//   含本插件偏好的根 +10000（优先于仅含 dylib 的 +1000），其后 dylib +1000、
//   Library/MobileSubstrate +100、usr/lib +10，同分再按 mtime 最新。
// 目的：同一份数据在所有进程（Settings / thermalmonitord / SpringBoard）稳定解析到同一个根，
// 避免"写着 A 根、读着 B 根"。
static inline NSString *CPUthermalCurrentRootHideRoot(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *appGroupRoot = S("/var/mobile/Containers/Shared/AppGroup");
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:appGroupRoot error:nil];
    NSString *bestRoot = nil;
    NSInteger bestScore = NSIntegerMin;
    NSDate *bestDate = nil;

    for (NSString *entry in entries) {
        if (![entry hasPrefix:S(".jbroot-")]) continue;
        NSString *root = [appGroupRoot stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:root isDirectory:&isDirectory] || !isDirectory) continue;

        NSInteger score = 0;
        if ([fileManager fileExistsAtPath:CPUthermalRootHidePrefPathForRoot(root)]) score += 10000;   // 数据锚定
        NSString *tweakPath = [root stringByAppendingPathComponent:S("Library/MobileSubstrate/DynamicLibraries/CPUthermal.dylib")];
        NSString *substratePath = [root stringByAppendingPathComponent:S("Library/MobileSubstrate")];
        NSString *usrLibPath = [root stringByAppendingPathComponent:S("usr/lib")];
        if ([fileManager fileExistsAtPath:tweakPath]) score += 1000;
        if ([fileManager fileExistsAtPath:substratePath]) score += 100;
        if ([fileManager fileExistsAtPath:usrLibPath]) score += 10;

        NSDictionary *attributes = [fileManager attributesOfItemAtPath:root error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!bestRoot || score > bestScore || (score == bestScore && [date compare:bestDate] == NSOrderedDescending)) {
            bestRoot = root;
            bestScore = score;
            bestDate = date;
        }
    }
    return bestRoot;
}

// 规范偏好路径：RootHide（存在 .jbroot-* 根）= 当前根；rootless = 真实 var 路径。
// 写入失败回退与迁移都以此为唯一落点。
// Rootless preference root: /var/jb/var/mobile/Library/Preferences (inside the jailbreak root).
static inline NSString *CPUthermalRootlessPrefPath(void) {
    NSString *jbRoot = S("/var/jb");
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:jbRoot isDirectory:&isDirectory] && isDirectory) {
        return [jbRoot stringByAppendingPathComponent:S(kCPUthermalPrefJBRelativePathC)];
    }
    return CPUthermalStringFromCPath(kCPUthermalPrefRootFSPathC);
}

static inline NSString *CPUthermalCanonicalPrefPath(void) {
    NSString *rootHideRoot = CPUthermalCurrentRootHideRoot();
    if (rootHideRoot.length > 0) return CPUthermalRootHidePrefPathForRoot(rootHideRoot);
    return CPUthermalRootlessPrefPath();
}

static inline NSString *CPUthermalCurrentPrefPath(void) {
    // RootHide 分支保持 .jbroot- 路径（根由 CPUthermalCurrentRootHideRoot 数据锚定评分选出）。
    NSString *rootHideRoot = CPUthermalCurrentRootHideRoot();
    if (rootHideRoot.length > 0) return CPUthermalRootHidePrefPathForRoot(rootHideRoot);

    // Rootless 分支：写入越狱根内的 var/mobile/Library/Preferences，避开 var 清理工具。
    return CPUthermalRootlessPrefPath();
}

// 旧副本删除闸门：同时满足 (1) RootHide 模式（当前路径在 .jbroot 根内）与
// (2) 与当前路径不是同一文件（stat 判定）才允许删除；rootless 一律不执行任何删除。
// Deletion gate: only known legacy locations may be removed, never the live file or an alias
// of it. Rootless old copies (real var + mirrored jb path) are removed after a verified
// migration so var-cleaner tools can no longer discover the settings.
static inline BOOL CPUthermalPrefDeletionAllowed(NSString *currentPath, NSString *candidate) {
    if (!currentPath || !candidate || candidate.length == 0) return NO;
    if (CPUthermalSameFile(candidate, currentPath)) return NO;
    if ([currentPath containsString:S("/Containers/Shared/AppGroup/.jbroot-")]) return YES;
    NSString *legacyRootFS = CPUthermalStringFromCPath(kCPUthermalPrefRootFSPathC);
    if ([candidate isEqualToString:legacyRootFS]) return YES;
    NSString *jbRoot = S("/var/jb");
    NSString *mirrored = [jbRoot stringByAppendingPathComponent:S(kCPUthermalPrefJBRelativePathC)];
    if ([candidate isEqualToString:mirrored]) return NO;
    NSString *resolved = [jbRoot stringByResolvingSymlinksInPath];
    if ([candidate hasPrefix:resolved] || [candidate hasPrefix:jbRoot]) return YES;
    return NO;
}

static inline NSString *CPUthermalOldJBRootPrefPath(void) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *resolvedJBRoot = [fileManager destinationOfSymbolicLinkAtPath:S("/var/jb") error:nil];
    if (resolvedJBRoot.length > 0) {
        return [resolvedJBRoot stringByAppendingPathComponent:S(kCPUthermalOldJBPrefRelativePathC)];
    }
    return [S("/var/jb") stringByAppendingPathComponent:S(kCPUthermalOldJBPrefRelativePathC)];
}

static inline void CPUthermalAppendUniquePath(NSMutableArray<NSString *> *paths, NSString *path) {
    if (path.length > 0 && ![paths containsObject:path]) [paths addObject:path];
}

static inline NSArray<NSString *> *CPUthermalLegacyPrefPaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // 1) 全部 .jbroot-* 根内的偏好副本（RootHide 重新生成环境后 UUID 会变化，需扫描迁移）。
    NSString *appGroupRoot = S("/var/mobile/Containers/Shared/AppGroup");
    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:appGroupRoot error:nil];
    for (NSString *entry in entries) {
        if (![entry hasPrefix:S(".jbroot-")]) continue;
        NSString *root = [appGroupRoot stringByAppendingPathComponent:entry];
        CPUthermalAppendUniquePath(paths, CPUthermalRootHidePrefPathForRoot(root));
    }

    // 2) 解析后的旧 JB Library/Preferences 路径（/var/jb -> 真实目录）。
    CPUthermalAppendUniquePath(paths, CPUthermalOldJBRootPrefPath());

    // 3) isolation.15：jbroot 转换路径变体及其 symlink 解析变体（rootless 迁移读取的主要来源）。
    CPUthermalAppendUniquePath(paths, [S("/var/jb") stringByAppendingPathComponent:S("var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist")]);
    NSString *resolvedJBRoot = [fileManager destinationOfSymbolicLinkAtPath:S("/var/jb") error:nil];
    if (resolvedJBRoot.length > 0) {
        CPUthermalAppendUniquePath(paths, [resolvedJBRoot stringByAppendingPathComponent:S("var/mobile/Library/Preferences/com.huayuarc.cputhermal.plist")]);
    }

    // 4) isolation.18：越狱根内的当前落点与真实 var（旧版本）副本。
    CPUthermalAppendUniquePath(paths, CPUthermalRootlessPrefPath());
    CPUthermalAppendUniquePath(paths, CPUthermalStringFromCPath(kCPUthermalPrefRootFSPathC));
    return paths;
}

static inline NSString *CPUthermalExistingExecutablePath(const char *rootFSPath, NSArray<NSString *> *fallbackPaths) {
    if (!rootFSPath) return nil;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *resolvedPath = CPUthermalJBRootPathForRootFSPath(rootFSPath);
    if (resolvedPath.length > 0 && [fileManager isExecutableFileAtPath:resolvedPath]) {
        return resolvedPath;
    }

    for (NSString *path in fallbackPaths) {
        if (path.length > 0 && [fileManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static inline NSString *CPUthermalLaunchctlPath(void) {
    return CPUthermalExistingExecutablePath("/usr/bin/launchctl", @[
        S("/var/jb/usr/bin/launchctl"),
        S("/var/jb/bin/launchctl"),
        S("/usr/bin/launchctl"),
        S("/bin/launchctl")
    ]);
}

static inline NSString *CPUthermalToolPath(void) {
    return CPUthermalExistingExecutablePath("/usr/local/bin/CPUthermalTool", @[
        S("/var/jb/usr/local/bin/CPUthermalTool"),
        S("/usr/local/bin/CPUthermalTool")
    ]);
}

static inline void CPUthermalEnsureDirectoryForPath(NSString *path) {
    if (path.length == 0) return;
    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
}

static inline void CPUthermalEnsurePrefDirectory(void) {
    CPUthermalEnsureDirectoryForPath(CPUthermalCurrentPrefPath());
}

// 偏好值等价比较（面板读回校验用）：NSNumber 走 isEqualToNumber，NSString 走 isEqualToString。
static inline BOOL CPUthermalPrefValueEquals(id stored, id desired) {
    if (stored == nil || desired == nil) return stored == desired;
    if ([stored isKindOfClass:[NSNumber class]] && [desired isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)stored isEqualToNumber:(NSNumber *)desired];
    }
    if ([stored isKindOfClass:[NSString class]] && [desired isKindOfClass:[NSString class]]) {
        return [(NSString *)stored isEqualToString:(NSString *)desired];
    }
    return [stored isEqual:desired];
}

// ============================================================================
// isolation.15：偏好文件属主/权限修复（根因定案）
//   真机证据：模块（root）写文件后属主 root:wheel 且权限不含 mobile（mobile 不可读），
//   设置面板进程（mobile）读不到 → 面板以"空字典 + 单个键"整文件覆盖 → 每开一个开关
//   就抹掉其它键；核心 loadPrefs 的 powerMode 自愈（root 写）又把文件重写成 root 属主。
//   修复：所有写入成功后把文件属主改回 mobile(501:501)、权限 0644（best-effort，失败静默），
//   让面板（mobile）恢复可读写；postinst 与核心 %ctor 亦各补一次。
// ============================================================================

static inline void CPUthermalFixPrefOwnership(NSString *path) {
    if (path.length == 0) return;
    const char *filePath = path.fileSystemRepresentation;
    if (!filePath) return;
    // best-effort：文件不存在或权限不足时静默失败，不改变任何调用方的返回值语义。
    chown(filePath, 501, 501);   // mobile:mobile
    chmod(filePath, 0644);
}

// 写入单个路径并读回校验：全等才判定成功——writeToFile 返回 YES 不保证读回内容一致。
static inline BOOL CPUthermalWritePrefsAtPathVerified(NSDictionary *prefs, NSString *path) {
    if (!prefs || path.length == 0) return NO;
    CPUthermalEnsureDirectoryForPath(path);
    if (![prefs writeToFile:path atomically:YES]) return NO;
    NSDictionary *readBack = [NSDictionary dictionaryWithContentsOfFile:path];
    return readBack && [readBack isEqualToDictionary:prefs];
}

static inline NSMutableDictionary *CPUthermalReadMutablePrefs(void) {
    NSString *path = CPUthermalCurrentPrefPath();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (prefs) {
        // 当前配置有效时，清理真实 var 和旧 UUID 副本，避免被 var 清理继续识别。
        // isolation.15：删除必须通过闸门——RootHide 模式且与当前文件不同一；
        // rootless（Dopamine）一律不删除，防止 /var/jb 与真实路径互为别名时误删有效偏好。
        for (NSString *legacyPath in CPUthermalLegacyPrefPaths()) {
            if (CPUthermalPrefDeletionAllowed(path, legacyPath)) {
                [fileManager removeItemAtPath:legacyPath error:nil];
            }
        }
        return prefs;
    }

    NSString *newestLegacyPath = nil;
    NSDictionary *newestLegacyPrefs = nil;
    NSDate *newestDate = nil;
    NSArray<NSString *> *legacyPaths = CPUthermalLegacyPrefPaths();
    for (NSString *legacyPath in legacyPaths) {
        if ([legacyPath isEqualToString:path]) continue;
        if (CPUthermalSameFile(legacyPath, path)) continue;   // 别名（同一 inode）无需再读
        NSDictionary *legacyPrefs = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
        if (!legacyPrefs) continue;
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:legacyPath error:nil];
        NSDate *date = attributes[NSFileModificationDate] ?: [NSDate distantPast];
        if (!newestLegacyPrefs || [date compare:newestDate] == NSOrderedDescending) {
            newestLegacyPath = legacyPath;
            newestLegacyPrefs = legacyPrefs;
            newestDate = date;
        }
    }

    if (newestLegacyPrefs) {
        // 迁移：读取最新旧副本，写入规范路径（rootless=真实 var；RootHide=当前根）；
        // rootless 下迁移后不删除任何原文件。
        prefs = [newestLegacyPrefs mutableCopy];
        NSString *canonicalPath = CPUthermalCanonicalPrefPath();
        if (CPUthermalWritePrefsAtPathVerified(prefs, canonicalPath)) {
            CPUthermalFixPrefOwnership(canonicalPath);   // 迁移写入同样修复属主/权限
            for (NSString *legacyPath in legacyPaths) {
                if (CPUthermalPrefDeletionAllowed(canonicalPath, legacyPath)) {
                    [fileManager removeItemAtPath:legacyPath error:nil];
                }
            }
        }
        (void)newestLegacyPath;
        return prefs;
    }

    return nil;
}

// SpringBoard readers never migrate, write, chown or delete preference files.
// Migration remains owned by the settings writer / thermal daemon.
static inline NSDictionary *CPUthermalReadPrefsSnapshot(void) {
    return [NSDictionary dictionaryWithContentsOfFile:CPUthermalCurrentPrefPath()];
}

static inline NSDictionary *CPUthermalReadPrefs(void) {
    return CPUthermalReadMutablePrefs();
}

static inline BOOL CPUthermalWritePrefs(NSDictionary *prefs) {
    if (!prefs) {
        return NO;
    }

    NSString *path = CPUthermalCurrentPrefPath();
    if (path.length == 0) return NO;

    // isolation.15：写入 → 读回校验（全等）；失败重试一次；仍失败回退到规范路径并再次校验；
    // 只有成功后才执行旧的清理循环（RootHide 闸门 + 同文件保护）。返回准确的 ok。
    BOOL ok = CPUthermalWritePrefsAtPathVerified(prefs, path);
    if (!ok) {
        ok = CPUthermalWritePrefsAtPathVerified(prefs, path);
    }
    if (!ok) {
        NSString *canonicalPath = CPUthermalCanonicalPrefPath();
        if (canonicalPath.length > 0) {
            ok = CPUthermalWritePrefsAtPathVerified(prefs, canonicalPath);
            if (ok) path = canonicalPath;
        }
    }
    if (ok) {
        CPUthermalFixPrefOwnership(path);   // 属主/权限修复：mobile 必须能读写同一文件
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSString *legacyPath in CPUthermalLegacyPrefPaths()) {
            if (CPUthermalPrefDeletionAllowed(path, legacyPath)) {
                [fileManager removeItemAtPath:legacyPath error:nil];
            }
        }
    }
    return ok;
}

static const char *kCPUthermalThermalEngineActiveC = "com.huayuarc.cputhermal/thermal.protection.active";
static const char *kCPUthermalThermalRunModeC = "com.huayuarc.cputhermal/thermal.runmode";

static inline void CPUthermalPostThermalEngineState(BOOL protectionActive, int runMode) {
    int token = 0;
    if (notify_register_check(kCPUthermalThermalEngineActiveC, &token) == NOTIFY_STATUS_OK) {
        notify_set_state(token, protectionActive ? 1 : 0);
        notify_post(kCPUthermalThermalEngineActiveC);
        notify_cancel(token);
    }
    token = 0;
    if (notify_register_check(kCPUthermalThermalRunModeC, &token) == NOTIFY_STATUS_OK) {
        notify_set_state(token, (uint64_t)runMode);
        notify_post(kCPUthermalThermalRunModeC);
        notify_cancel(token);
    }
}

static inline void CPUthermalReadThermalEngineState(BOOL *protectionActive, int *runMode) {
    if (protectionActive) *protectionActive = NO;
    if (runMode) *runMode = 1;
    int token = 0; uint64_t state = 0;
    if (protectionActive && notify_register_check(kCPUthermalThermalEngineActiveC, &token) == NOTIFY_STATUS_OK) {
        if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) *protectionActive = (state == 1);
        notify_cancel(token);
    }
    token = 0;
    if (runMode && notify_register_check(kCPUthermalThermalRunModeC, &token) == NOTIFY_STATUS_OK) {
        if (notify_get_state(token, &state) == NOTIFY_STATUS_OK) *runMode = (int)state;
        notify_cancel(token);
    }
}

static const char *kCPUthermalLowPowerModeC = "lowPower";
static const char *kCPUthermalFullPowerModeC = "fullPower";
static const char *kCPUthermalExtremeModeC = "extremeFull";
static const char *kCPUthermalPowerModeChangedC = "com.huayuarc.cputhermal/powerModeChanged";

static inline void CPUthermalPostPowerMode(NSString *mode) {
    int token = 0;
    if (notify_register_check(kCPUthermalPowerModeChangedC, &token) != NOTIFY_STATUS_OK) return;
    uint64_t state = 1;
    if ([mode isKindOfClass:[NSString class]] && [mode isEqualToString:S(kCPUthermalLowPowerModeC)]) state = 0;
    else if ([mode isKindOfClass:[NSString class]] && [mode isEqualToString:S(kCPUthermalExtremeModeC)]) state = 2;
    notify_set_state(token, state);
    notify_post(kCPUthermalPowerModeChangedC);
    notify_cancel(token);
    notify_post(kCPUthermalSettingsChangedNotifC);   // 让主模块立即重载并应用
}

#endif
