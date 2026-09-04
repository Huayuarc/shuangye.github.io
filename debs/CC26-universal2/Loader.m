#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSString *const CC26Domain = @"com.cureux.cc26";
static CFStringRef const CC26Changed = CFSTR("com.cureux.cc26.prefschanged");
static void *gCC26CoreHandle = NULL;

static BOOL CC26RuntimeSupported(void) {
    NSOperatingSystemVersion version = [NSProcessInfo processInfo].operatingSystemVersion;
    // 上传版原始类布局来自 0.4.9.9b（原作者标注 iOS 13–17），
    // universal1 安全补丁移除了最危险的全局特殊边框递归；当前 Loader 放行 iOS 15/16，
    // 并继续要求关键私有类与 selector 实际存在。iOS 17+ 默认隔离。
    if (version.majorVersion < 15 || version.majorVersion > 16) return NO;
    // 这些类/selector 是上传版核心执行的关键边界；缺失时不装载核心。
    Class materialLayer = NSClassFromString(@"MTMaterialLayer");
    Class modularController = NSClassFromString(@"CCUIModularControlCenterOverlayViewController");
    return materialLayer != Nil && modularController != Nil &&
        class_getInstanceMethod(materialLayer, NSSelectorFromString(@"_configureIfNecessaryWithSettingsInterpolator:")) != NULL;
}

static BOOL CC26Enabled(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC26Domain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("Enabled"), (__bridge CFStringRef)CC26Domain);
    if (!value) return YES;
    BOOL enabled = [(__bridge id)value boolValue];
    CFRelease(value);
    return enabled;
}

static NSString *CC26CorePath(void) {
    NSString *loader = [NSString stringWithUTF8String:__FILE__];
    (void)loader;
    // Loader 与 Core 安装在同一 DynamicLibraries 目录，避免固定 /var/jb。
    Dl_info info = {0};
    if (dladdr((const void *)&CC26CorePath, &info) && info.dli_fname) {
        NSString *directory = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
        return [directory stringByAppendingPathComponent:@"CC26Core.dylib"];
    }
    return nil;
}

static void CC26LoadCoreIfAllowed(void) {
    if (gCC26CoreHandle || !CC26Enabled() || !CC26RuntimeSupported()) return;
    NSString *path = CC26CorePath();
    if (!path.length) return;
    gCC26CoreHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
}

static void CC26PreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                   const void *object, CFDictionaryRef userInfo) {
    // Core 的 Logos hooks 一经安装无法安全卸载；开关变化后重启 SpringBoard 生效。
    if (CC26Enabled()) CC26LoadCoreIfAllowed();
}

__attribute__((constructor)) static void CC26LoaderInit(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (![bundleID isEqualToString:@"com.apple.springboard"]) return;
        CC26LoadCoreIfAllowed();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            CC26PreferencesChanged, CC26Changed, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
