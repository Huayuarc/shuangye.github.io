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
#include <string.h>
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
static NSArray<NSString *> *kOptimKeys;   // 80% 优化充电/涓流停 相关布尔 → 清 NO
static BOOL gPowerd = NO;
static BOOL gThermal = NO;
static uint64_t gLastBreakNS = 0;

#pragma mark - 轻量诊断日志（帮助定位"温度残链"：powerd vs registry）
static NSString *diagLogPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *env = getenv("CPUTHERMAL_DIAG_DIR") ? [NSString stringWithUTF8String:getenv("CPUTHERMAL_DIAG_DIR")] : nil;
    NSString *dir = nil;
    // 候选目录：优先 env，其次工程安装目录，最后 /var/mobile/Media、/tmp
    NSArray *cands = env ? @[env] : @[@"/var/jb/usr/local/share/CPUthermal",
                                      @"/usr/local/share/CPUthermal",
                                      @"/var/mobile/Media"];
    for (NSString *c in cands) {
        BOOL isd=NO;
        if ([fm fileExistsAtPath:c isDirectory:&isd]) { if (isd){ dir=c; break; } }
        else { // 目录不存在 → 尝试创建（powerd=root 可写 /var/jb 与 /usr/local、/var/mobile/Media）
            if ([fm createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:nil]) { dir=c; break; }
        }
    }
    if (!dir) dir = @"/tmp";
    return [dir stringByAppendingPathComponent:@"cputhermal-mit.log"];
}
static void logDiag(NSString *fmt, ...) {
    NSString *path = diagLogPath();
    int fd = open(path.fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND, 0644);
    if (fd<0) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    struct timeval tv; gettimeofday(&tv,NULL);
    NSString *proc = [[NSProcessInfo processInfo] processName];
    NSString *line = [NSString stringWithFormat:@"[%lld.%03d][%@] %@\n",(long long)tv.tv_sec,(int)(tv.tv_usec/1000),proc,body];
    const char *cs = line.UTF8String;
    if (cs) (void)write(fd,cs,strlen(cs));
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
        kOptimKeys = @[ @"PredictiveChargingInhibit", @"SmartChargeState", @"OptimizedChargingValue" ];
    });
}

static BOOL protectOn(void) {
    if (gToken == -1) notify_register_check(NOTIFY_CPU_MODE, &gToken);
    uint64_t s = 0; notify_get_state(gToken, &s);
    return ((s >> 10) & 1) || ((s >> 9) & 1);
}
static BOOL fastChargeOn(void) {   // 强制满血快充（bit9）：含 killThermalStop 语义（无视发热）
    if (gToken == -1) notify_register_check(NOTIFY_CPU_MODE, &gToken);
    uint64_t s = 0; notify_get_state(gToken, &s);
    return (s >> 9) & 1;
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
        if (batteryLike && protectOn())
            logDiag(@"multi T=%d V=%d reason=%d thermalLim=%d",topT,topV,nestedReason,nestedThermLimit);
        if (protectOn()){
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
    if (!orig_SetCFProp) return KERN_FAILURE;
    if (!key) return orig_SetCFProp(e,key,val);
    // 门控：仅当“禁止高温停充(bit10)”或“强制满血快充(bit9)”任一开启才干预；
    // 否则完全放行，避免未开启时也无条件改写（回归 -48 前行为）。
    if (!protectOn()) return orig_SetCFProp(e,key,val);

    NSString *p=(__bridge NSString*)key;
    if (keyHit(p,kPauseKeys)) return orig_SetCFProp(e,key,kCFBooleanFalse);
    if (CFGetTypeID(val)==CFNumberGetTypeID() && keyHit(p,kReasonKeys)){
        int z=0;CFNumberRef n=CFNumberCreate(NULL,kCFNumberIntType,&z);
        kern_return_t r=orig_SetCFProp(e,key,n);CFRelease(n);return r;
    }
    if (CFGetTypeID(val)==CFNumberGetTypeID() && keyHit(p,kLimitKeys)){
        int v=0;CFNumberGetValue((CFNumberRef)val,kCFNumberIntType,&v);
        int m=readMax(e);
        if (m<=0) m=SafeCurrentMA;
        // 热控把上限降到 0/负 → 恢复原机量；或满血快充开启且被压到明显低于原机(<2/3) → 提回满量
        BOOL tooLowFast = (v>0 && m>0 && fastChargeOn() && v < (m*2/3));
        if (v<=0 || tooLowFast){
            CFNumberRef n=CFNumberCreate(NULL,kCFNumberIntType,&m);
            kern_return_t r=orig_SetCFProp(e,key,n);CFRelease(n);return r;
        }
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
        NSDictionary *sn=(__bridge NSDictionary*)cur;

        // ---------- 快照提取 ----------
        int rawT=-1,rawV=-1; int reasonSeen=0, pauseSeen=0;
        NSNumber *cc=[sn objectForKey:@"CurrentCapacity"];       // %
        int pct = cc? [cc intValue] : 101;
        NSNumber *vb=[sn objectForKey:@"AppleRawBatteryVoltage"];
        if (!vb) vb=[sn objectForKey:@"Voltage"];
        int vmV = vb? [vb intValue] : 0;                          // mV
        NSDictionary *cd=[sn objectForKey:@"ChargerData"];
        if (![cd isKindOfClass:[NSDictionary class]]) cd=nil;
        double targetMV = 0; NSNumber *cvm=[cd objectForKey:@"ChargingVoltage"];
        if (cvm) targetMV = [cvm doubleValue];                    // 常见 mV
        if (targetMV<=0) targetMV = 4230.0;
        NSNumber *t1=[sn objectForKey:@"Temperature"];
        NSNumber *t2=[sn objectForKey:@"VirtualTemperature"];
        // 温度取整(×100)
        if (t1) rawT=[t1 intValue];
        if (t2) rawV=[t2 intValue];
        // reasons(top+nested)
        for (NSDictionary *mp in @[sn, cd ?: @{}])
            for (NSString *kp in kReasonKeys){ NSNumber *nr=[mp objectForKey:kp]; if (nr && [nr intValue]!=0) reasonSeen=1; }
        // pause
        for (NSString *kp in kPauseKeys){ NSNumber *pb=[sn objectForKey:kp]; if (pb && [pb boolValue]) pauseSeen=1; }
        BOOL fully = [[sn objectForKey:@"FullyCharged"] boolValue];
        BOOL optim = NO;
        for (NSString *kp in kOptimKeys){
            id o=[sn objectForKey:kp];
            if ([o isKindOfClass:[NSNumber class]] && [o boolValue]) optim=YES;
        }

        if (rawT>=0 || reasonSeen||pauseSeen||optim||fully)
            logDiag(@"cleanup pct=%d vmV=%d tgt=%d fully=%d optim=%d T=%d V=%d reason=%d pause=%d prot=%d",
                    pct,vmV,(int)targetMV,(int)fully,(int)optim,rawT,rawV,reasonSeen,pauseSeen,(int)protectOn());

        // ---------- 一、清停充布尔 / 原因码 / 优化(涓流)位 ----------
        for (NSString *k in kPauseKeys){
            CFTypeRef v=CFDictionaryGetValue(cur,(__bridge CFStringRef)k);
            if (v && CFGetTypeID(v)==CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v))
                orig_SetCFProp(s,(__bridge CFStringRef)k,kCFBooleanFalse);
        }
        for (NSString *k in kReasonKeys){
            CFTypeRef v=CFDictionaryGetValue(cur,(__bridge CFStringRef)k);
            if (v && CFGetTypeID(v)==CFNumberGetTypeID()){
                int q=0; CFNumberGetValue((CFNumberRef)v,kCFNumberIntType,&q);
                if (q!=0){ int zz=0; CFNumberRef zz2=CFNumberCreate(NULL,kCFNumberIntType,&zz);
                           if (zz2){ orig_SetCFProp(s,(__bridge CFStringRef)k,zz2); CFRelease(zz2);} }
            }
        }
        for (NSString *k in kOptimKeys){
            CFTypeRef v=CFDictionaryGetValue(cur,(__bridge CFStringRef)k);
            if (v && CFGetTypeID(v)==CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v))
                orig_SetCFProp(s,(__bridge CFStringRef)k,kCFBooleanFalse);
        }

        // ---------- 二、解除 iOS 80+%/涓流提前截断 ----------
        // 仅“电量<100 且 电压仍距该段 CV 目标>90mV 却被置 fully/reason/optim/pause”时撤销(事件型，
        // 带 2s 节流；不写 External/IsCharging/原始电流——遵守 1.6.4-33 输入语义禁令)。
        if (pct<100 && vmV>0 && ((double)vmV) < targetMV-90.0){
            if (fully || reasonSeen || optim || pauseSeen){
                if (fully) { orig_SetCFProp(s,CFSTR("FullyCharged"),kCFBooleanFalse); }
                uint64_t nowNS = dispatch_time(DISPATCH_TIME_NOW,0);
                if (gLastBreakNS==0 || (nowNS-gLastBreakNS) > (uint64_t)(2.0*NSEC_PER_SEC)){
                    gLastBreakNS=nowNS;
                    logDiag(@"break80limit: pct=%d v=%dmV cv-tgt=%.0fmV cleared fully/reason/optim/pause",pct,vmV,targetMV);
                }
            }
        }
        CFRelease(cur);
    }
    IOObjectRelease(s);
}

#pragma mark - IOConnect/userclient 探针（powerd 电池读路径定位，registry 之外）
static mach_port_t gBattC[24]; static int gBattCN=0;
static BOOL connBat(mach_port_t c){ for(int i=0;i<gBattCN;i++) if(gBattC[i]==c) return YES; return NO; }
typedef kern_return_t (*t_open)(io_service_t, task_port_t, uint32_t, io_connect_t*);
static t_open o_Open;
static kern_return_t h_Open(io_service_t svc, task_port_t tk, uint32_t ty, io_connect_t* co){
    kern_return_t r = o_Open?o_Open(svc,tk,ty,co):KERN_FAILURE;
    if (r==KERN_SUCCESS && co && *co){
        io_name_t nm={0}; IORegistryEntryGetName(svc,nm);
        if (strstr(nm,"SmartBattery")||strstr(nm,"PMU")||strstr(nm,"PowerSource")||strstr(nm,"gas-gauge")||strstr(nm,"Charger")){
            logDiag(@"UIOpen type=%u name=%s",(unsigned)ty, nm);
            if (gBattCN<24) gBattC[gBattCN++]=*co;
        }
    }
    return r;
}
typedef kern_return_t (*t_close)(io_connect_t); static t_close o_Close;
static kern_return_t h_Close(io_connect_t c){ if (connBat(c)) logDiag(@"UIClose"); return o_Close?o_Close(c):KERN_FAILURE; }
static void traceSel(const char* kind,uint32_t sel,uint32_t iCn,uint32_t oCn,const void* outs,size_t sSz){
    if (!protectOn()) return;
    size_t n = sSz>40?40:sSz;
    char hx[160]; int hw=0; const unsigned char* p=(const unsigned char*)outs;
    for (size_t i=0;i<n && hw<150;i++) hw+=snprintf(hx+hw,sizeof(hx)-hw,"%02x",p[i]);
    logDiag(@"UIOC %s sel=%u iN=%u oN=%u sz=%zu [%s]",kind,(unsigned)sel,iCn,oCn,sSz,hx);
}
typedef kern_return_t (*t_m)(mach_port_t,uint32_t,const uint64_t*,uint32_t,const void*,size_t,uint64_t*,uint32_t*,void*,size_t*);
static t_m o_CM;
static kern_return_t h_CM(mach_port_t c,uint32_t sel,const uint64_t*in,uint32_t iC,const void*is,size_t isz,uint64_t*out,uint32_t*oc,void*os,size_t*osz){
    BOOL b=connBat(c);
    kern_return_t r=o_CM?o_CM(c,sel,in,iC,is,isz,out,oc,os,osz):KERN_FAILURE;
    if (b){ size_t z=osz?*osz:0; traceSel("CM",sel,iC,oc?*oc:0,os,z); }
    return r;
}
typedef kern_return_t (*t_s)(mach_port_t,uint32_t,const void*,size_t,void*,size_t*);
static t_s o_CS;
static kern_return_t h_CS(mach_port_t c,uint32_t sel,const void*is,size_t isz,void*os,size_t*osz){
    BOOL b=connBat(c);
    kern_return_t r=o_CS?o_CS(c,sel,is,isz,os,osz):KERN_FAILURE;
    if (b){ size_t z=osz?*osz:0; traceSel("CS",sel,(uint32_t)isz,(uint32_t)z,os,z); }
    return r;
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
        // bootmark：任何守护被注入后都无条件写一行，用于判定“dylib 是否真的在 powerd/thermal 内运行”
        // 若该行都没出现 → 未载入（需完整重启用户空间）或目录/权限问题。
        logDiag(@"boot proc=%@ pid=%d", proc, (int)getpid());
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

        // userclient 探针（powerd only）
        if (gPowerd){
            void *po=dlsym(k,"IOServiceOpen");
            void *pc=dlsym(k,"IOServiceClose");
            void *pm=dlsym(k,"IOConnectCallMethod");
            void *ps=dlsym(k,"IOConnectCallStructMethod");
            if (po) MSHookFunction(po,(void*)h_Open,(void**)&o_Open);
            if (pc) MSHookFunction(pc,(void*)h_Close,(void**)&o_Close);
            if (pm) MSHookFunction(pm,(void*)h_CM,(void**)&o_CM);
            if (ps) MSHookFunction(ps,(void*)h_CS,(void**)&o_CS);
        }

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
