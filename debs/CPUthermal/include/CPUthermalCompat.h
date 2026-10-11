#ifndef CPUTHERMAL_COMPAT_H
#define CPUTHERMAL_COMPAT_H

// isolation.9 跨版本适配小工具：被 Tools/CPUthermalChargeTool.m 与 Tweak.x 共同使用。
// 只提供“读取与解析”能力，不包含任何写入、定时器或日志副作用。

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <stdlib.h>
#include <string.h>

// 电流防降频：充电电流压力通知（命名沿用 com.huayuarc.cputhermal/<name> 约定）。
static const char *kCPUthermalCurrentStressNotifC = "com.huayuarc.cputhermal/currentStress";

// 系统主版本号（15/16/17...），进程内缓存一次；无法解析时返回 0（调用方必须把 0 当作未知，不得当作任意已知版本）。
static inline int CPUthermalSystemMajorVersion(void) {
    static int cachedMajorVersion = -1;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        int major = 0;
        @try {
            NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
            if (version.majorVersion > 0 && version.majorVersion < 100) major = (int)version.majorVersion;
        } @catch (__unused NSException *exception) {
            major = 0;
        }
        cachedMajorVersion = major;
    });
    return cachedMajorVersion < 0 ? 0 : cachedMajorVersion;
}

// 数字解析：CFNumber（整数/浮点/布尔）与 CFString 都容忍；无法确定数值时返回 NO 并保持 *out 不变。
static inline BOOL CPUthermalNumberValue(id value, double *out) {
    if (!value) return NO;
    if ([value isKindOfClass:[NSNumber class]]) {
        double number = [(NSNumber *)value doubleValue];
        if (out) *out = number;
        return YES;
    }
    CFTypeRef raw = (__bridge CFTypeRef)value;
    CFTypeID type = CFGetTypeID(raw);
    if (type == CFBooleanGetTypeID()) {
        if (out) *out = CFBooleanGetValue((CFBooleanRef)raw) ? 1.0 : 0.0;
        return YES;
    }
    if (type == CFNumberGetTypeID()) {
        double number = 0;
        if (!CFNumberGetValue((CFNumberRef)raw, kCFNumberDoubleType, &number)) return NO;
        if (out) *out = number;
        return YES;
    }
    if (type == CFStringGetTypeID() || [value isKindOfClass:[NSString class]]) {
        NSString *text = [value isKindOfClass:[NSString class]] ? (NSString *)value : [(__bridge NSString *)raw description];
        const char *utf8 = [text UTF8String];
        if (!utf8 || !*utf8) return NO;
        char *end = NULL;
        double parsed = strtod(utf8, &end);
        if (end == utf8) return NO;             // 无数字前缀
        while (end && (*end == ' ' || *end == '\t' || *end == '\n' || *end == '\r')) end++;
        if (end && *end != '\0') return NO;      // 尾随非数字内容（例如单位）视为不可解析，避免误读
        if (out) *out = parsed;
        return YES;
    }
    return NO;
}

// 按顺序回退读取 IORegistry 数字属性：命中第一个可解析的键即返回 YES，matchedKey 回填实际命中键。
static inline BOOL CPUthermalPropertyNumber(io_service_t service, NSArray<NSString *> *keys, double *out, NSString **matchedKey) {
    if (matchedKey) *matchedKey = nil;
    if (service == IO_OBJECT_NULL || ![keys isKindOfClass:[NSArray class]]) return NO;
    for (NSString *key in keys) {
        if (![key isKindOfClass:[NSString class]] || key.length == 0) continue;
        CFTypeRef property = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
        if (!property) continue;                 // 键不存在：跳过该键
        BOOL ok = CPUthermalNumberValue((__bridge id)property, out);
        CFRelease(property);
        if (ok) {
            if (matchedKey) *matchedKey = key;
            return YES;
        }
    }
    return NO;
}

#endif
