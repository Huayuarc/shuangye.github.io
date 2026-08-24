#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>

static BOOL PMExternalCCSupport(void){
    if(objc_getClass("CCSModuleProviderManager"))return YES;
    for(uint32_t i=0;i<_dyld_image_count();i++){const char *n=_dyld_get_image_name(i);if(n&&(strstr(n,"CCSupport.dylib")||strstr(n,"/CCSupport/")))return YES;}
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray *fixed=@[@"/Library/MobileSubstrate/DynamicLibraries/CCSupport.dylib",@"/var/jb/Library/MobileSubstrate/DynamicLibraries/CCSupport.dylib",@"/Library/Application Support/CCSupport",@"/var/jb/Library/Application Support/CCSupport"];
    for(NSString *p in fixed)if([fm fileExistsAtPath:p])return YES;
    NSString *base=@"/var/mobile/Containers/Shared/AppGroup";
    for(NSString *n in [fm contentsOfDirectoryAtPath:base error:nil]?:@[]){if(![n hasPrefix:@".jbroot-"])continue;NSString *r=[base stringByAppendingPathComponent:n];if([fm fileExistsAtPath:[r stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/CCSupport.dylib"]]||[fm fileExistsAtPath:[r stringByAppendingPathComponent:@"Library/Application Support/CCSupport"]])return YES;}
    return NO;
}
static NSString *PMModulesDirectory(void){
    NSFileManager *fm=NSFileManager.defaultManager;NSString *base=@"/var/mobile/Containers/Shared/AppGroup";NSString *best=nil;NSDate *date=nil;
    for(NSString *n in [fm contentsOfDirectoryAtPath:base error:nil]?:@[]){if(![n hasPrefix:@".jbroot-"])continue;NSString *r=[base stringByAppendingPathComponent:n];NSString *p=[r stringByAppendingPathComponent:@"Library/ControlCenter/Bundles/PictureModule1.bundle"];if(![fm fileExistsAtPath:p])continue;NSDate *d=[[fm attributesOfItemAtPath:p error:nil] fileModificationDate];if(!best||[d compare:date]==NSOrderedDescending){best=[r stringByAppendingPathComponent:@"Library/ControlCenter/Bundles"];date=d;}}
    if(best)return best;if([fm fileExistsAtPath:@"/var/jb/Library/ControlCenter/Bundles"])return @"/var/jb/Library/ControlCenter/Bundles";return @"/Library/ControlCenter/Bundles";
}
static void PMAllow(id repo){Class c=object_getClass(repo);if(!c)c=[repo class];Ivar iv=class_getInstanceVariable(c,"_ignoreAllowedList");if(!iv)iv=class_getInstanceVariable(c,"_ignoreWhitelist");if(iv){uint8_t *b=(uint8_t *)(__bridge void *)repo;b[ivar_getOffset(iv)]=1;}}
static NSArray *(*PMOrigDirs)(id,SEL);static NSArray *PMDirs(id self,SEL cmd){NSArray *a=PMOrigDirs?PMOrigDirs(self,cmd):@[];NSString *p=PMModulesDirectory();for(NSURL *u in a)if([u.path isEqualToString:p])return a;return [a arrayByAddingObject:[NSURL fileURLWithPath:p isDirectory:YES]];}
static void (*PMOrigQueue)(id,SEL);static void PMQueue(id self,SEL cmd){PMAllow(self);if(PMOrigQueue)PMOrigQueue(self,cmd);}
static void (*PMOrigUpdate)(id,SEL);static void PMUpdate(id self,SEL cmd){PMAllow(self);if(PMOrigUpdate)PMOrigUpdate(self,cmd);}
static BOOL PMInstalled=NO;static void PMInstall(void){if(PMInstalled||PMExternalCCSupport())return;dlopen("/System/Library/PrivateFrameworks/ControlCenterServices.framework/ControlCenterServices",RTLD_NOW|RTLD_GLOBAL);Class c=objc_getClass("CCSModuleRepository");if(!c)return;Class meta=object_getClass(c);Method m=class_getClassMethod(c,sel_registerName("_defaultModuleDirectories"));if(m)MSHookMessageEx(meta,method_getName(m),(IMP)PMDirs,(IMP *)&PMOrigDirs);m=class_getInstanceMethod(c,sel_registerName("_queue_updateAllModuleMetadata"));if(m)MSHookMessageEx(c,method_getName(m),(IMP)PMQueue,(IMP *)&PMOrigQueue);m=class_getInstanceMethod(c,sel_registerName("_updateAllModuleMetadata"));if(m)MSHookMessageEx(c,method_getName(m),(IMP)PMUpdate,(IMP *)&PMOrigUpdate);PMInstalled=YES;}
__attribute__((constructor))static void PMStart(void){@autoreleasepool{if(PMExternalCCSupport())return;PMInstall();if(!PMInstalled)[NSNotificationCenter.defaultCenter addObserverForName:NSBundleDidLoadNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){if(!PMExternalCCSupport())PMInstall();}];}}
