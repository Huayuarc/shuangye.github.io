// ============================================================================
// Heaven.xm — 逆向还原 Logos 源码
// 插件名: Heaven (com.huayuarc.xinji.heaven)
// 作者: 倔强的石头
// 类型: 设备信息伪装 / 修改 / 清理
// 架构: arm64
//
// [RE] 标注 = 逆向推测部分
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonCryptor.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#if __has_include(<sys/ptrace.h>)
#import <sys/ptrace.h>
#else
#ifdef __cplusplus
extern "C" {
#endif
extern int ptrace(int request, pid_t pid, void *addr, int data);
#ifdef __cplusplus
}
#endif
#endif
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
#import <sys/stat.h>
#import <unistd.h>
#import <dlfcn.h>
#import <notify.h>
#import <AdSupport/AdSupport.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreLocation/CLLocationManager.h>
#import <CoreLocation/CLLocation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <errno.h>
#import <resolv.h>
#import <dns_sd.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Logos 头
#import <substrate.h>

// ============================================================================
// 字符串常量定义
// ============================================================================

// 服务器地址
static NSString *const kHeavenServerBase = @"https://new.abc3.vip";
static NSString *const kHeavenAPIReport  = @"/api/r";

// HMAC 密钥 [RE] 推测: 用于请求签名
static NSString *const kHeavenHMACKey1 = @"heaven2026securekey12345678901";
// Preferences 域
static NSString *const kHeavenPrefsPath = @"/var/mobile/Library/Preferences/com.huayuarc.xinji.heaven.plist";

// 日志标签
static NSString *const kLogTag = @"[Heaven]";

// ============================================================================
// 设备型号映射表 (model → 名称 → 规格)
// [RE] 推测: 完整映射来自插件二进制字符串表
// ============================================================================
static NSDictionary *sDeviceModelMap = nil;
static dispatch_once_t sModelMapOnce;

static NSDictionary *getDeviceModelMap(void) {
    dispatch_once(&sModelMapOnce, ^{
        sDeviceModelMap = @{
            @"iPhone10,3": @{
                @"name": @"iPhone X",
                @"cpu": @"A11 Bionic",
                @"arch": @"arm64",
                @"generation": @"10"
            },
            @"iPhone10,6": @{
                @"name": @"iPhone X (Global)",
                @"cpu": @"A11 Bionic",
                @"arch": @"arm64",
                @"generation": @"10"
            },
            @"iPhone11,2": @{
                @"name": @"iPhone XS",
                @"cpu": @"A12 Bionic",
                @"arch": @"arm64e",
                @"generation": @"11"
            },
            @"iPhone11,4": @{
                @"name": @"iPhone XS Max",
                @"cpu": @"A12 Bionic",
                @"arch": @"arm64e",
                @"generation": @"11"
            },
            @"iPhone11,6": @{
                @"name": @"iPhone XS Max (China)",
                @"cpu": @"A12 Bionic",
                @"arch": @"arm64e",
                @"generation": @"11"
            },
            @"iPhone11,8": @{
                @"name": @"iPhone XR",
                @"cpu": @"A12 Bionic",
                @"arch": @"arm64e",
                @"generation": @"11"
            },
            @"iPhone12,1": @{
                @"name": @"iPhone 11",
                @"cpu": @"A13 Bionic",
                @"arch": @"arm64e",
                @"generation": @"12"
            },
            @"iPhone12,3": @{
                @"name": @"iPhone 11 Pro",
                @"cpu": @"A13 Bionic",
                @"arch": @"arm64e",
                @"generation": @"12"
            },
            @"iPhone12,5": @{
                @"name": @"iPhone 11 Pro Max",
                @"cpu": @"A13 Bionic",
                @"arch": @"arm64e",
                @"generation": @"12"
            },
            @"iPhone12,8": @{
                @"name": @"iPhone SE (2nd gen)",
                @"cpu": @"A13 Bionic",
                @"arch": @"arm64e",
                @"generation": @"12"
            },
            @"iPhone13,1": @{
                @"name": @"iPhone 12 mini",
                @"cpu": @"A14 Bionic",
                @"arch": @"arm64e",
                @"generation": @"13"
            },
            @"iPhone13,2": @{
                @"name": @"iPhone 12",
                @"cpu": @"A14 Bionic",
                @"arch": @"arm64e",
                @"generation": @"13"
            },
            @"iPhone13,3": @{
                @"name": @"iPhone 12 Pro",
                @"cpu": @"A14 Bionic",
                @"arch": @"arm64e",
                @"generation": @"13"
            },
            @"iPhone13,4": @{
                @"name": @"iPhone 12 Pro Max",
                @"cpu": @"A14 Bionic",
                @"arch": @"arm64e",
                @"generation": @"13"
            },
            @"iPhone14,2": @{
                @"name": @"iPhone 13 Pro",
                @"cpu": @"A15 Bionic",
                @"arch": @"arm64e",
                @"generation": @"14"
            },
            @"iPhone14,3": @{
                @"name": @"iPhone 13 Pro Max",
                @"cpu": @"A15 Bionic",
                @"arch": @"arm64e",
                @"generation": @"14"
            },
            @"iPhone14,4": @{
                @"name": @"iPhone 13 mini",
                @"cpu": @"A15 Bionic",
                @"arch": @"arm64e",
                @"generation": @"14"
            },
            @"iPhone14,5": @{
                @"name": @"iPhone 13",
                @"cpu": @"A15 Bionic",
                @"arch": @"arm64e",
                @"generation": @"14"
            },
            @"iPhone14,6": @{
                @"name": @"iPhone SE (3rd gen)",
                @"cpu": @"A15 Bionic",
                @"arch": @"arm64e",
                @"generation": @"14"
            },
            @"iPhone14,7": @{
                @"name": @"iPhone 14",
                @"cpu": @"A15 Bionic",
                @"arch": @"arm64e",
                @"generation": @"14"
            },
            @"iPhone14,8": @{
                @"name": @"iPhone 14 Plus",
                @"cpu": @"A15 Bionic",
                @"arch": @"arm64e",
                @"generation": @"14"
            },
            @"iPhone15,2": @{
                @"name": @"iPhone 14 Pro",
                @"cpu": @"A16 Bionic",
                @"arch": @"arm64e",
                @"generation": @"15"
            },
            @"iPhone15,3": @{
                @"name": @"iPhone 14 Pro Max",
                @"cpu": @"A16 Bionic",
                @"arch": @"arm64e",
                @"generation": @"15"
            },
            @"iPhone15,4": @{
                @"name": @"iPhone 15",
                @"cpu": @"A16 Bionic",
                @"arch": @"arm64e",
                @"generation": @"15"
            },
            @"iPhone15,5": @{
                @"name": @"iPhone 15 Plus",
                @"cpu": @"A16 Bionic",
                @"arch": @"arm64e",
                @"generation": @"15"
            },
            @"iPhone16,1": @{
                @"name": @"iPhone 15 Pro",
                @"cpu": @"A17 Pro",
                @"arch": @"arm64e",
                @"generation": @"16"
            },
            @"iPhone16,2": @{
                @"name": @"iPhone 15 Pro Max",
                @"cpu": @"A17 Pro",
                @"arch": @"arm64e",
                @"generation": @"16"
            },
            @"iPhone17,1": @{
                @"name": @"iPhone 16",
                @"cpu": @"A18",
                @"arch": @"arm64e",
                @"generation": @"17"
            },
            @"iPhone17,2": @{
                @"name": @"iPhone 16 Plus",
                @"cpu": @"A18",
                @"arch": @"arm64e",
                @"generation": @"17"
            },
            @"iPhone17,3": @{
                @"name": @"iPhone 16 Pro",
                @"cpu": @"A18 Pro",
                @"arch": @"arm64e",
                @"generation": @"17"
            },
            @"iPhone17,4": @{
                @"name": @"iPhone 16 Pro Max",
                @"cpu": @"A18 Pro",
                @"arch": @"arm64e",
                @"generation": @"17"
            },
            // iPad 部分
            @"iPad13,1": @{
                @"name": @"iPad Air (4th gen)",
                @"cpu": @"A14 Bionic",
                @"arch": @"arm64e",
                @"generation": @"13"
            },
            @"iPad13,4": @{
                @"name": @"iPad Pro 11\" (3rd gen)",
                @"cpu": @"M1",
                @"arch": @"arm64e",
                @"generation": @"13"
            },
            @"iPad14,1": @{
                @"name": @"iPad mini (6th gen)",
                @"cpu": @"A15 Bionic",
                @"arch": @"arm64e",
                @"generation": @"14"
            },
        };
    });
    return sDeviceModelMap;
}

// ============================================================================
// 工具函数 — HMAC-SHA256
// ============================================================================
static NSString *heaven_hmac_sha256(NSString *data, NSString *key) {
    const char *cData = [data cStringUsingEncoding:NSUTF8StringEncoding];
    const char *cKey  = [key cStringUsingEncoding:NSUTF8StringEncoding];

    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);

    NSMutableString *hash = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hash appendFormat:@"%02x", cHMAC[i]];
    }
    return [hash copy];
}

// ============================================================================
// 工具函数 — 生成随机 Nonce
// ============================================================================
static NSString *heaven_generate_nonce(void) {
    uint8_t bytes[16];
    arc4random_buf(bytes, sizeof(bytes));
    NSMutableString *nonce = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) {
        [nonce appendFormat:@"%02x", bytes[i]];
    }
    return [nonce copy];
}

// ============================================================================
// 工具函数 — JSON 序列化
// ============================================================================
static NSString *heaven_json_stringify(NSDictionary *dict) {
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (!jsonData || error) return @"{}";
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

// ============================================================================
// 工具函数 — 读取/写入偏好设置
// ============================================================================
static id heaven_prefs_read(NSString *key, id defaultValue) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kHeavenPrefsPath];
    id val = prefs[key];
    return val ?: defaultValue;
}

static BOOL heaven_prefs_bool(NSString *key, BOOL defaultValue) {
    id value = heaven_prefs_read(key, @(defaultValue));
    return value ? [value boolValue] : defaultValue;
}

// ============================================================================
// 设备信息模型
// ============================================================================
@interface HeavenDeviceProfile : NSObject
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy) NSString *machineModel;
@property (nonatomic, copy) NSString *systemVersion;
@property (nonatomic, copy) NSString *idfa;
@property (nonatomic, copy) NSString *idfv;
@property (nonatomic, copy) NSString *wifiBSSID;
@property (nonatomic, copy) NSString *wifiSSID;
@property (nonatomic, copy) NSString *carrierName;
@property (nonatomic, copy) NSString *locationLat;
@property (nonatomic, copy) NSString *locationLng;
@property (nonatomic, copy) NSString *deviceToken;
@property (nonatomic, copy) NSString *macAddress;
@property (nonatomic, copy) NSString *internalIP;
@property (nonatomic, copy) NSString *userAgent;
@property (nonatomic, copy) NSString *serialNumber;
@property (nonatomic, copy) NSString *imei;
@property (nonatomic, copy) NSString *meid;
@property (nonatomic, copy) NSString *udid;
@property (nonatomic, copy) NSString *ecid;
@property (nonatomic, copy) NSString *bluetoothAddress;
@property (nonatomic, copy) NSString *buildVersion;
@property (nonatomic, copy) NSString *cpuArchitecture;
@property (nonatomic, strong) NSNumber *batteryHealth;
@property (nonatomic, strong) NSNumber *brightness;
@property (nonatomic, strong) NSNumber *bootTimeOffset;
@property (nonatomic, strong) NSNumber *cpuFreqMHz;
@property (nonatomic, strong) NSNumber *screenWidth;
@property (nonatomic, strong) NSNumber *screenHeight;
@property (nonatomic, copy) NSString *hardwareID;
@property (nonatomic, copy) NSString *diskMemoryInfo;
@property (nonatomic, copy) NSString *batteryVolumeInfo;
@end

@implementation HeavenDeviceProfile
@end

// ============================================================================
// 核心管理器 — HeavenManager
// [RE] 推测: 插件的核心单例，管理所有欺骗/清理/网络逻辑
// ============================================================================
@interface HeavenManager : NSObject

@property (nonatomic, strong) HeavenDeviceProfile *spoofedProfile;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, assign, getter=isSpoofingEnabled) BOOL spoofingEnabled;

+ (instancetype)sharedInstance;

- (void)loadSettings;
- (HeavenDeviceProfile *)currentSpoofProfile;

// 网络上报
- (void)reportDeviceInfo;

// 数据清理
- (void)cleanKeychain;
- (void)cleanCookies;
- (void)cleanWebKitData;
- (void)cleanPasteboard;
- (void)cleanCaches;
- (void)cleanAppDataForBundleID:(NSString *)bundleID;
- (void)cleanAppleIDKeychain;
- (void)cleanAppStoreKeychain;

// 反检测
- (BOOL)isJailbroken;
- (void)applyAntiDebug;

// 生成签名请求
- (NSDictionary *)signedRequestParams;
- (NSString *)generateSignatureWithTimestamp:(NSString *)timestamp nonce:(NSString *)nonce params:(NSDictionary *)params;

@end

// ============================================================================
// 全局状态
// ============================================================================
static HeavenManager *s_sharedManager = nil;
static NSString *s_targetBundleID = nil;

// ============================================================================
// 白名单目标
// [RE] 推测: 插件只对特定进程注入
// ============================================================================
static NSSet *heaven_target_bundles(void) {
    return [NSSet setWithObjects:
        @"com.apple.springboard",
        @"com.apple.WebKit.WebContent",
        @"com.apple.mobilesafari",
        @"com.apple.managedconfiguration.profiled",    // [RE] 推测: networkd
        @"com.apple.nsurlsessiond",
        @"com.apple.CFNetwork",
        @"com.apple.accountsd",
        @"com.apple.authkit",
        nil
    ];
}

// ============================================================================
// HeavenManager 实现
// ============================================================================
@implementation HeavenManager

+ (instancetype)sharedInstance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_sharedManager = [[self alloc] init];
    });
    return s_sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _spoofedProfile = [[HeavenDeviceProfile alloc] init];
        _enabled = YES;
        [self loadSettings];
    }
    return self;
}

- (void)loadSettings {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kHeavenPrefsPath] ?: @{};

    self.enabled = heaven_prefs_bool(@"enabled", YES);
    self.spoofingEnabled = heaven_prefs_bool(@"spoofingEnabled", NO);

    // 读取欺骗配置
    self.spoofedProfile.deviceName      = prefs[@"spoofedDeviceName"];
    self.spoofedProfile.machineModel    = prefs[@"spoofedModel"];
    self.spoofedProfile.systemVersion   = prefs[@"spoofedSystemVersion"];
    self.spoofedProfile.idfa            = prefs[@"spoofedIDFA"];
    self.spoofedProfile.idfv            = prefs[@"spoofedIDFV"];
    self.spoofedProfile.wifiBSSID       = prefs[@"spoofedBSSID"];
    self.spoofedProfile.wifiSSID        = prefs[@"spoofedSSID"];
    self.spoofedProfile.carrierName     = prefs[@"spoofedCarrier"];
    self.spoofedProfile.locationLat     = prefs[@"spoofedLatitude"];
    self.spoofedProfile.locationLng     = prefs[@"spoofedLongitude"];
    self.spoofedProfile.macAddress      = prefs[@"spoofedMAC"];
    self.spoofedProfile.internalIP      = prefs[@"spoofedInternalIP"];
    self.spoofedProfile.serialNumber    = prefs[@"spoofedSerial"];
    self.spoofedProfile.imei            = prefs[@"spoofedIMEI"];
    self.spoofedProfile.meid            = prefs[@"spoofedMEID"];
    self.spoofedProfile.udid            = prefs[@"spoofedUDID"];
    self.spoofedProfile.ecid            = prefs[@"spoofedECID"];
    self.spoofedProfile.bluetoothAddress = prefs[@"spoofedBTAddress"];
    self.spoofedProfile.buildVersion    = prefs[@"spoofedBuild"];
    self.spoofedProfile.cpuArchitecture = prefs[@"spoofedCPUArch"];
    self.spoofedProfile.userAgent       = prefs[@"spoofedUA"];

    // 数值类型
    if (prefs[@"spoofedBrightness"])    self.spoofedProfile.brightness = prefs[@"spoofedBrightness"];
    if (prefs[@"spoofedBatteryHealth"]) self.spoofedProfile.batteryHealth = prefs[@"spoofedBatteryHealth"];
    if (prefs[@"spoofedCPUFreq"])       self.spoofedProfile.cpuFreqMHz = prefs[@"spoofedCPUFreq"];
    if (prefs[@"spoofedScreenWidth"])   self.spoofedProfile.screenWidth = prefs[@"spoofedScreenWidth"];
    if (prefs[@"spoofedScreenHeight"])  self.spoofedProfile.screenHeight = prefs[@"spoofedScreenHeight"];
    if (prefs[@"spoofedBootTime"])      self.spoofedProfile.bootTimeOffset = prefs[@"spoofedBootTime"];

}

- (HeavenDeviceProfile *)currentSpoofProfile {
    return self.spoofedProfile;
}

// ============================================================================
// 签名生成
// [RE] 推测: X-Heaven-Signature = HMAC-SHA256(timestamp + nonce + json_body, key1)
// ============================================================================
- (NSString *)generateSignatureWithTimestamp:(NSString *)timestamp
                                      nonce:(NSString *)nonce
                                     params:(NSDictionary *)params
{
    NSString *jsonBody = heaven_json_stringify(params);
    NSString *data = [NSString stringWithFormat:@"%@%@%@", timestamp, nonce, jsonBody];
    return heaven_hmac_sha256(data, kHeavenHMACKey1);
}

- (NSDictionary *)signedRequestParams {
    // [RE] 推测: 收集设备信息用于上报
    UIDevice *device = [UIDevice currentDevice];
    NSString *timestamp = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    NSString *nonce = heaven_generate_nonce();

    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"deviceName"] = device.name ?: @"";
    params[@"model"] = [self deviceModelString];
    params[@"systemVersion"] = device.systemVersion ?: @"";
    params[@"idfv"] = [[device identifierForVendor] UUIDString] ?: @"";
    params[@"bundleID"] = s_targetBundleID ?: @"";
    params[@"timestamp"] = timestamp;
    params[@"nonce"] = nonce;

    NSString *signature = [self generateSignatureWithTimestamp:timestamp nonce:nonce params:params];
    params[@"signature"] = signature;

    return [params copy];
}

// ============================================================================
// 获取设备型号字符串
// ============================================================================
- (NSString *)deviceModelString {
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *machine = (char *)malloc(size);
    if (machine) {
        sysctlbyname("hw.machine", machine, &size, NULL, 0);
        NSString *model = [NSString stringWithCString:machine encoding:NSUTF8StringEncoding];
        free(machine);
        return model;
    }
    return @"iPhone14,2"; // fallback
}

// ============================================================================
// 设备信息上报
// ============================================================================
- (void)reportDeviceInfo {
    NSString *urlStr = [NSString stringWithFormat:@"%@%@", kHeavenServerBase, kHeavenAPIReport];
    NSURL *url = [NSURL URLWithString:urlStr];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *params = [self signedRequestParams];
    NSString *signature = params[@"signature"];
    NSString *timestamp = params[@"timestamp"];
    NSString *nonce = params[@"nonce"];

    [request setValue:timestamp forHTTPHeaderField:@"X-Heaven-Timestamp"];
    [request setValue:nonce forHTTPHeaderField:@"X-Heaven-Nonce"];
    [request setValue:signature forHTTPHeaderField:@"X-Heaven-Signature"];

    NSError *jsonError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:params options:0 error:&jsonError];

    if (jsonError) return;

    // 异步上报
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"%@ Device info report failed: %@", kLogTag, error.localizedDescription);
        }
    }];
    [task resume];

    NSLog(@"%@ Device info report scheduled", kLogTag);
}

// ============================================================================
// 反越狱检测
// [RE] 推测: 检查常见越狱文件和进程
// ============================================================================
- (BOOL)isJailbroken {
    // 检查越狱文件
    NSArray *jailbreakPaths = @[
        @"/Applications/Cydia.app",
        @"/Applications/Sileo.app",
        @"/Applications/Zebra.app",
        @"/Applications/Dopamine.app",
        @"/Applications/TrollStore.app",
        @"/usr/lib/libhooker.dylib",
        @"/usr/lib/substrate.dylib",
        @"/usr/lib/libsubstrate.dylib",
        @"/etc/apt",
        @"/var/jb",
        @"/private/preboot/jb",
        @"/usr/sbin/frida-server",
        @"/usr/bin/frida",
        @"/usr/bin/cycript",
        @"/usr/bin/debugserver",
        @"/usr/bin/ssh",
        @"/bin/bash",
        @"/bin/sh",
        @"/private/var/lib/apt",
    ];

    for (NSString *path in jailbreakPaths) {
        struct stat st;
        if (stat([path UTF8String], &st) == 0) {
            NSLog(@"%@ AntiJailbreak: detected jailbreak file at %@", kLogTag, path);
            return YES;
        }
    }

    // [RE] 推测: 原始实现可能还通过 sysctl(KERN_PROC) 枚举进程。
    // 当前重构保留文件检测，避免引入不完整的进程枚举逻辑。
    return NO;
}

// ============================================================================
// 反调试
// [RE] 推测: ptrace(PT_DENY_ATTACH, 0, 0, 0) / ptrace(31, 0, 0, 0)
// ============================================================================
- (void)applyAntiDebug {
    // PT_DENY_ATTACH = 31
    ptrace(PT_DENY_ATTACH, 0, NULL, 0);

    // 清理环境变量防止被注入检测
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("DYLD_FORCE_FLAT_NAMESPACE");
    unsetenv("DYLD_PRINT_TO_FILE");
    unsetenv("DYLD_SHARED_REGION");
    unsetenv("DYLD_LIBRARY_PATH");
    unsetenv("DYLD_FRAMEWORK_PATH");

    NSLog(@"%@ AntiDebug: ptrace(PT_DENY_ATTACH) applied, env vars cleaned", kLogTag);
}

// ============================================================================
// 清理 Keychain
// [RE] 推测: 遍历所有 keychain 项并删除
// ============================================================================
- (void)cleanKeychain {
    // 匹配所有 keychain 项
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnRef: @YES,
    };

    CFArrayRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);

    if (status == errSecSuccess && result) {
        NSArray *items = (__bridge_transfer NSArray *)result;
        for (NSDictionary *item in items) {
            NSMutableDictionary *deleteQuery = [NSMutableDictionary dictionary];
            deleteQuery[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;

            if (item[(__bridge id)kSecAttrAccount])
                deleteQuery[(__bridge id)kSecAttrAccount] = item[(__bridge id)kSecAttrAccount];
            if (item[(__bridge id)kSecAttrService])
                deleteQuery[(__bridge id)kSecAttrService] = item[(__bridge id)kSecAttrService];
            if (item[(__bridge id)kSecAttrGeneric])
                deleteQuery[(__bridge id)kSecAttrGeneric] = item[(__bridge id)kSecAttrGeneric];

            SecItemDelete((__bridge CFDictionaryRef)deleteQuery);
        }
    }

    // 清理 Internet 密码
    NSDictionary *internetQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
    };
    SecItemDelete((__bridge CFDictionaryRef)internetQuery);

    // 清理证书和密钥
    SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassCertificate});
    SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassKey});
    SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassIdentity});

    NSLog(@"%@ Keychain cleared", kLogTag);
}

// ============================================================================
// 清理 Apple ID 相关 Keychain
// [RE] 推测: 按 service 名称筛选
// ============================================================================
- (void)cleanAppleIDKeychain {
    NSArray *appleServices = @[
        @"appleid",
        @"icloud",
        @"accountsd",
        @"authkit",
        @"com.apple.account.AppleAccount",
        @"com.apple.account.iCloud",
        @"com.apple.account.iTunesStore",
    ];

    for (NSString *service in appleServices) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        };
        SecItemDelete((__bridge CFDictionaryRef)query);

        NSLog(@"%@ Keychain cleared for service: %@", kLogTag, service);
    }
}

// ============================================================================
// 清理 App Store 相关 Keychain
// ============================================================================
- (void)cleanAppStoreKeychain {
    NSArray *storeServices = @[
        @"com.apple.appstore",
        @"com.apple.storekit",
        @"com.apple.itunesstored",
        @"com.apple.store.JSStore",
    ];

    for (NSString *service in storeServices) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: service,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        };
        SecItemDelete((__bridge CFDictionaryRef)query);
    }

    NSLog(@"%@ AppStore keychain cleared", kLogTag);
}

// ============================================================================
// 清理 Cookies
// ============================================================================
- (void)cleanCookies {
    // NSHTTPCookieStorage
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [cookieStorage.cookies copy];
    for (NSHTTPCookie *cookie in cookies) {
        [cookieStorage deleteCookie:cookie];
    }

    // WKWebsiteDataStore (WebKit)
    Class wkDataStoreClass = NSClassFromString(@"WKWebsiteDataStore");
    if (wkDataStoreClass) {
        SEL defaultSel = NSSelectorFromString(@"defaultDataStore");
        IMP defaultImp = [wkDataStoreClass methodForSelector:defaultSel];
        if (defaultImp) {
            id defaultStore = ((id (*)(id, SEL))defaultImp)(wkDataStoreClass, defaultSel);
            SEL fetchSel = NSSelectorFromString(@"fetchDataRecordsOfTypes:completionHandler:");
            SEL removeSel = NSSelectorFromString(@"removeDataOfTypes:forDataRecords:completionHandler:");

            if ([defaultStore respondsToSelector:fetchSel]) {
                void (^fetchHandler)(NSArray *) = ^(NSArray *records) {
                    if ([defaultStore respondsToSelector:removeSel]) {
                        NSSet *types = [NSSet setWithObjects:
                            @"WKWebsiteDataTypeCookies",
                            @"WKWebsiteDataTypeLocalStorage",
                            @"WKWebsiteDataTypeSessionStorage",
                            @"WKWebsiteDataTypeWebSQLDatabases",
                            @"WKWebsiteDataTypeIndexedDBDatabases",
                            nil
                        ];
                        ((void (*)(id, SEL, id, id, id))[defaultStore methodForSelector:removeSel])
                            (defaultStore, removeSel, types, records, ^{});
                    }
                };
                ((void (*)(id, SEL, id, id))[defaultStore methodForSelector:fetchSel])
                    (defaultStore, fetchSel, [NSSet setWithObject:@"WKWebsiteDataTypeCookies"], fetchHandler);
            }
        }
    }

    NSLog(@"%@ Cookies cleared", kLogTag);
}

// ============================================================================
// 清理 WebKit 数据
// ============================================================================
- (void)cleanWebKitData {
    // [RE] 推测: 使用 WKWebsiteDataStore 清理所有网站数据
    Class wkDataStoreClass = NSClassFromString(@"WKWebsiteDataStore");
    if (wkDataStoreClass) {
        SEL defaultSel = NSSelectorFromString(@"defaultDataStore");
        IMP defaultImp = [wkDataStoreClass methodForSelector:defaultSel];
        if (defaultImp) {
            id defaultStore = ((id (*)(id, SEL))defaultImp)(wkDataStoreClass, defaultSel);

            SEL removeAllSel = NSSelectorFromString(@"removeDataOfTypes:modifiedSince:completionHandler:");
            if ([defaultStore respondsToSelector:removeAllSel]) {
                NSSet *allTypes = [NSSet setWithObjects:
                    @"WKWebsiteDataTypeDiskCache",
                    @"WKWebsiteDataTypeMemoryCache",
                    @"WKWebsiteDataTypeCookies",
                    @"WKWebsiteDataTypeLocalStorage",
                    @"WKWebsiteDataTypeSessionStorage",
                    @"WKWebsiteDataTypeWebSQLDatabases",
                    @"WKWebsiteDataTypeIndexedDBDatabases",
                    @"WKWebsiteDataTypeOfflineWebApplicationCache",
                    nil
                ];
                ((void (*)(id, SEL, id, NSDate *, id))[defaultStore methodForSelector:removeAllSel])
                    (defaultStore, removeAllSel, allTypes, [NSDate distantPast], ^{});
            }
        }
    }

    // 清理 WKProcessPool
    Class wkProcessPoolClass = NSClassFromString(@"WKProcessPool");
    if (wkProcessPoolClass) {
        __unused id processPool = [[wkProcessPoolClass alloc] init]; // 创建新 pool 刷新旧连接
    }

    NSLog(@"%@ WebKit data cleared", kLogTag);
}

// ============================================================================
// 清理剪贴板
// ============================================================================
- (void)cleanPasteboard {
    [UIPasteboard generalPasteboard].items = @[];
    [UIPasteboard generalPasteboard].string = @"";

    // [RE] 推测: 也清理 UIPasteboard 的 name 变体
    Class pbClass = NSClassFromString(@"UIPasteboard");
    if (pbClass) {
        SEL removeSel = NSSelectorFromString(@"removePasteboardWithName:");
        if ([pbClass respondsToSelector:removeSel]) {
            ((void (*)(id, SEL, NSString *))[pbClass methodForSelector:removeSel])
                (pbClass, removeSel, UIPasteboardNameGeneral);
        }
    }

    NSLog(@"%@ Pasteboard cleared", kLogTag);
}

// ============================================================================
// 清理缓存
// ============================================================================
- (void)cleanCaches {
    // [RE] 推测: 清理 Library/Caches 下各子目录
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cachesDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];

    NSArray *cacheSubdirs = @[
        @"com.apple.WebKit",
        @"Snapshots",
        @"com.apple.nsurlsessiond",
        @"com.apple.mobilesafari",
    ];

    for (NSString *subdir in cacheSubdirs) {
        NSString *path = [cachesDir stringByAppendingPathComponent:subdir];
        if ([fm fileExistsAtPath:path]) {
            NSError *error = nil;
            [fm removeItemAtPath:path error:&error];
            NSLog(@"%@ Cache cleared: %@ (error: %@)", kLogTag, subdir, error ? [error localizedDescription] : @"none");
        }
    }

    // 清理完整 caches 目录 (除关键文件外)
    NSArray *contents = [fm contentsOfDirectoryAtPath:cachesDir error:nil];
    for (NSString *item in contents) {
        // [RE] 推测: 跳过某些必要文件
        if ([item hasPrefix:@"."]) continue;
        NSString *fullPath = [cachesDir stringByAppendingPathComponent:item];
        [fm removeItemAtPath:fullPath error:nil];
    }

    // 清理 NSURLCache
    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSLog(@"%@ All caches cleared", kLogTag);
}

// ============================================================================
// 清理指定 App 的数据
// ============================================================================
- (void)cleanAppDataForBundleID:(NSString *)bundleID {
    // [RE] 推测: 获取 app 的 container 路径并清理
    // 在 rootless 环境下通过 LSApplicationProxy 获取
    Class lsProxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!lsProxyClass) return;

    SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![lsProxyClass respondsToSelector:proxySel]) return;

    id appProxy = ((id (*)(id, SEL, NSString *))[lsProxyClass methodForSelector:proxySel])
        (lsProxyClass, proxySel, bundleID);

    if (!appProxy) return;

    // [RE] 推测: 获取 dataContainerURL
    SEL dataURLSel = NSSelectorFromString(@"dataContainerURL");
    if ([appProxy respondsToSelector:dataURLSel]) {
        NSURL *dataURL = ((NSURL * (*)(id, SEL))[appProxy methodForSelector:dataURLSel])
            (appProxy, dataURLSel);

        if (dataURL) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *dataPath = [dataURL path];

            // 清理 Documents
            NSString *docsPath = [dataPath stringByAppendingPathComponent:@"Documents"];
            if ([fm fileExistsAtPath:docsPath]) {
                [fm removeItemAtPath:docsPath error:nil];
                [fm createDirectoryAtPath:docsPath withIntermediateDirectories:YES attributes:nil error:nil];
            }

            // 清理 Library/Caches
            NSString *cachesPath = [dataPath stringByAppendingPathComponent:@"Library/Caches"];
            if ([fm fileExistsAtPath:cachesPath]) {
                [fm removeItemAtPath:cachesPath error:nil];
                [fm createDirectoryAtPath:cachesPath withIntermediateDirectories:YES attributes:nil error:nil];
            }

            // 清理 tmp
            NSString *tmpPath = [dataPath stringByAppendingPathComponent:@"tmp"];
            if ([fm fileExistsAtPath:tmpPath]) {
                [fm removeItemAtPath:tmpPath error:nil];
                [fm createDirectoryAtPath:tmpPath withIntermediateDirectories:YES attributes:nil error:nil];
            }

            NSLog(@"%@ App data cleaned for bundle: %@", kLogTag, bundleID);
        }
    }
}

@end

// ============================================================================
// 全局目标应用识别
// ============================================================================
static BOOL heaven_is_target_app(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID) return NO;

    s_targetBundleID = [bundleID copy];

    if ([heaven_target_bundles() containsObject:bundleID]) {
        NSLog(@"%@ Injecting into target app: %@", kLogTag, bundleID);
        return YES;
    }

    // [RE] 推测: 也检查进程名
    NSString *processName = [[NSProcessInfo processInfo] processName];
    if ([processName isEqualToString:@"SpringBoard"] ||
        [processName isEqualToString:@"MobileSafari"] ||
        [processName isEqualToString:@"nsurlsessiond"])
    {
        NSLog(@"%@ Injecting via process name: %@", kLogTag, processName);
        return YES;
    }

    return NO;
}

// ============================================================================
// 构造函数 — 注入入口
// ============================================================================
%ctor {
    // 只对白名单应用执行
    if (!heaven_is_target_app()) return;

    @autoreleasepool {
        NSLog(@"%@ Heaven loaded into %@", kLogTag, [[NSBundle mainBundle] bundleIdentifier]);

        // 初始化管理器
        HeavenManager *mgr = [HeavenManager sharedInstance];

        // 应用反调试
        if (heaven_prefs_bool(@"enableAntiDebug", YES)) {
            [mgr applyAntiDebug];
        }

        // 检查越狱状态并上报
        BOOL jailbroken = [mgr isJailbroken];
        NSLog(@"%@ Jailbreak detection: %d", kLogTag, jailbroken);

        // 设备信息上报 (异步)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            [mgr reportDeviceInfo];
        });

        NSLog(@"%@ Heaven initialization complete", kLogTag);
    }
}

// ============================================================================
// Hook: UIDevice — 设备属性欺骗
// ============================================================================
%hook UIDevice

- (NSString *)name {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.deviceName) {
        return mgr.spoofedProfile.deviceName;
    }
    return %orig;
}

- (NSString *)model {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.machineModel) {
        // [RE] 推测: 从 model map 获取对应的显示名称
        NSDictionary *modelInfo = getDeviceModelMap()[mgr.spoofedProfile.machineModel];
        if (modelInfo[@"name"]) return modelInfo[@"name"];
        return mgr.spoofedProfile.machineModel;
    }
    return %orig;
}

- (NSString *)systemVersion {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.systemVersion) {
        return mgr.spoofedProfile.systemVersion;
    }
    return %orig;
}

- (NSUUID *)identifierForVendor {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.idfv) {
        return [[NSUUID alloc] initWithUUIDString:mgr.spoofedProfile.idfv];
    }
    return %orig;
}

%end

// ============================================================================
// Hook: UIScreen — 亮度欺骗
// ============================================================================
%hook UIScreen

- (CGFloat)brightness {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.brightness) {
        return [mgr.spoofedProfile.brightness floatValue];
    }
    return %orig;
}

%end

// ============================================================================
// Hook: ASIdentifierManager — IDFA 欺骗
// ============================================================================
%hook ASIdentifierManager

- (NSUUID *)advertisingIdentifier {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.idfa) {
        return [[NSUUID alloc] initWithUUIDString:mgr.spoofedProfile.idfa];
    }
    return %orig;
}

%end

// ============================================================================
// Hook: CTTelephonyNetworkInfo — 运营商欺骗
// ============================================================================
%hook CTTelephonyNetworkInfo

- (CTCarrier *)subscriberCellularProvider {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.carrierName) {
        // [RE] 推测: 创建一个伪造的 CTCarrier 对象
        CTCarrier *fakeCarrier = [[CTCarrier alloc] init];
        if (fakeCarrier) {
            // [RE] 推测: 使用 KVC 设置只读属性
            [fakeCarrier setValue:mgr.spoofedProfile.carrierName forKey:@"carrierName"];
            [fakeCarrier setValue:@"Heaven" forKey:@"mobileCountryCode"];
            [fakeCarrier setValue:@"00" forKey:@"mobileNetworkCode"];
            [fakeCarrier setValue:@"Heaven" forKey:@"isoCountryCode"];
            [fakeCarrier setValue:@YES forKey:@"allowsVOIP"];
        }
        return fakeCarrier;
    }
    return %orig;
}

// [RE] 推测: 对 iOS 16+ 的多个运营商 API 同样 hook
%new
- (CTCarrier *)serviceSubscriberCellularProviderForIdentifier:(NSString *)identifier {
    // [RE] 推测: iOS 16 改用此方法
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.carrierName) {
        CTCarrier *fakeCarrier = [[CTCarrier alloc] init];
        if (fakeCarrier) {
            [fakeCarrier setValue:mgr.spoofedProfile.carrierName forKey:@"carrierName"];
            [fakeCarrier setValue:@"Heaven" forKey:@"mobileCountryCode"];
            [fakeCarrier setValue:@"00" forKey:@"mobileNetworkCode"];
            [fakeCarrier setValue:@"Heaven" forKey:@"isoCountryCode"];
            [fakeCarrier setValue:@YES forKey:@"allowsVOIP"];
        }
        return fakeCarrier;
    }
    // [RE] 推测: 调用原始实现
    return nil;
}

%end

// ============================================================================
// Hook: CLLocationManager — 定位欺骗
// ============================================================================
%hook CLLocationManager

// [RE] 推测: Hook 位置更新回调中的坐标
%new
- (void)heaven_overrideLocation {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (!mgr.isEnabled || !mgr.isSpoofingEnabled) return;
    if (!mgr.spoofedProfile.locationLat || !mgr.spoofedProfile.locationLng) return;

    // [RE] 推测: 使用 KVO / swizzle 在 location 更新时替换坐标
    // 具体实现可能使用 method_setImplementation 动态替换 delegate 方法
    CLLocationCoordinate2D fakeCoord = CLLocationCoordinate2DMake(
        [mgr.spoofedProfile.locationLat doubleValue],
        [mgr.spoofedProfile.locationLng doubleValue]
    );

    CLLocation *fakeLocation = [[CLLocation alloc] initWithCoordinate:fakeCoord
                                                             altitude:0.0
                                                   horizontalAccuracy:10.0
                                                     verticalAccuracy:10.0
                                                            timestamp:[NSDate date]];
    if (fakeLocation) {
        // [RE] 推测: 通过 KVO 或公告发送虚假位置
        [[NSNotificationCenter defaultCenter] postNotificationName:@"HeavenFakeLocation"
                                                            object:fakeLocation];
    }
}

%end

// ============================================================================
// C 函数 Hook: sysctlbyname / getifaddrs / fork
// ============================================================================
// [RE] 这些低层 C hook 在反编译代码中只有伪实现，未在当前重构版中注册。
// 保留 Objective-C / Logos 层 hook，避免不完整的底层替换影响系统稳定性。

// ============================================================================
// Hook: NSProcessInfo — 进程信息欺骗
// ============================================================================
%hook NSProcessInfo

- (NSString *)hostName {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.deviceName) {
        return mgr.spoofedProfile.deviceName;
    }
    return %orig;
}

- (NSString *)operatingSystemVersionString {
    HeavenManager *mgr = [HeavenManager sharedInstance];
    if (mgr.isEnabled && mgr.isSpoofingEnabled && mgr.spoofedProfile.systemVersion) {
        return [NSString stringWithFormat:@"iOS %@", mgr.spoofedProfile.systemVersion];
    }
    return %orig;
}

%end

// ============================================================================
// Hook: WKWebsiteDataStore — 清理 WebKit 数据
// [RE] 推测: 通过 Method Swizzle 在清理触发时介入
// ============================================================================

// 使用 Logos 的 %class 和 %hook 保持统一风格

// ============================================================================
// CLLocationManagerDelegate Swizzle (动态)
// [RE] 推测: 在运行时动态替换 CLLocationManagerDelegate 的方法
// 具体替换在 HeavenManager 初始化时进行
// ============================================================================
static void heaven_swizzle_location_delegate(Class delegateClass) {
    SEL didUpdateSel = @selector(locationManager:didUpdateLocations:);
    SEL didChangeAuthSel = @selector(locationManager:didChangeAuthorizationStatus:);
    // [RE] 推测: 获取原始实现
    Method origUpdate = class_getInstanceMethod(delegateClass, didUpdateSel);
    if (origUpdate) {
        IMP origImp = method_getImplementation(origUpdate);
        IMP newImp = imp_implementationWithBlock(^(id self, CLLocationManager *manager, NSArray *locations) {
            HeavenManager *mgr = [HeavenManager sharedInstance];
            if (mgr.isEnabled && mgr.isSpoofingEnabled &&
                mgr.spoofedProfile.locationLat && mgr.spoofedProfile.locationLng) {

                // 替换位置信息
                CLLocationCoordinate2D fakeCoord = CLLocationCoordinate2DMake(
                    [mgr.spoofedProfile.locationLat doubleValue],
                    [mgr.spoofedProfile.locationLng doubleValue]
                );
                CLLocation *fakeLocation = [[CLLocation alloc] initWithCoordinate:fakeCoord
                                                                         altitude:0.0
                                                               horizontalAccuracy:10.0
                                                                 verticalAccuracy:10.0
                                                                        timestamp:[NSDate date]];
                locations = @[fakeLocation];
            }

            // 调用原始实现
            ((void (*)(id, SEL, id, id))origImp)(self, didUpdateSel, manager, locations);
        });

        method_setImplementation(origUpdate, newImp);
    }

    Method origAuth = class_getInstanceMethod(delegateClass, didChangeAuthSel);
    if (origAuth) {
        IMP origAuthImp = method_getImplementation(origAuth);
        IMP newAuthImp = imp_implementationWithBlock(^(id self, CLLocationManager *manager, CLAuthorizationStatus status) {
            // [RE] 推测: 总是返回 kCLAuthorizationStatusAuthorizedAlways
            ((void (*)(id, SEL, id, CLAuthorizationStatus))origAuthImp)
                (self, didChangeAuthSel, manager, kCLAuthorizationStatusAuthorizedAlways);
        });
        method_setImplementation(origAuth, newAuthImp);
    }
}

// ============================================================================
// MSHookMessageEx 包装: CLLocationManager setDelegate:
// [RE] 推测: 当设置 delegate 时自动 swizzle 其 delegate 方法
// ============================================================================
static void (*orig_setDelegate)(CLLocationManager *, SEL, id<CLLocationManagerDelegate>) = NULL;

static void new_setDelegate(CLLocationManager *self, SEL _cmd, id<CLLocationManagerDelegate> delegate) {
    if (delegate) {
        // [RE] 推测: 自动 swizzle delegate 的定位方法
        heaven_swizzle_location_delegate(object_getClass(delegate));
    }

    if (orig_setDelegate) {
        orig_setDelegate(self, _cmd, delegate);
    }
}

// ============================================================================
// 额外初始化 (通过 MSHookMessageEx)
// ============================================================================
// 注意: MSHookMessageEx 不能在 %ctor 块中用 Logos 语法直接声明
// 需要在运行时手动调用，这里在 %ctor 末尾补充

// 使用 C 函数在构造末尾注册
__attribute__((constructor)) static void heaven_extra_init() {
    if (!heaven_is_target_app()) return;

    // Hook CLLocationManager.setDelegate:
    Class clLocationMgr = [CLLocationManager class];
    if (clLocationMgr) {
        MSHookMessageEx(
            clLocationMgr,
            @selector(setDelegate:),
            (IMP)new_setDelegate,
            (IMP *)&orig_setDelegate
        );
    }
}
