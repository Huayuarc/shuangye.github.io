#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#include <roothide.h>

// 按历史 1.6.0-7 / CC模块 1.6.4.7 的实现边界：
// 仅 Hook CCSModuleRepository._defaultModuleDirectories，并用 jbroot() 解析当前越狱根。
static NSArray *CPUthermalAppendModuleDirectory(NSArray *original) {
    NSMutableArray *result=[original isKindOfClass:[NSArray class]]?[original mutableCopy]:[NSMutableArray array];
    NSFileManager *fm=[NSFileManager defaultManager];
    NSMutableArray *paths=[NSMutableArray array];
    const char *converted=jbroot("/Library/ControlCenter/Bundles");
    if(converted&&converted[0])[paths addObject:[NSString stringWithUTF8String:converted]];
    [paths addObject:@"/Library/ControlCenter/Bundles"];
    [paths addObject:@"/var/jb/Library/ControlCenter/Bundles"];
    for(NSString *path in paths){
        BOOL dir=NO; if(![fm fileExistsAtPath:path isDirectory:&dir]||!dir)continue;
        BOOL found=NO;
        for(id old in result){
            NSString *oldPath=[old isKindOfClass:[NSURL class]]?[old path]:([old isKindOfClass:[NSString class]]?old:nil);
            if([oldPath isEqualToString:path]){found=YES;break;}
        }
        if(!found)[result addObject:[NSURL fileURLWithPath:path isDirectory:YES]];
    }
    return result;
}

static id (*origRepoDirs)(id,SEL)=NULL;
static id hookRepoDirs(id self,SEL cmd){return CPUthermalAppendModuleDirectory(origRepoDirs?origRepoDirs(self,cmd):nil);}
static id (*origRepoClassDirs)(id,SEL)=NULL;
static id hookRepoClassDirs(id self,SEL cmd){return CPUthermalAppendModuleDirectory(origRepoClassDirs?origRepoClassDirs(self,cmd):nil);}
static BOOL gInstanceHooked=NO,gClassHooked=NO;

static void CPUthermalInstallCCRepositoryHook(void){
    Class repo=objc_getClass("CCSModuleRepository"); if(!repo)return;
    SEL dirs=sel_registerName("_defaultModuleDirectories");
    if(!gInstanceHooked&&class_getInstanceMethod(repo,dirs)){
        MSHookMessageEx(repo,dirs,(IMP)hookRepoDirs,(IMP*)&origRepoDirs);gInstanceHooked=YES;
    }
    Class meta=object_getClass(repo);
    if(meta&&!gClassHooked&&class_getInstanceMethod(meta,dirs)){
        MSHookMessageEx(meta,dirs,(IMP)hookRepoClassDirs,(IMP*)&origRepoClassDirs);gClassHooked=YES;
    }
}

static void CPUthermalRefreshCCRepository(void){
    Class repo=objc_getClass("CCSModuleRepository"); if(!repo)return;
    SEL dm=sel_registerName("defaultManager");
    id object=[repo respondsToSelector:dm]?((id(*)(id,SEL))objc_msgSend)(repo,dm):nil;
    if(!object)return;
    SEL queued=sel_registerName("_queue_updateAllModuleMetadata");
    SEL direct=sel_registerName("_updateAllModuleMetadata");
    if([object respondsToSelector:queued])((void(*)(id,SEL))objc_msgSend)(object,queued);
    else if([object respondsToSelector:direct])((void(*)(id,SEL))objc_msgSend)(object,direct);
}

%ctor {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices",RTLD_LAZY|RTLD_LOCAL);
        CPUthermalInstallCCRepositoryHook();
        [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification object:nil queue:nil usingBlock:^(NSNotification *n){
            (void)n;CPUthermalInstallCCRepositoryHook();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            CPUthermalInstallCCRepositoryHook();CPUthermalRefreshCCRepository();
        });
    }
}
