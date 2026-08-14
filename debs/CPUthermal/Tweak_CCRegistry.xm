#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>

@interface CCSModuleRepository : NSObject
+ (NSArray<NSURL *> *)_defaultModuleDirectories;
- (void)_queue_updateAllModuleMetadata;
@end

static NSString *CPUthermalCCModulesDirectory(void) {
    NSString *rootHideRoot = CPUthermalCurrentRootHideRoot();
    if (rootHideRoot.length > 0) {
        NSString *candidate = [rootHideRoot stringByAppendingPathComponent:S("Library/ControlCenter/Bundles")];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) return candidate;
    }
    NSString *resolved = CPUthermalJBRootPathForRootFSPath("/Library/ControlCenter/Bundles");
    if (resolved.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:resolved]) return resolved;
    return S("/Library/ControlCenter/Bundles");
}

static void CPUthermalEnableThirdPartyModules(id repository) {
    if (!repository) return;
    Class cls = [repository class];
    if (class_getInstanceVariable(cls, "_ignoreAllowedList")) {
        MSHookIvar<BOOL>(repository, "_ignoreAllowedList") = YES;
    } else if (class_getInstanceVariable(cls, "_ignoreWhitelist")) {
        MSHookIvar<BOOL>(repository, "_ignoreWhitelist") = YES;
    }
}

%group CPUthermalCCRegistryGroup
%hook CCSModuleRepository
+ (NSArray<NSURL *> *)_defaultModuleDirectories {
    NSArray<NSURL *> *directories = %orig;
    NSString *path = CPUthermalCCModulesDirectory();
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    for (NSURL *existing in directories) {
        if ([[existing path] isEqualToString:path]) return directories;
    }
    return directories ? [directories arrayByAddingObject:url] : @[url];
}

- (void)_queue_updateAllModuleMetadata {
    CPUthermalEnableThirdPartyModules(self);
    %orig;
}
%end
%end

%ctor {
    dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices", RTLD_NOW | RTLD_GLOBAL);
    if (objc_getClass("CCSModuleRepository")) %init(CPUthermalCCRegistryGroup);
}
