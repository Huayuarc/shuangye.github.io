#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SCPaths.h"

static NSArray<NSURL *> *(*origDefaultModuleDirectories)(id,SEL)=NULL;
static void (*origQueueUpdateAllModuleMetadata)(id,SEL)=NULL;
static void (*origUpdateAllModuleMetadata)(id,SEL)=NULL;
static BOOL gSCRepositoryHooksInstalled=NO;

static NSString *SCControlCenterModulesPath(void){
    NSString *root=SCCurrentJailbreakRoot();
    if(root.length)return [root stringByAppendingPathComponent:@"Library/ControlCenter/Bundles"];
    return @"/Library/ControlCenter/Bundles";
}
static void SCBypassRepositoryAllowlist(id repository){
    if(!repository)return;Class cls=[repository class];Ivar ivar=class_getInstanceVariable(cls,"_ignoreAllowedList");if(!ivar)ivar=class_getInstanceVariable(cls,"_ignoreWhitelist");if(!ivar)return;
    ptrdiff_t offset=ivar_getOffset(ivar);*((BOOL*)((uint8_t*)(__bridge void*)repository+offset))=YES;
}
static NSArray<NSURL*> *SCDefaultModuleDirectories(id self,SEL cmd){
    NSArray<NSURL*> *dirs=origDefaultModuleDirectories?origDefaultModuleDirectories(self,cmd):nil;NSString *path=SCControlCenterModulesPath();NSURL *url=path.length?[NSURL fileURLWithPath:path isDirectory:YES]:nil;if(!url)return dirs;
    for(NSURL *existing in dirs?:@[])if([existing.path isEqualToString:url.path])return dirs;
    return dirs?[dirs arrayByAddingObject:url]:@[url];
}
static void SCQueueUpdateMetadata(id self,SEL cmd){SCBypassRepositoryAllowlist(self);if(origQueueUpdateAllModuleMetadata)origQueueUpdateAllModuleMetadata(self,cmd);}
static void SCUpdateMetadata(id self,SEL cmd){SCBypassRepositoryAllowlist(self);if(origUpdateAllModuleMetadata)origUpdateAllModuleMetadata(self,cmd);}
static void SCInstallRepositoryHooks(void){
    if(gSCRepositoryHooksInstalled)return;Class cls=objc_getClass("CCSModuleRepository");if(!cls)return;
    SEL dirs=sel_registerName("_defaultModuleDirectories");Class meta=object_getClass(cls);if(class_getClassMethod(cls,dirs)&&!origDefaultModuleDirectories)MSHookMessageEx(meta,dirs,(IMP)SCDefaultModuleDirectories,(IMP*)&origDefaultModuleDirectories);
    SEL queue=sel_registerName("_queue_updateAllModuleMetadata");if(class_getInstanceMethod(cls,queue)&&!origQueueUpdateAllModuleMetadata)MSHookMessageEx(cls,queue,(IMP)SCQueueUpdateMetadata,(IMP*)&origQueueUpdateAllModuleMetadata);
    SEL update=sel_registerName("_updateAllModuleMetadata");if(class_getInstanceMethod(cls,update)&&!origUpdateAllModuleMetadata)MSHookMessageEx(cls,update,(IMP)SCUpdateMetadata,(IMP*)&origUpdateAllModuleMetadata);
    gSCRepositoryHooksInstalled=origDefaultModuleDirectories&&(origQueueUpdateAllModuleMetadata||origUpdateAllModuleMetadata);
}
static void SCBundleDidLoad(CFNotificationCenterRef c,void *o,CFStringRef n,const void *obj,CFDictionaryRef u){SCInstallRepositoryHooks();}
%ctor { @autoreleasepool { dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices",RTLD_LAZY|RTLD_GLOBAL);SCInstallRepositoryHooks();if(!gSCRepositoryHooksInstalled)CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(),NULL,SCBundleDidLoad,(__bridge CFStringRef)NSBundleDidLoadNotification,NULL,CFNotificationSuspensionBehaviorCoalesce); } }
