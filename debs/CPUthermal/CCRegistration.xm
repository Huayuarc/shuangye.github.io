#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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
static NSURL *(*origConfigurationFileURL)(id, SEL) = NULL;
static void (*origSettingsListViewDidLoad)(id, SEL) = NULL;
static void (*origSettingsModulesViewDidLoad)(id, SEL) = NULL;
static BOOL gRepositoryHooksInstalled = NO;
static BOOL gConfigurationHookInstalled = NO;
static BOOL gSettingsUIHookInstalled = NO;
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

static NSString *CPUthermalDefaultCCConfigurationPath(void) {
    return @"/var/mobile/Library/ControlCenter/ModuleConfiguration.plist";
}

static NSString *CPUthermalEmbeddedCCConfigurationPath(void) {
    NSString *directory = CPUthermalJBRootPathForRootFSPath("/var/mobile/Library/ControlCenter");
    if (directory.length == 0 || [directory isEqualToString:@"/var/mobile/Library/ControlCenter"])
        directory = @"/var/mobile/Library/ControlCenter";
    return [directory stringByAppendingPathComponent:@"ModuleConfiguration_CCSupport.plist"];
}

static void CPUthermalPrepareEmbeddedConfiguration(void) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *target = CPUthermalEmbeddedCCConfigurationPath();
    NSString *directory = [target stringByDeletingLastPathComponent];
    [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    if (![manager fileExistsAtPath:target]) {
        NSString *source = CPUthermalDefaultCCConfigurationPath();
        if ([manager fileExistsAtPath:source]) [manager copyItemAtPath:source toPath:target error:nil];
    }
}

static NSURL *CPUthermalConfigurationFileURL(id self, SEL command) {
    if (CPUthermalExternalCCSupportPresent() && origConfigurationFileURL)
        return origConfigurationFileURL(self, command);
    CPUthermalPrepareEmbeddedConfiguration();
    return [NSURL fileURLWithPath:CPUthermalEmbeddedCCConfigurationPath()];
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

static void CPUthermalReloadSettingsController(id controller) {
    SEL reload = sel_registerName("reloadSpecifiers");
    if ([controller respondsToSelector:reload]) ((void (*)(id, SEL))objc_msgSend)(controller, reload);
    else if ([[controller view] isKindOfClass:[UIView class]]) [[controller view] setNeedsLayout];
}

static void CPUthermalPresentResetModules(id controller) {
    if (CPUthermalExternalCCSupportPresent() || ![controller isKindOfClass:[UIViewController class]]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置模组"
        message:@"内置 CCSupport 与外部 CCSupport 共用同一配置文件。请选择需要重置的配置。"
        preferredStyle:UIAlertControllerStyleAlert];
    void (^removePath)(NSString *) = ^(NSString *path) { [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; };
    [alert addAction:[UIAlertAction actionWithTitle:@"重置系统自带的配置" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        removePath(CPUthermalDefaultCCConfigurationPath()); CPUthermalReloadSettingsController(controller);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重置内置 CCSupport 配置" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        removePath(CPUthermalEmbeddedCCConfigurationPath()); CPUthermalPrepareEmbeddedConfiguration(); CPUthermalReloadSettingsController(controller);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"两者均重置" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        removePath(CPUthermalDefaultCCConfigurationPath()); removePath(CPUthermalEmbeddedCCConfigurationPath()); CPUthermalReloadSettingsController(controller);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [(UIViewController *)controller presentViewController:alert animated:YES completion:nil];
}

@interface CPUthermalCCResetTarget : NSObject
+ (void)resetModulesFromController:(id)controller;
@end
@implementation CPUthermalCCResetTarget
+ (void)resetModulesFromController:(id)controller { CPUthermalPresentResetModules(controller); }
@end

static void CPUthermalInstallResetButton(id controller) {
    if (CPUthermalExternalCCSupportPresent() || ![controller isKindOfClass:[UIViewController class]]) return;
    UIViewController *viewController = controller;
    if (viewController.navigationItem.rightBarButtonItem && viewController.navigationItem.rightBarButtonItem.tag == 16411) return;
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:@"重置模组" style:UIBarButtonItemStylePlain target:nil action:nil];
    button.tag = 16411;
    button.target = viewController;
    button.action = sel_registerName("cputhermal_resetModules");
    viewController.navigationItem.rightBarButtonItem = button;
}

static void CPUthermalSettingsListViewDidLoad(id self, SEL command) {
    if (origSettingsListViewDidLoad) origSettingsListViewDidLoad(self, command);
    CPUthermalInstallResetButton(self);
}
static void CPUthermalSettingsModulesViewDidLoad(id self, SEL command) {
    if (origSettingsModulesViewDidLoad) origSettingsModulesViewDidLoad(self, command);
    CPUthermalInstallResetButton(self);
}
static void CPUthermalResetModulesIMP(id self, SEL command) { CPUthermalPresentResetModules(self); }

static void CPUthermalInstallConfigurationAndSettingsHooks(void) {
    if (gExternalCCSupportDetected || CPUthermalExternalCCSupportPresent()) return;
    Class provider = objc_getClass("CCSModuleSettingsProvider");
    SEL configurationSelector = sel_registerName("_configurationFileURL");
    if (provider && class_getClassMethod(provider, configurationSelector) && !origConfigurationFileURL) {
        MSHookMessageEx(object_getClass(provider), configurationSelector, (IMP)CPUthermalConfigurationFileURL, (IMP *)&origConfigurationFileURL);
        gConfigurationHookInstalled = (origConfigurationFileURL != NULL);
    }
    Class listController = objc_getClass("CCUISettingsListController");
    Class modulesController = objc_getClass("CCUISettingsModulesController");
    SEL viewDidLoadSelector = sel_registerName("viewDidLoad");
    SEL resetSelector = sel_registerName("cputhermal_resetModules");
    if (listController && !class_getInstanceMethod(listController, resetSelector)) class_addMethod(listController, resetSelector, (IMP)CPUthermalResetModulesIMP, "v@:");
    if (modulesController && !class_getInstanceMethod(modulesController, resetSelector)) class_addMethod(modulesController, resetSelector, (IMP)CPUthermalResetModulesIMP, "v@:");
    if (listController && class_getInstanceMethod(listController, viewDidLoadSelector) && !origSettingsListViewDidLoad)
        MSHookMessageEx(listController, viewDidLoadSelector, (IMP)CPUthermalSettingsListViewDidLoad, (IMP *)&origSettingsListViewDidLoad);
    if (modulesController && class_getInstanceMethod(modulesController, viewDidLoadSelector) && !origSettingsModulesViewDidLoad)
        MSHookMessageEx(modulesController, viewDidLoadSelector, (IMP)CPUthermalSettingsModulesViewDidLoad, (IMP *)&origSettingsModulesViewDidLoad);
    gSettingsUIHookInstalled = (origSettingsListViewDidLoad != NULL) || (origSettingsModulesViewDidLoad != NULL);
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
    CPUthermalInstallConfigurationAndSettingsHooks();
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

        CPUthermalPrepareEmbeddedConfiguration();
        CPUthermalInstallRepositoryHooks();
        CPUthermalInstallConfigurationAndSettingsHooks();
        if (!gRepositoryHooksInstalled || !gConfigurationHookInstalled || !gSettingsUIHookInstalled) {
            CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL, CPUthermalBundleDidLoad,
                (__bridge CFStringRef)NSBundleDidLoadNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
        }
    }
}
