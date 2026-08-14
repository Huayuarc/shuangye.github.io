#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import "SCPaths.h"

@interface CCSModuleRepository : NSObject
+ (NSArray<NSURL *> *)_defaultModuleDirectories;
- (void)_queue_updateAllModuleMetadata;
@end

static NSString *SCModulesDirectory(void) {
    NSString *root=SCCurrentJailbreakRoot();
    if(root.length){NSString *p=[root stringByAppendingPathComponent:@"Library/ControlCenter/Bundles"];if([[NSFileManager defaultManager] fileExistsAtPath:p])return p;}
    return @"/Library/ControlCenter/Bundles";
}
static void SCAllowModules(id repo){Class c=[repo class];if(class_getInstanceVariable(c,"_ignoreAllowedList"))MSHookIvar<BOOL>(repo,"_ignoreAllowedList")=YES;else if(class_getInstanceVariable(c,"_ignoreWhitelist"))MSHookIvar<BOOL>(repo,"_ignoreWhitelist")=YES;}

%hook CCSModuleRepository
+ (NSArray<NSURL *> *)_defaultModuleDirectories { NSArray *dirs=%orig;NSString *p=SCModulesDirectory();for(NSURL *u in dirs)if([u.path isEqualToString:p])return dirs;NSURL *u=[NSURL fileURLWithPath:p isDirectory:YES];return dirs?[dirs arrayByAddingObject:u]:@[u]; }
- (void)_queue_updateAllModuleMetadata { SCAllowModules(self);%orig; }
%end

%ctor { dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices",RTLD_NOW|RTLD_GLOBAL);if(objc_getClass("CCSModuleRepository"))%init; }
