//
//  MitigationHook.xm — CPUthermal v4（电池温度屏蔽完善：registry 读归一 + 周期性复位）
//
//  v4 变更依据（DevelopCubeLab/BatteryInfo + 真机 IOPMPowerSource dump）：
//   * 第三方/系统以 IOPMPowerSource 服务（IOServiceMatching）的 IORegistryEntryCreateCFProperties
//     拿整本属性快照；其对温度的表示顶层为 ×100（Temperature/Virtual 如 3839=38.39°C），
//     ChargerData.NotChargingReason=256(0x100) 与 ChargingCurrent=0 就是热停充实物。
//   * "能充一会又过热提示"说明 powerd 会周期性复查；因此除读边界归一外，新增
//     **周期(~1.6s)兜底**：定位 IOPMPowerSource 服务，把其上的热停充布尔清 NO、
//     原因码（NotChargingReason 等）写 0，主动抵消 powerd/BMS 重新落上的停充标签，
//     拉长"保持充电"窗口。
//   * 本版在 thermalmonitord 内【只】做 registry 读（单值+整本）温度/原因/暂停归一，
//     不重复 Tweak.x 已接管的 IORegistryEntrySetCFProperty(写)；写边界(SetCFProp清停)
//     仅在 powerd 内挂，避免同进程双写 Hook 冲突（1.6.4-74 教训）。

#import <Foundation/Foundation.h>
#import <notify.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <substrate.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/time.h>

#define NOTIFY_CPU_MODE "com.huayuarc.cputhermal/mitigationState"

static const int NeutralC    = 25;
static const int NeutralC10  = 250;
static const int NeutralC100 = 2500;
static const int SafeCurrentMA = 5000;
static const int PeriodicSec   = 2;      // keep-alive 周期（秒）
static int gToken = -1;

static kern_return_t (*orig_SetCFProp)(io_registry_entry_t, CFStringRef, CFTypeRef) = NULL;
static CFTypeRef      (*orig_SingleProp)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t) = NULL;
static kern_return_t (*orig_MultiProps)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t) = NULL;

static NSArray<NSString *> *kTempKeys;
static NSArray<NSString *> *kTempNested;
static NSArray<NSString *> *kPauseKeys;
static NSArray<NSString *> *kReasonKeys;
static NSArray<NSString *> *kLimitKeys;
static BOOL gPowerd = NO;
static BOOL gThermal = NO;

#pragma mark - 轻量诊断日志（帮助定位"温度残链"：powerd vs registry）
#ifndef S
#define S(x) (x)
#endif

static void logDiag(NSString *fmt, ...) {
    static int _rate = 0; // 限流：每 4 次才写 1 次，避免日志爆炸
    // 诊断始终写（用户主动开），每隔多次折叠到 ~0.5s 一拍
    char *base = getenv("CPUTHERMAL_DIAG_DIR");
    static NSString *dir;
    if (!dir) {
        for (NSString *d in @[ base?[NSString stringWithUTF8String:base]:nil,
                               S("/var/jb/usr/local/share/CPUthermal"),
                               S("/usr/local/share/CPUthermal") ]) {
            if (!d) continue;
            struct stat st;
            if (stat(d.fileSystemRepresentation,&st)==0 && (st.st_mode&S_IFDIR))
                dir = d;
        }
    }
    if (!dir) { dir = S("/tmp"); }
    static NSString *path;
    path = [dir stringByAppendingPathComponent:S("cputhermal-mit.log")];
    int fd = open(path.fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd<0) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv,NULL);
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *line = [NSString stringWithFormat:@"[%lld.%03d][%@] %@\n",(long long)tv.tv_sec,(int)(tv.tv_usec/1000),proc,body];
    const char *cs = line.UTF8String;
    if (cs && write(fd,cs,strlen(cs))>0){}
    close(fd);
}

static void initKeySets(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kTempKeys = @[ @"Temperature", @"VirtualTemperature", @"BatteryTemperature" ];
        kTempNested = @[ @"AverageTemperature", @"MinimumTemperature", @"MaximumTemperature" ];
        kPauseKeys = @[ @"ChargingPaused", @"ChargeInhibit", @"ChargeBlocked",
                        @"BatteryChargingInterrupted", @"BatteryChargingInterruptedCount",
                        @"ChargingCriticalTemperature", @"ForceDisableCharge" ];
        kReasonKeys = @[ @"NotChargingReason", @"BatteryNotChargingReason",
                         @"ChargeStateReason", @"ChargingLimitReasonCode" ];
        kLimitKeys = @[ @"ChargeCurrentLimit", @"ExternalChargeCurrentLimit",
                        @"ChargingCurrent", @"MaxChargeCurrent", @"NominalChargeCurrent",
                        @"AppleSmartBatteryMaxCurrent", @"ConfiguredChargeCurrent" ];
    });
}

static BOOL protectOn(void) {
    if (gToken == -1) notify_register_check(NOTIFY_CPU_MODE, &gToken);
    uint64_t s = 0; notify_get_state(gToken, &s);
    return ((s >> 10) & 1) || ((s >> 9) & 1);
}
static BOOL keyHit(NSString *k, NSArray<NSString *> *ks) {
    for (NSString *c in ks)
        if ([k rangeOfString:c options:NSCaseInsensitiveSearch|NSLiteralSearch].location != NSNotFound) return YES;
    return NO;
}

#pragma mark - 温度分档归一
static CFNumberRef neutralTemp(CFNumberRef n) {
    int v = 0; if (!CFNumberGetValue(n, kCFNumberSInt32Type, &v)) return NULL;
    int write = 0;
    if (v >= 1000) write = NeutralC100;
    else if (v >= 60) write = NeutralC10;
    else write = NeutralC;
    BOOL stable = (write == NeutralC100)  ? (v > 2300 && v < 2600)
                : (write == NeutralC10)   ? (v > 230  && v < 260 )
                : (v >= 20 && v <= 32);
    if (stable) return NULL;
    CFNumberRef nn = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &write);
    return nn;
}

#pragma mark - 递归 CF 清洗（温度/原因/暂停）
static CFTypeRef sanitizeNode(CFTypeRef node) {
    if (!node) return NULL;
    CFTypeID t = CFGetTypeID(node);
    if (t == CFDictionaryGetTypeID()) {
        CFDictionaryRef d = (CFDictionaryRef)node;
        CFIndex n = CFDictionaryGetCount(d);
        CFMutableDictionaryRef out = CFDictionaryCreateMutable(NULL, n, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFStringRef *keys = (CFStringRef *)calloc(n?n:1,sizeof(CFStringRef));
        CFTypeRef   *vals = (CFTypeRef *)calloc(n?n:1,sizeof(CFTypeRef));
        CFDictionaryGetKeysAndValues(d,(const void**)keys,(const void**)vals);
        for (CFIndex i=0;i<n;i++){
            NSString *kn=(__bridge NSString*)keys[i];
            BOOL isTemp = keyHit(kn,kTempKeys)||keyHit(kn,kTempNested);
            BOOL isReason= keyHit(kn,kReasonKeys);
            BOOL isPause = keyHit(kn,kPauseKeys);
            if (isTemp && vals[i] && CFGetTypeID(vals[i])==CFNumberGetTypeID()){
                CFNumberRef nn=neutralTemp((CFNumberRef)vals[i]);
                if (nn){ CFDictionarySetValue(out,keys[i],nn); CFRelease(nn); continue; }
            }
            if (isReason && vals[i] && CFGetTypeID(vals[i])==CFNumberGetTypeID()){
                int zz=0; CFNumberRef z=CFNumberCreate(NULL,kCFNumberIntType,&zz);
                CFDictionarySetValue(out,keys[i],z); CFRelease(z); continue;
            }
            if (isPause && vals[i] && CFGetTypeID(vals[i])==CFBooleanGetTypeID()){
                CFDictionarySetValue(out,keys[i],kCFBooleanFalse); continue;
            }
            CFTypeRef sub=sanitizeNode(vals[i]);
            if (sub){ CFDictionarySetValue(out,keys[i],sub); CFRelease(sub); }
            else {
                CFDictionarySetValue(out,keys[i],vals[i]); // SetValue 会 retain，保证原 dict 释放后仍存活
            }
        }
        free(keys); free(vals);
        return out;
    }
    if (t == CFArrayGetTypeID()){
        CFArrayRef a=(CFArrayRef)node; CFIndex n=CFArrayGetCount(a);
        CFMutableArrayRef out=CFArrayCreateMutable(NULL,n,&kCFTypeArrayCallBacks);
        for (CFIndex i=0;i<n;i++){ CFTypeRef it=CFArrayGetValueAtIndex(a,i); CFTypeRef sub=sanitizeNode(it);
            if (sub){ CFArrayAppendValue(out,sub); CFRelease(sub);} else CFArrayAppendValue(out,it);}
        return out;
    }
    return NULL;
}

#pragma mark - 读边界（powerd 与 thermalmonitord 都可挂）
static CFTypeRef hk_Single(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, uint32_t o){
    if (key && protectOn()){
        NSString *k=(__bridge NSString*)key;
        if (keyHit(k,kTempKeys)){ int v=NeutralC100; return CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&v); }
        if (keyHit(k,kReasonKeys)){ int z=0; return CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&z); }
        if (keyHit(k,kPauseKeys)) return (CFTypeRef)CFRetain(kCFBooleanFalse);
    }
    return orig_SingleProp?orig_SingleProp(e,key,a,o):NULL;
}
static kern_return_t hk_Multi(io_registry_entry_t e, CFMutableDictionaryRef *p, CFAllocatorRef a, uint32_t o){
    if (!orig_MultiProps) return p && !*p ? KERN_FAILURE : KERN_SUCCESS;
    kern_return_t r = orig_MultiProps(e,p,a,o);
    if (r==KERN_SUCCESS && p && *p && CFGetTypeID(*p)==CFDictionaryGetTypeID()){
        // 快照诊断：记录净化前真实顶层温度 & 相关停充标签
        NSDictionary *snap=(__bridge NSDictionary*)*p;
        int topT=-1, topV=-1, nestedReason=-1, nestedThermLimit=-1;
        if ([snap isKindOfClass:[NSDictionary class]]){
            NSNumber *t1=[snap objectForKey:@"Temperature"];
            NSNumber *t2=[snap objectForKey:@"VirtualTemperature"];
            if (t1) topT=[t1 intValue];
            if (t2) topV=[t2 intValue];
            NSDictionary *cd=[snap objectForKey:@"ChargerData"];
            if ([cd isKindOfClass:[NSDictionary class]]){
                NSNumber *nr=[cd objectForKey:@"NotChargingReason"];
                NSNumber *tl=[cd objectForKey:@"TimeChargingThermallyLimited"];
                if (nr) nestedReason=[nr intValue];
                if (tl) nestedThermLimit=[tl intValue];
            }
        }
        BOOL batteryLike = (topT>=0 || nestedReason>=0);
        if (batteryLike && chargeProtectOn())
            logDiag(@"multi T=%d V=%d reason=%d thermalLim=%d",topT,topV,nestedReason,nestedThermLimit);
        if (chargeProtectOn()){
            CFTypeRef clean=sanitizeNode(*p);
            if (clean){ CFRelease(*p); *p=(CFMutableDictionaryRef)clean; }
        }
    }
    return r;
}

#pragma mark - 写边界（仅 powerd）清停充/原因；温度不写
static int readMax(io_registry_entry_t e){
    CFMutableDictionaryRef pr=NULL;
    if (orig_MultiProps && orig_MultiProps(e,&pr,kCFAllocatorDefault,0)==KERN_SUCCESS && pr){
        int mx=0;
        for (NSString *k in kLimitKeys){ CFTypeRef v=CFDictionaryGetValue(pr,(__bridge CFStringRef)k);
            if (v&&CFGetTypeID(v)==CFNumberGetTypeID()){int t=0;CFNumberGetValue((CFNumberRef)v,kCFNumberIntType,&t);if(t>mx)mx=t;}}
        CFTypeRef cd=CFDictionaryGetValue(pr,CFSTR("ChargerData"));
        if (cd&&CFGetTypeID(cd)==CFDictionaryGetTypeID()) for (NSString*k in kLimitKeys) {CFTypeRef v=CFDictionaryGetValue((CFDictionaryRef)cd,(__bridge CFStringRef)k);
            if(v&&CFGetTypeID(v)==CFNumberGetTypeID()){int t=0;CFNumberGetValue((CFNumberRef)v,kCFNumberIntType,&t);if(t>mx)mx=t;}}
        CFRelease(pr);
        if (mx>0) return mx;
    }
    return 0;
}
static kern_return_t hk_Set(io_registry_entry_t e,CFStringRef key,CFTypeRef val){
    if (!key) return orig_SetCFProp?orig_SetCFProp(e,key,val):KERN_FAILURE;
    NSString *p=(__bridge NSString*)key;
    if (keyHit(p,kPauseKeys)) return orig_SetCFProp(e,key,kCFBooleanFalse);
    if (CFGetTypeID(val)==CFNumberGetTypeID() && keyHit(p,kReasonKeys)){int z=0;CFNumberRef n=CFNumberCreate(NULL,kCFNumberIntType,&z);kern_return_t r=orig_SetCFProp(e,key,n);CFRelease(n);return r;}
    if (CFGetTypeID(val)==CFNumberGetTypeID() && keyHit(p,kLimitKeys)){
        int v=0;CFNumberGetValue((CFNumberRef)val,kCFNumberIntType,&v);
        if (v<=0){int m=readMax(e);if(m<=0)m=SafeCurrentMA;CFNumberRef n=CFNumberCreate(NULL,kCFNumberIntType,&m);kern_return_t r=orig_SetCFProp(e,key,n);CFRelease(n);return r;}
    }
    return orig_SetCFProp?orig_SetCFProp(e,key,val):KERN_FAILURE;
}

#pragma mark - 周期兜底（清已落地的热停充标签）
static void periodicCleanup(void){
    if (!protectOn()) return;
    if (!orig_MultiProps || !orig_SetCFProp) return;
    mach_port_t mp=0; if (IOMasterPort(MACH_PORT_NULL,&mp)!=KERN_SUCCESS) return;
    CFMutableDictionaryRef m=IOServiceMatching("IOPMPowerSource");
    if (!m) return;
    io_service_t s=IOServiceGetMatchingService(mp,m);
    if (!s) return;
    CFMutableDictionaryRef cur=NULL;
    if (orig_MultiProps(s,&cur,kCFAllocatorDefault,0)==KERN_SUCCESS && cur){
        int rawT=-1,rawV=-1; int reasonSeen=0, pauseSeen=0;
        NSDictionary *mp=(__bridge NSDictionary*)cur;
        if ([mp isKindOfClass:[NSDictionary class]]){
            NSNumber *t1=[mp objectForKey:@"Temperature"];
            NSNumber *t2=[mp objectForKey:@"VirtualTemperature"];
            if (t1) rawT=[t1 intValue];
            if (t2) rawV=[t2 intValue];
            for (NSString *kp in kReasonKeys){
                NSNumber *nr=[mp objectForKey:kp];
                if (nr && [nr intValue]!=0) reasonSeen=1;
            }
            for (NSString *kp in kPauseKeys){
                NSNumber *pb=[mp objectForKey:kp];
                if (pb && [pb boolValue]) pauseSeen=1;
            }
        }
        if (rawT>=0 || reasonSeen||pauseSeen)
            logDiag(@"cleanup realT=%d realV=%d reason=%d pause=%d protect=%d",rawT,rawV,reasonSeen,pauseSeen,(int)protectOn());
        // 清 pause(true→NO) 与 reason(非0→0)
        for (NSString *k in kPauseKeys){
            CFTypeRef v=CFDictionaryGetValue(cur,(__bridge CFStringRef)k);
            if (v && CFGetTypeID(v)==CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v))
                orig_SetCFProp(s,(__bridge CFStringRef)k,kCFBooleanFalse);
        }
        for (NSString *k in kReasonKeys){
            CFTypeRef v=CFDictionaryGetValue(cur,(__bridge CFStringRef)k);
            if (v && CFGetTypeID(v)==CFNumberGetTypeID()){
                int q=0; CFNumberGetValue((CFNumberRef)v,kCFNumberIntType,&q);
                if (q!=0){ int zz=0; CFNumberRef z=CFNumberCreate(NULL,kCFNumberIntType,&zz);
                           if (z){ orig_SetCFProp(s,(__bridge CFStringRef)k,z); CFRelease(z);} }
            }
        }
        CFRelease(cur);
    }
    IOObjectRelease(s);
}

#pragma mark - ctor
%ctor {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *proc=[NSProcessInfo processInfo].processName;
        if ([proc isEqualToString:@"powerd"]) gPowerd=YES;
        else if ([proc isEqualToString:@"thermalmonitord"]) gThermal=YES;
        else return;
        initKeySets();
        void *k=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW);
        if (!k) return;
        void *wr=dlsym(k,"IORegistryEntrySetCFProperty");
        void *s1=dlsym(k,"IORegistryEntryCreateCFProperty");
        void *mn=dlsym(k,"IORegistryEntryCreateCFProperties");
        if (!mn) return;
        // 读：两进程都挂（递归温度/原因/暂停归一）
        MSHookFunction(mn,(void*)hk_Multi,(void**)&orig_MultiProps);
        if (s1) MSHookFunction(s1,(void*)hk_Single,(void**)&orig_SingleProp);
        // 写停充/原因/电流上限重放：仅在 powerd（thermalmonitord 由 Tweak.x 管）
        if (wr && gPowerd) MSHookFunction(wr,(void*)hk_Set,(void**)&orig_SetCFProp);

        if (gPowerd || gThermal){
            dispatch_source_t t=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,
                        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0));
            dispatch_source_set_timer(t,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),
                        PeriodicSec*NSEC_PER_SEC,0.5*NSEC_PER_SEC);
            dispatch_source_set_event_handler(t,^{ periodicCleanup(); });
            dispatch_resume(t);
        }
    });
}
