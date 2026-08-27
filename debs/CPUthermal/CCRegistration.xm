#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <CPUthermalPaths.h>

// CPUthermal minimal Control Center registration bridge.
// Derived from the MIT-licensed CCSupport core loader path:
// https://github.com/opa334/CCSupport (Copyright Lars Fröder).
// Only the third-party module directory and repository allowlist bypass are retained.

static NSArray<NSURL *> *(*origDefaultModuleDirectories)(id, SEL) = NULL;
static void (*origQueueUpdateAllModuleMetadata)(id, SEL) = NULL;
static void (*origUpdateAllModuleMetadata)(id, SEL) = NULL;
static BOOL gRepositoryHooksInstalled = NO;
static BOOL gExternalCCSupportDetected = NO;

static BOOL CPUthermalPathExists(NSString *path) {
    return path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static BOOL CPUthermalImageNameContains(const char *needle) {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name && strstr(name, needle)) return YES;
    }
    return NO;
}

static BOOL CPUthermalExternalCCSupportPresent(void) {
    // Runtime evidence wins: official CCSupport manager class or loaded dylib.
    if (objc_getClass("CCSModuleProviderManager")) return YES;
    if (CPUthermalImageNameContains("CCSupport.dylib") || CPUthermalImageNameContains("/CCSupport/")) return YES;

    NSMutableArray<NSString *> *roots = [NSMutableArray arrayWithObjects:@"", @"/var/jb", nil];
    NSString *rootHideRoot = CPUthermalCurrentRootHideRoot();
    if (rootHideRoot.length > 0) [roots addObject:rootHideRoot];
    for (NSString *root in roots) {
        NSString *dylib = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/CCSupport.dylib"];
        // 以实际注入 dylib 为安装证据；Application Support 目录可能在卸载后残留，不能单独触发互斥。
        if (CPUthermalPathExists(dylib)) return YES;
    }
    return NO;
}

static NSString *CPUthermalCCModulesPath(void) {
    return CPUthermalJBRootPathForRootFSPath("/Library/ControlCenter/Bundles");
}

static void CPUthermalSetRepositoryAllowlistBypass(id repository) {
    if (!repository) return;
    Class cls = object_getClass(repository);
    Ivar ivar = class_getInstanceVariable(cls, "_ignoreAllowedList");
    if (!ivar) ivar = class_getInstanceVariable(cls, "_ignoreWhitelist");
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *((BOOL *)((uint8_t *)(__bridge void *)repository + offset)) = YES;
}

static NSArray<NSURL *> *CPUthermalDefaultModuleDirectories(id self, SEL command) {
    NSArray<NSURL *> *directories = origDefaultModuleDirectories ? origDefaultModuleDirectories(self, command) : nil;
    // 外部 CCSupport 后加载时立即旁路内置目录修改，由外部 replacement 链作为最终结果。
    if (CPUthermalExternalCCSupportPresent()) return directories;
    NSString *path = CPUthermalCCModulesPath();
    NSURL *thirdPartyURL = path.length ? [NSURL fileURLWithPath:path isDirectory:YES] : nil;
    if (!thirdPartyURL) return directories;
    for (NSURL *url in directories ?: [NSArray array]) {
        if ([[url path] isEqualToString:[thirdPartyURL path]]) return directories;
    }
    return directories ? [directories arrayByAddingObject:thirdPartyURL] : [NSArray arrayWithObject:thirdPartyURL];
}

static void CPUthermalQueueUpdateAllModuleMetadata(id self, SEL command) {
    if (!CPUthermalExternalCCSupportPresent()) CPUthermalSetRepositoryAllowlistBypass(self);
    if (origQueueUpdateAllModuleMetadata) origQueueUpdateAllModuleMetadata(self, command);
}

static void CPUthermalUpdateAllModuleMetadata(id self, SEL command) {
    if (!CPUthermalExternalCCSupportPresent()) CPUthermalSetRepositoryAllowlistBypass(self);
    if (origUpdateAllModuleMetadata) origUpdateAllModuleMetadata(self, command);
}

static void CPUthermalInstallRepositoryHooks(void) {
    if (gExternalCCSupportDetected || gRepositoryHooksInstalled) return;
    Class repositoryClass = objc_getClass("CCSModuleRepository");
    if (!repositoryClass) return;

    SEL directoriesSelector = sel_registerName("_defaultModuleDirectories");
    Class repositoryMetaClass = object_getClass(repositoryClass);
    Method directoriesMethod = class_getClassMethod(repositoryClass, directoriesSelector);
    if (directoriesMethod && !origDefaultModuleDirectories) {
        MSHookMessageEx(repositoryMetaClass, directoriesSelector, (IMP)CPUthermalDefaultModuleDirectories, (IMP *)&origDefaultModuleDirectories);
    }

    SEL queueSelector = sel_registerName("_queue_updateAllModuleMetadata");
    if (class_getInstanceMethod(repositoryClass, queueSelector) && !origQueueUpdateAllModuleMetadata) {
        MSHookMessageEx(repositoryClass, queueSelector, (IMP)CPUthermalQueueUpdateAllModuleMetadata, (IMP *)&origQueueUpdateAllModuleMetadata);
    }

    SEL updateSelector = sel_registerName("_updateAllModuleMetadata");
    if (class_getInstanceMethod(repositoryClass, updateSelector) && !origUpdateAllModuleMetadata) {
        MSHookMessageEx(repositoryClass, updateSelector, (IMP)CPUthermalUpdateAllModuleMetadata, (IMP *)&origUpdateAllModuleMetadata);
    }

    gRepositoryHooksInstalled = (origDefaultModuleDirectories != NULL) &&
        ((origQueueUpdateAllModuleMetadata != NULL) || (origUpdateAllModuleMetadata != NULL));
}

static void CPUthermalBundleDidLoad(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (!gExternalCCSupportDetected && CPUthermalExternalCCSupportPresent()) {
        gExternalCCSupportDetected = YES;
        return;
    }
    CPUthermalInstallRepositoryHooks();
}

%ctor {
    @autoreleasepool {
        // Mutual exclusion must run before touching CCSModuleRepository.
        gExternalCCSupportDetected = CPUthermalExternalCCSupportPresent();
        if (gExternalCCSupportDetected) return;

        // SpringBoard usually has ControlCenterServices loaded already; Preferences loads it lazily.
        dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices", RTLD_LAZY | RTLD_GLOBAL);

        // CCSupport may have been loaded by the framework/process bootstrap in the meantime.
        gExternalCCSupportDetected = CPUthermalExternalCCSupportPresent();
        if (gExternalCCSupportDetected) return;

        CPUthermalInstallRepositoryHooks();
        if (!gRepositoryHooksInstalled) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, CPUthermalBundleDidLoad,
                (__bridge CFStringRef)NSBundleDidLoadNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
        }
    }
}
