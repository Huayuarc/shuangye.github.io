#import "CPUThermalRecovered.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <stdatomic.h>

#ifndef CTR_S
#define CTR_S(x) [NSString stringWithUTF8String:(x)]
#endif

static _Atomic(NSInteger) gFallbackMode = CTRThermalModeSystem;
static _Atomic(CTRThermalModeProvider) gModeProvider = NULL;
static CTRThermalMode CurrentMode(void) {
    CTRThermalModeProvider p = atomic_load(&gModeProvider);
    NSInteger v = p ? p() : atomic_load(&gFallbackMode);
    return (v >= CTRThermalModeSystem && v <= CTRThermalModeAggressive) ? (CTRThermalMode)v : CTRThermalModeSystem;
}
void CTRSetThermalModeProvider(CTRThermalModeProvider p) { atomic_store(&gModeProvider, p); }
void CTRSetFallbackThermalMode(CTRThermalMode m) { atomic_store(&gFallbackMode, m); }

static id DeepMutable(id obj) {
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *d=[NSMutableDictionary dictionaryWithCapacity:[obj count]];
        [obj enumerateKeysAndObjectsUsingBlock:^(id k,id v,BOOL *stop){ d[k]=DeepMutable(v) ?: NSNull.null; }];
        return d;
    }
    if ([obj isKindOfClass:NSArray.class]) {
        NSMutableArray *a=[NSMutableArray arrayWithCapacity:[obj count]];
        for (id v in obj) [a addObject:DeepMutable(v) ?: NSNull.null];
        return a;
    }
    return obj;
}
static void ReplaceExisting(NSMutableDictionary *d, NSString *key, id value) {
    // 只改系统原配置中已存在的键，避免把产品级键污染进任意嵌套字典。
    if ([d isKindOfClass:NSMutableDictionary.class] && d[key] != nil) d[key]=value;
}
static void NormalizeDecisionRows(id table) {
    if (![table isKindOfClass:NSArray.class]) return;
    for (id row in table) if ([row isKindOfClass:NSMutableDictionary.class]) {
        NSMutableDictionary *d=row;
        // 样本逐行清空 dtThermalLevel；仅替换原行中已经存在的字段。
        ReplaceExisting(d,CTR_S("dtThermalLevel"),@0);
        if (d[CTR_S("intMax")] && d[CTR_S("intMin")]) d[CTR_S("intMin")]=d[CTR_S("intMax")];
        ReplaceExisting(d,CTR_S("target"),@150);
        ReplaceExisting(d,CTR_S("alternateTarget"),@150);
        ReplaceExisting(d,CTR_S("THERMAL_TRAP_LOAD"),@150);
        ReplaceExisting(d,CTR_S("THERMAL_TRAP_SLEEP"),@150);
        ReplaceExisting(d,CTR_S("ForcedThermalLevelTarget0"),@150);
        ReplaceExisting(d,CTR_S("ForcedThermalLevelTarget1"),@150);
        ReplaceExisting(d,CTR_S("ForcedThermalPressureLevelLightTarget"),@150);
    }
}
static void TransformDictionary(NSMutableDictionary *d, CTRThermalMode mode) {
    if (![d isKindOfClass:NSMutableDictionary.class]) return;
    // 性能策略：三个最大功率预算统一提高到 65000；
    // minPackagePower 保留设备原始值，避免锁高 Package 最低预算和增加空闲发热。
    ReplaceExisting(d,CTR_S("CPUMaxPower"),@65000);
    ReplaceExisting(d,CTR_S("GPUMaxPower"),@65000);
    ReplaceExisting(d,CTR_S("PackageMaxPower"),@65000);
    ReplaceExisting(d,CTR_S("maxCPU"),@5);
    ReplaceExisting(d,CTR_S("maxGPU"),@5);

    for (NSString *k in @[CTR_S("canForceThermalLevels"),CTR_S("monitorsCameraSensors"),CTR_S("usesInPocketContext"),
                           CTR_S("shouldDispatchVirtualTemp"),CTR_S("enableSendingMaxTempToDisplayDriver"),
                           CTR_S("needsLifetimeServo"),CTR_S("needsAppleConnectThermalTrapLogging"),
                           CTR_S("needsPushingTSFDtoDisplayDriver"),CTR_S("needsContextualClamp"),
                           CTR_S("needsArcControl"),CTR_S("needsPowerZoneTelemetry")])
        ReplaceExisting(d,k,@NO);
    ReplaceExisting(d,CTR_S("solarContextType"),@0);
    ReplaceExisting(d,CTR_S("forcedThermalLevelLower"),@20);
    ReplaceExisting(d,CTR_S("forcedThermalLevelUpper"),@21);

    // 样本会移除这些低功耗/通知配置。
    [d removeObjectForKey:CTR_S("lowParamsPeakPower")];
    [d removeObjectForKey:CTR_S("lowParamsSpeaker")];
    [d removeObjectForKey:CTR_S("lowNotificationLimits")];

    NormalizeDecisionRows(d[CTR_S("DecisionTreeTable")]);
    for (id v in d.allValues) {
        if ([v isKindOfClass:NSMutableDictionary.class]) TransformDictionary(v,mode);
        else if ([v isKindOfClass:NSMutableArray.class]) {
            for (id e in v) if ([e isKindOfClass:NSMutableDictionary.class]) TransformDictionary(e,mode);
        }
    }
}
id CTRTransformThermalConfiguration(id configuration, CTRThermalMode mode) {
    if (mode==CTRThermalModeSystem || !configuration) return configuration;
    id result=DeepMutable(configuration);
    if ([result isKindOfClass:NSMutableDictionary.class]) TransformDictionary(result,mode);
    else if ([result isKindOfClass:NSMutableArray.class])
        for (id e in result) if ([e isKindOfClass:NSMutableDictionary.class]) TransformDictionary(e,mode);
    return result;
}

#define ORIG(ret,n,...) static ret (*orig_##n)(id,SEL,##__VA_ARGS__)=NULL
ORIG(int,dieTemp);
static int new_dieTemp(id self,SEL cmd) { return CurrentMode()==CTRThermalModeAggressive ? 2600 : orig_dieTemp(self,cmd); }
ORIG(void,setHiP,BOOL);
static void new_setHiP(id self,SEL cmd,BOOL enabled) { orig_setHiP(self,cmd,CurrentMode()==CTRThermalModeSystem ? enabled : NO); }
ORIG(BOOL,lightPressure);
static BOOL new_lightPressure(id self,SEL cmd) { return CurrentMode()==CTRThermalModeSystem ? orig_lightPressure(self,cmd) : NO; }
ORIG(int,forcedPressure);
static int new_forcedPressure(id self,SEL cmd) { return CurrentMode()==CTRThermalModeSystem ? orig_forcedPressure(self,cmd) : 0; }
ORIG(int,highestSkin);
static int new_highestSkin(id self,SEL cmd) { return CurrentMode()==CTRThermalModeAggressive ? 0 : orig_highestSkin(self,cmd); }
ORIG(id,forcedLevel,id);
static id new_forcedLevel(id self,SEL cmd,id a) { return CurrentMode()==CTRThermalModeSystem ? orig_forcedLevel(self,cmd,a) : nil; }
ORIG(float,effort,float,float);
static float new_effort(id self,SEL cmd,float a,float b) {
    return CurrentMode()==CTRThermalModeAggressive ? orig_effort(self,cmd,23.0f,23.0f) : orig_effort(self,cmd,a,b);
}
static void Hook(const char *cn,const char *sn,IMP n,IMP *o) {
    Class c=objc_getClass(cn); SEL s=sel_registerName(sn);
    if(c && class_getInstanceMethod(c,s) && !*o) MSHookMessageEx(c,s,n,o);
}
void CTRInstallRecoveredThermalHooks(void) {
    // getConfigurationFor: 已由宿主的跨版本 C 函数 replacement 调用 CTRTransformThermalConfiguration，
    // 避免同一配置被 Objective-C 与 C 入口双重变换。
    Hook("CommonProduct","dieTempFilteredMaxAverage",(IMP)new_dieTemp,(IMP*)&orig_dieTemp);
    Hook("CommonProduct","setHiPFeatureEnabled:",(IMP)new_setHiP,(IMP*)&orig_setHiP);
    Hook("CommonProduct","shouldEnforceLightThermalPressure",(IMP)new_lightPressure,(IMP*)&orig_lightPressure);
    Hook("CommonProduct","getPotentialForcedThermalPressureLevel",(IMP)new_forcedPressure,(IMP*)&orig_forcedPressure);
    Hook("CommonProduct","getHighestSkinTemp",(IMP)new_highestSkin,(IMP*)&orig_highestSkin);
    Hook("CommonProduct","getPotentialForcedThermalLevel:",(IMP)new_forcedLevel,(IMP*)&orig_forcedLevel);
    Hook("SupervisorControl","calculateControlEffort:trigger:",(IMP)new_effort,(IMP*)&orig_effort);
    // evaluateDecisionTree 与 CPMS 继续由宿主现有 Hook 处理，避免重复链。
}
