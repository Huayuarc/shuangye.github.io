#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <fcntl.h>
#import <stdio.h>
#import <stdarg.h>
#import <errno.h>
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
static BOOL RHSensitivePath(const char *p){if(!p)return NO;NSString*s=[NSString stringWithUTF8String:p].lowercaseString;NSArray*marks=@[@"/applications/cydia.app",@"/applications/sileo.app",@"/library/mobilesubstrate",@"/usr/lib/substrate",@"/usr/bin/ssh",@"/private/etc/apt",@"/var/jb",@"/.jbroot",@"/private/jailbreak.txt",@"/var/checkra1n",@"/var/binpack",@"/usr/lib/tweakloader.dylib",@"/usr/lib/ellekit"];for(NSString*m in marks)if([s containsString:m])return YES;return NO;}
static BOOL RHSensitiveImage(const char*p){if(!p)return NO;NSString*s=[NSString stringWithUTF8String:p].lowercaseString;return [s containsString:@"roothidesupport"]||[s containsString:@"mobilesubstrate"]||[s containsString:@"ellekit"]||[s containsString:@"tweakloader"]||[s containsString:@"/var/jb/"]||[s containsString:@"/.jbroot-"];}
static int(*origAccess)(const char*,int);static int hookAccess(const char*p,int m){if(RHSensitivePath(p)){errno=ENOENT;return -1;}return origAccess(p,m);}static int(*origStat)(const char*,struct stat*);static int hookStat(const char*p,struct stat*b){if(RHSensitivePath(p)){errno=ENOENT;return -1;}return origStat(p,b);}static int(*origLstat)(const char*,struct stat*);static int hookLstat(const char*p,struct stat*b){if(RHSensitivePath(p)){errno=ENOENT;return -1;}return origLstat(p,b);}static int(*origOpen)(const char*,int,...);static int hookOpen(const char*p,int f,...){mode_t mode=0;if(f&O_CREAT){va_list a;va_start(a,f);mode=va_arg(a,int);va_end(a);}if(RHSensitivePath(p)){errno=ENOENT;return -1;}return (f&O_CREAT)?origOpen(p,f,mode):origOpen(p,f);}static FILE*(*origFopen)(const char*,const char*);static FILE*hookFopen(const char*p,const char*m){if(RHSensitivePath(p)){errno=ENOENT;return NULL;}return origFopen(p,m);}
extern int ptrace(int,pid_t,caddr_t,int);
static int(*origPtrace)(int,pid_t,caddr_t,int);static int hookPtrace(int req,pid_t pid,caddr_t a,int d){if(req==31)return 0;return origPtrace(req,pid,a,d);}static int(*origSysctl)(int*,u_int,void*,size_t*,void*,size_t);static int hookSysctl(int*n,u_int l,void*o,size_t*ol,void*nn,size_t nl){int r=origSysctl(n,l,o,ol,nn,nl);if(r==0&&n&&l>=4&&n[0]==CTL_KERN&&n[1]==KERN_PROC&&o&&ol&&*ol>=sizeof(struct kinfo_proc)){struct kinfo_proc*k=o;k->kp_proc.p_flag&=~P_TRACED;}return r;}
static const char*(*origImageName)(uint32_t);static const char*hookImageName(uint32_t i){const char*p=origImageName(i);return RHSensitiveImage(p)?"/usr/lib/libSystem.B.dylib":p;}
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
__attribute__((constructor))static void RHInit(void){@autoreleasepool{if(!RHStrictEnabled())return;RHInstalled=[NSMutableSet set];RHQueue=dispatch_queue_create("com.roothide.support.scan",DISPATCH_QUEUE_SERIAL);MSHookFunction((void*)access,(void*)hookAccess,(void**)&origAccess);MSHookFunction((void*)stat,(void*)hookStat,(void**)&origStat);MSHookFunction((void*)lstat,(void*)hookLstat,(void**)&origLstat);MSHookFunction((void*)open,(void*)hookOpen,(void**)&origOpen);MSHookFunction((void*)fopen,(void*)hookFopen,(void**)&origFopen);MSHookFunction((void*)ptrace,(void*)hookPtrace,(void**)&origPtrace);MSHookFunction((void*)sysctl,(void*)hookSysctl,(void**)&origSysctl);MSHookFunction((void*)_dyld_get_image_name,(void*)hookImageName,(void**)&origImageName);MSHookMessageEx(UIApplication.class,@selector(canOpenURL:),(IMP)hookCanOpenURL,(IMP*)&origCanOpenURL);RHScan();_dyld_register_func_for_add_image(RHImageAdded);[[NSNotificationCenter defaultCenter]addObserverForName:NSBundleDidLoadNotification object:nil queue:nil usingBlock:^(NSNotification*n){RHBundleLoaded(n);}];}}
