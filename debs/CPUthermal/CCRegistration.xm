#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <CPUthermalPaths.h>

// CPUthermal minimal Control Center registration bridge.
// Derived from the MIT-licensed CCSupport repository core loader path:
// https://github.com/opa334/CCSupport (Copyright Lars Fröder).
// Scope is intentionally limited to adding the standard third-party module directory
// and disabling the private repository allowlist in SpringBoard / Preferences.

@interface CCSModuleRepository : NSObject
+ (NSArray<NSURL *> *)_defaultModuleDirectories;
- (void)_queue_updateAllModuleMetadata;
- (void)_updateAllModuleMetadata;
@end

static NSString *CPUthermalCCModulesPath(void) {
    return CPUthermalJBRootPathForRootFSPath("/Library/ControlCenter/Bundles");
}

static void CPUthermalSetRepositoryAllowlistBypass(id repository) {
    Class cls = object_getClass(repository);
    Ivar ivar = class_getInstanceVariable(cls, "_ignoreAllowedList");
    if (!ivar) ivar = class_getInstanceVariable(cls, "_ignoreWhitelist");
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *((BOOL *)((uint8_t *)(__bridge void *)repository + offset)) = YES;
}

%hook CCSModuleRepository

+ (NSArray<NSURL *> *)_defaultModuleDirectories {
    NSArray<NSURL *> *directories = %orig;
    NSURL *thirdPartyURL = [NSURL fileURLWithPath:CPUthermalCCModulesPath() isDirectory:YES];
    if (!thirdPartyURL) return directories;
    NSArray *existingDirectories = directories ?: [NSArray array];
    for (NSURL *url in existingDirectories) if ([url.path isEqualToString:thirdPartyURL.path]) return directories;
    return directories ? [directories arrayByAddingObject:thirdPartyURL] : [NSArray arrayWithObject:thirdPartyURL];
}

- (void)_queue_updateAllModuleMetadata {
    CPUthermalSetRepositoryAllowlistBypass(self);
    %orig;
}

- (void)_updateAllModuleMetadata {
    CPUthermalSetRepositoryAllowlistBypass(self);
    %orig;
}

%end
