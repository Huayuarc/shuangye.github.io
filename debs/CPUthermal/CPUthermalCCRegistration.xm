#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>

// 内置 CCSupport 核心能力：让 ControlCenterServices 扫描越狱模块目录。
// 与外部 CCSupport 共存时按路径去重；不复制/捆绑第三方二进制。
static NSArray *CPUthermalAppendModuleDirs(NSArray *original) {
    NSMutableArray *result=[original isKindOfClass:[NSArray class]]?[original mutableCopy]:[NSMutableArray array];
    NSFileManager *fm=[NSFileManager defaultManager];
    NSMutableArray *paths=[NSMutableArray arrayWithObjects:
        @"/var/jb/Library/ControlCenter/Bundles", @"/Library/ControlCenter/Bundles", nil];
    NSString *ag=@"/var/mobile/Containers/Shared/AppGroup";
    for(NSString *entry in [fm contentsOfDirectoryAtPath:ag error:nil]?:@[])
        if([entry hasPrefix:@".jbroot-"])
            [paths addObject:[[[ag stringByAppendingPathComponent:entry]
                stringByAppendingPathComponent:@"Library/ControlCenter"]
                stringByAppendingPathComponent:@"Bundles"]];
    for(NSString *path in paths){
        BOOL dir=NO; if(![fm fileExistsAtPath:path isDirectory:&dir]||!dir)continue;
        NSURL *url=[NSURL fileURLWithPath:path isDirectory:YES];
        BOOL found=NO;
        for(id old in result){
            NSString *oldPath=[old isKindOfClass:[NSURL class]]?[old path]:([old isKindOfClass:[NSString class]]?old:nil);
            if([oldPath isEqualToString:path]){found=YES;break;}
        }
        if(!found)[result addObject:url];
    }
    return result;
}

static id (*origManagerDirs)(id,SEL)=NULL;
static id hookManagerDirs(id self,SEL cmd){ return CPUthermalAppendModuleDirs(origManagerDirs?origManagerDirs(self,cmd):nil); }
static id (*origRepoDirs)(id,SEL)=NULL;
static id hookRepoDirs(id self,SEL cmd){ return CPUthermalAppendModuleDirs(origRepoDirs?origRepoDirs(self,cmd):nil); }
static id (*origManagerClassDirs)(id,SEL)=NULL;
static id hookManagerClassDirs(id self,SEL cmd){ return CPUthermalAppendModuleDirs(origManagerClassDirs?origManagerClassDirs(self,cmd):nil); }
static id (*origRepoClassDirs)(id,SEL)=NULL;
static id hookRepoClassDirs(id self,SEL cmd){ return CPUthermalAppendModuleDirs(origRepoClassDirs?origRepoClassDirs(self,cmd):nil); }

static BOOL gManagerInstanceHooked=NO,gRepoInstanceHooked=NO,gManagerClassHooked=NO,gRepoClassHooked=NO;
static void CPUthermalInstallCCHooks(void){
    SEL dirs=sel_registerName("_defaultModuleDirectories");
    Class manager=objc_getClass("CCSModuleProviderManager");
    Class repo=objc_getClass("CCSModuleRepository");
    if(manager&&!gManagerInstanceHooked&&class_getInstanceMethod(manager,dirs)){
        MSHookMessageEx(manager,dirs,(IMP)hookManagerDirs,(IMP*)&origManagerDirs);gManagerInstanceHooked=YES;
    }
    if(repo&&!gRepoInstanceHooked&&class_getInstanceMethod(repo,dirs)){
        MSHookMessageEx(repo,dirs,(IMP)hookRepoDirs,(IMP*)&origRepoDirs);gRepoInstanceHooked=YES;
    }
    Class mm=manager?object_getClass(manager):Nil;
    Class rm=repo?object_getClass(repo):Nil;
    if(mm&&!gManagerClassHooked&&class_getInstanceMethod(mm,dirs)){
        MSHookMessageEx(mm,dirs,(IMP)hookManagerClassDirs,(IMP*)&origManagerClassDirs);gManagerClassHooked=YES;
    }
    if(rm&&!gRepoClassHooked&&class_getInstanceMethod(rm,dirs)){
        MSHookMessageEx(rm,dirs,(IMP)hookRepoClassDirs,(IMP*)&origRepoClassDirs);gRepoClassHooked=YES;
    }
}

static void CPUthermalRefreshCCMetadata(void){
    const char *classes[]={"CCSModuleProviderManager","CCSModuleRepository",NULL};
    const char *singletons[]={"sharedInstance","defaultManager","sharedRepository",NULL};
    const char *updates[]={"_queue_updateAllModuleMetadata","_updateAllModuleMetadata",NULL};
    for(int i=0;classes[i];i++){
        Class cls=objc_getClass(classes[i]); if(!cls)continue;
        id object=nil;
        for(int j=0;singletons[j]&&!object;j++){
            SEL s=sel_registerName(singletons[j]); if([cls respondsToSelector:s])object=((id(*)(id,SEL))objc_msgSend)(cls,s);
        }
        if(!object)continue;
        for(int j=0;updates[j];j++){
            SEL u=sel_registerName(updates[j]); if([object respondsToSelector:u]){((void(*)(id,SEL))objc_msgSend)(object,u);break;}
        }
    }
}

%ctor {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices",RTLD_LAZY|RTLD_LOCAL);
        CPUthermalInstallCCHooks();
        [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification object:nil queue:nil usingBlock:^(NSNotification *n){
            (void)n; CPUthermalInstallCCHooks();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            CPUthermalInstallCCHooks(); CPUthermalRefreshCCMetadata();
        });
    }
}
