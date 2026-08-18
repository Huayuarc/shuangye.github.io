#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <roothide.h>

static BOOL RHStrictEnabled(void) {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    if (!bid.length) return NO;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/RootHide/RootHideConfig.plist")];
    return [cfg[@"strictShieldModes"][bid] integerValue] == 2;
}

static BOOL RHBlockedScheme(NSURL *url) {
    NSString *s = url.scheme.lowercaseString;
    return [@[@"cydia",@"sileo",@"zbra",@"filza",@"activator",@"undecimus",@"odyssey",@"dopamine"] containsObject:s];
}

static BOOL (*origCanOpenURL)(id,SEL,NSURL *);
static BOOL hookCanOpenURL(id self,SEL _cmd,NSURL *url) { if (RHBlockedScheme(url)) return NO; return origCanOpenURL(self,_cmd,url); }
static BOOL hookFalse(id self,SEL _cmd) { return NO; }
static void hookNoop(id self,SEL _cmd) {}
static void hookSetFalse(id self,SEL _cmd,BOOL value) { (void)value; }
static void hookSetNil(id self,SEL _cmd,id value) { (void)value; }

static void RHInstallOnClass(Class cls) {
    if (!cls) return;
    const char *falseSelectors[] = {"isJailbreak","isJailBroken","isJailbroken","isJail","JBCheck","isRiskyDevice","isRisky"};
    for (NSUInteger i=0;i<sizeof(falseSelectors)/sizeof(falseSelectors[0]);i++) {
        SEL sel=sel_registerName(falseSelectors[i]); Method m=class_getInstanceMethod(cls,sel);
        if (m && method_getNumberOfArguments(m)==2) MSHookMessageEx(cls,sel,(IMP)hookFalse,NULL);
        Class meta=object_getClass(cls); Method cm=class_getClassMethod(cls,sel);
        if (cm && method_getNumberOfArguments(cm)==2) MSHookMessageEx(meta,sel,(IMP)hookFalse,NULL);
    }
    SEL mark=sel_registerName("markRiskyDevice"); if(class_getInstanceMethod(cls,mark)) MSHookMessageEx(cls,mark,(IMP)hookNoop,NULL);
    SEL risky=sel_registerName("setIsRisky:"); if(class_getInstanceMethod(cls,risky)) MSHookMessageEx(cls,risky,(IMP)hookSetFalse,NULL);
    SEL risks=sel_registerName("setIsRisks:"); if(class_getInstanceMethod(cls,risks)) MSHookMessageEx(cls,risks,(IMP)hookSetFalse,NULL);
    SEL marker=sel_registerName("setRiskyMarkerFileDir:"); if(class_getInstanceMethod(cls,marker)) MSHookMessageEx(cls,marker,(IMP)hookSetNil,NULL);
}

__attribute__((constructor)) static void RHInit(void) {
    @autoreleasepool {
        if (!RHStrictEnabled()) return;
        MSHookMessageEx(UIApplication.class,@selector(canOpenURL:),(IMP)hookCanOpenURL,(IMP *)&origCanOpenURL);
        int count=objc_getClassList(NULL,0); if(count<=0)return; Class *classes=(Class *)calloc((size_t)count,sizeof(Class)); count=objc_getClassList(classes,count);
        for(int i=0;i<count;i++) RHInstallOnClass(classes[i]); free(classes);
    }
}
