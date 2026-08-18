#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import <roothide.h>

static NSMutableSet *RHInstalled;
static dispatch_queue_t RHQueue;

static BOOL RHStrictEnabled(void) {
    NSString *bid=NSBundle.mainBundle.bundleIdentifier;if(!bid.length)return NO;
    NSDictionary *cfg=[NSDictionary dictionaryWithContentsOfFile:jbroot(@"/var/mobile/Library/RootHide/RootHideConfig.plist")];
    return [cfg[@"strictShieldModes"][bid] integerValue]==2;
}
static BOOL RHBlockedScheme(NSURL *url){NSString*s=url.scheme.lowercaseString;return [@[@"cydia",@"sileo",@"zbra",@"zebra",@"filza",@"activator",@"undecimus",@"odyssey",@"dopamine",@"checkra1n"] containsObject:s];}
static BOOL(*origCanOpenURL)(id,SEL,NSURL*);static BOOL hookCanOpenURL(id self,SEL cmd,NSURL*u){return RHBlockedScheme(u)?NO:origCanOpenURL(self,cmd,u);}
static BOOL hookFalse(id s,SEL c){return NO;} static BOOL hookFalseObj(id s,SEL c,id x){return NO;} static void hookNoop(id s,SEL c){} static void hookSetFalse(id s,SEL c,BOOL x){} static void hookSetNil(id s,SEL c,id x){}

static void RHInstall(Class cls,SEL sel,IMP imp,BOOL meta){
    if(!cls)return;Class target=meta?object_getClass(cls):cls;Method m=meta?class_getClassMethod(cls,sel):class_getInstanceMethod(cls,sel);if(!m)return;
    NSString*k=[NSString stringWithFormat:@"%p:%c:%@",cls,meta?'C':'I',NSStringFromSelector(sel)];@synchronized(RHInstalled){if([RHInstalled containsObject:k])return;[RHInstalled addObject:k];}
    MSHookMessageEx(target,sel,imp,NULL);
}
static void RHInstallOnClass(Class cls){
    const char*zero[]={"isJailbreak","isJailBroken","isJailbroken","isJail","JBCheck","isRiskyDevice","isRisky","isRisks","isHooked","isInjected","isDebuggerAttached"};
    for(NSUInteger i=0;i<sizeof(zero)/sizeof(zero[0]);i++){SEL q=sel_registerName(zero[i]);Method m=class_getInstanceMethod(cls,q);if(m&&method_getNumberOfArguments(m)==2)RHInstall(cls,q,(IMP)hookFalse,NO);Method cm=class_getClassMethod(cls,q);if(cm&&method_getNumberOfArguments(cm)==2)RHInstall(cls,q,(IMP)hookFalse,YES);}
    const char*one[]={"isRisky:","isJailbreak:","isJailBroken:","isJailbroken:"};for(NSUInteger i=0;i<sizeof(one)/sizeof(one[0]);i++){SEL q=sel_registerName(one[i]);Method m=class_getInstanceMethod(cls,q);if(m&&method_getNumberOfArguments(m)==3)RHInstall(cls,q,(IMP)hookFalseObj,NO);}
    RHInstall(cls,sel_registerName("markRiskyDevice"),(IMP)hookNoop,NO);RHInstall(cls,sel_registerName("setIsRisky:"),(IMP)hookSetFalse,NO);RHInstall(cls,sel_registerName("setIsRisks:"),(IMP)hookSetFalse,NO);RHInstall(cls,sel_registerName("setRisky:"),(IMP)hookSetFalse,NO);RHInstall(cls,sel_registerName("setRiskyMarkerFileDir:"),(IMP)hookSetNil,NO);RHInstall(cls,sel_registerName("setExtRiskData:"),(IMP)hookSetNil,NO);
}
static void RHScan(void){if(!RHStrictEnabled())return;int n=objc_getClassList(NULL,0);if(n<=0)return;Class*cs=(Class*)calloc((size_t)n,sizeof(Class));n=objc_getClassList(cs,n);for(int i=0;i<n;i++)RHInstallOnClass(cs[i]);free(cs);}
static void RHImageAdded(const struct mach_header*mh,intptr_t slide){(void)mh;(void)slide;dispatch_async(RHQueue,^{@autoreleasepool{RHScan();}});}
static void RHBundleLoaded(NSNotification*n){(void)n;dispatch_async(RHQueue,^{@autoreleasepool{RHScan();}});}
__attribute__((constructor))static void RHInit(void){@autoreleasepool{if(!RHStrictEnabled())return;RHInstalled=[NSMutableSet set];RHQueue=dispatch_queue_create("com.roothide.support.scan",DISPATCH_QUEUE_SERIAL);MSHookMessageEx(UIApplication.class,@selector(canOpenURL:),(IMP)hookCanOpenURL,(IMP*)&origCanOpenURL);RHScan();_dyld_register_func_for_add_image(RHImageAdded);[[NSNotificationCenter defaultCenter]addObserverForName:NSBundleDidLoadNotification object:nil queue:nil usingBlock:^(NSNotification*n){RHBundleLoaded(n);}];}}
