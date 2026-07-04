#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <AdSupport/ASIdentifierManager.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/socket.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <ifaddrs.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <spawn.h>

#import <rootless.h>
#import <substrate.h>

#pragma mark - Constants & Keys

static NSString *heavenPrefsPath(void) {
    return ROOT_PATH_NS(@"/var/mobile/Library/Preferences/vip.abc3.heaven.plist");
}

static NSString *const kNotifyPrefsChanged = @"vip.abc3.heaven/prefsChanged";
static NSString *const kNotifyRegenerate = @"vip.abc3.heaven/regenerate";

#pragma mark - Device Profile Structure

@interface HVDeviceProfile : NSObject
@property (nonatomic, strong) NSString *deviceName;
@property (nonatomic, strong) NSString *machineModel;
@property (nonatomic, strong) NSString *systemVersion;
@property (nonatomic, strong) NSString *buildVersion;
@property (nonatomic, strong) NSString *serialNumber;
@property (nonatomic, strong) NSString *cpuMode;
@property (nonatomic, strong) NSString *gpuModel;
@property (nonatomic, strong) NSString *processorCount;
@property (nonatomic, strong) NSString *memorySize;
@property (nonatomic, strong) NSString *diskSize;
@property (nonatomic, strong) NSString *batteryCapacity;
@property (nonatomic, strong) NSString *batteryHealth;
@property (nonatomic, strong) NSString *idfa;
@property (nonatomic, strong) NSString *idfv;
@property (nonatomic, strong) NSString *internalIP;
@property (nonatomic, strong) NSString *macAddress;
@property (nonatomic, strong) NSString *carrierName;
@property (nonatomic, strong) NSString *networkType;
@property (nonatomic, strong) NSString *wifiSSID;
@property (nonatomic, strong) NSString *wifiBSSID;
@property (nonatomic, strong) NSString *cellularAddress;
@property (nonatomic, strong) NSString *deviceIdentifier;
@property (nonatomic, strong) NSString *cpuArchitecture;
@property (nonatomic, strong) NSString *bluetoothAddress;
@property (nonatomic, strong) NSString *wifiSerial;
@property (nonatomic, strong) NSString *locationName;
@property (nonatomic, strong) NSString *latitude;
@property (nonatomic, strong) NSString *longitude;
@property (nonatomic, strong) NSString *userAgent;
@property (nonatomic, strong) NSString *imei;
@property (nonatomic, strong) NSString *meid;
@property (nonatomic, strong) NSString *udid;
@property (nonatomic, strong) NSString *ecid;
@property (nonatomic, strong) NSNumber *enabled;
@property (nonatomic, strong) NSNumber *antiJailbreak;
@property (nonatomic, strong) NSString *targetBundleID;
@end

@implementation HVDeviceProfile
@end

#pragma mark - Forward Declarations

static HVDeviceProfile *currentProfile = nil;
static BOOL isEnabled = NO;
static BOOL antiJailbreakEnabled = NO;
static NSString *targetBundleID = nil;

// Original function pointers
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_getifaddrs)(struct ifaddrs **);
static pid_t (*orig_fork)(void);

// Original ObjC IMPs
static NSString *(*orig_UIDevice_name)(id, SEL);
static NSString *(*orig_UIDevice_model)(id, SEL);
static NSString *(*orig_UIDevice_localizedModel)(id, SEL);
static NSString *(*orig_UIDevice_systemVersion)(id, SEL);
static NSString *(*orig_UIDevice_systemName)(id, SEL);
static NSUUID *(*orig_UIDevice_identifierForVendor)(id, SEL);
static float (*orig_UIDevice_batteryLevel)(id, SEL);
static NSInteger (*orig_UIDevice_batteryState)(id, SEL);
static NSString *(*orig_NSProcessInfo_operatingSystemVersionString)(id, SEL);
static NSOperatingSystemVersion (*orig_NSProcessInfo_operatingSystemVersion)(id, SEL);
static NSUInteger (*orig_NSProcessInfo_processorCount)(id, SEL);
static NSUInteger (*orig_NSProcessInfo_activeProcessorCount)(id, SEL);
static NSString *(*orig_NSProcessInfo_hostName)(id, SEL);

static CGFloat (*orig_UIScreen_brightness)(id, SEL);
static CGFloat (*orig_UIScreen_scale)(id, SEL);

#pragma mark - Device Info Generation

static NSString *randomHexString(NSUInteger length) {
    NSMutableString *result = [NSMutableString stringWithCapacity:length];
    for (NSUInteger i = 0; i < length; i++) {
        [result appendFormat:@"%02x", arc4random_uniform(256)];
    }
    return result;
}

static NSString *randomMACAddress(void) {
    uint8_t bytes[6];
    arc4random_buf(bytes, 6);
    // Set local administered bit
    bytes[0] |= 0x02;
    bytes[0] &= 0xFE;
    return [NSString stringWithFormat:@"%02x:%02x:%02x:%02x:%02x:%02x",
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]];
}

static NSString *randomUUIDString(void) {
    NSUUID *uuid = [NSUUID UUID];
    return [uuid UUIDString];
}

static NSString *randomSerialNumber(void) {
    static const char chars[] = "ABCDEFGHIJKLMNPQRSTUVWXYZ0123456789";
    NSMutableString *serial = [NSMutableString string];
    // Format: XX1234ABCD (like real Apple serial)
    for (int i = 0; i < 10; i++) {
        [serial appendFormat:@"%c", chars[arc4random_uniform((uint32_t)(sizeof(chars) - 1))]];
    }
    return serial;
}

static NSString *randomIMEI(void) {
    NSMutableString *imei = [NSMutableString string];
    for (int i = 0; i < 15; i++) {
        [imei appendFormat:@"%d", arc4random_uniform(10)];
    }
    return imei;
}

static NSString *randomMEID(void) {
    NSMutableString *meid = [NSMutableString string];
    for (int i = 0; i < 14; i++) {
        [meid appendFormat:@"%02x", arc4random_uniform(16)];
    }
    return [meid uppercaseString];
}

static NSString *randomUDID(void) {
    return randomHexString(40);
}

static NSString *randomECID(void) {
    uint64_t ecid = 0;
    arc4random_buf(&ecid, sizeof(ecid));
    return [NSString stringWithFormat:@"%016llX", ecid];
}

static NSString *randomInternalIP(void) {
    return [NSString stringWithFormat:@"192.168.%d.%d",
            arc4random_uniform(254) + 1, arc4random_uniform(254) + 1];
}

static NSString *randomWifiSerial(void) {
    static const char chars[] = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    NSMutableString *result = [NSMutableString string];
    for (int i = 0; i < 12; i++) {
        [result appendFormat:@"%c", chars[arc4random_uniform((uint32_t)(sizeof(chars) - 1))]];
    }
    return result;
}

typedef struct {
    NSString *modelIdentifier;
    NSString *displayName;
    NSString *cpuName;
    NSString *gpuName;
    NSInteger processorCount;
    NSString *memorySize;
    NSString *diskSize;
    NSString *batteryCapacity;
    CGFloat minVersion;
    CGFloat maxVersion;
} DeviceSpec;

static DeviceSpec deviceSpecs[] = {
    {@"iPhone10,3", @"iPhone X",        @"A11 Bionic",     @"Apple GPU (3-core)", 6, @"3 GB",  @"64/256GB",    @"2716 mAh", 11.0, 16.7},
    {@"iPhone10,6", @"iPhone X",        @"A11 Bionic",     @"Apple GPU (3-core)", 6, @"3 GB",  @"64/256GB",    @"2716 mAh", 11.0, 16.7},
    {@"iPhone11,2", @"iPhone XS",       @"A12 Bionic",     @"Apple GPU (4-core)", 6, @"4 GB",  @"64/256/512GB",@"2658 mAh", 12.0, 17.4},
    {@"iPhone11,4", @"iPhone XS Max",   @"A12 Bionic",     @"Apple GPU (4-core)", 6, @"4 GB",  @"64/256/512GB",@"3174 mAh", 12.0, 17.4},
    {@"iPhone11,8", @"iPhone XR",       @"A12 Bionic",     @"Apple GPU (4-core)", 6, @"3 GB",  @"64/128/256GB",@"2942 mAh", 12.0, 17.4},
    {@"iPhone12,1", @"iPhone 11",       @"A13 Bionic",     @"Apple GPU (4-core)", 6, @"4 GB",  @"64/128/256GB",@"3110 mAh", 13.0, 18.0},
    {@"iPhone12,3", @"iPhone 11 Pro",   @"A13 Bionic",     @"Apple GPU (4-core)", 6, @"4 GB",  @"64/256/512GB",@"3046 mAh", 13.0, 18.0},
    {@"iPhone13,2", @"iPhone 12",       @"A14 Bionic",     @"Apple GPU (4-core)", 6, @"4 GB",  @"64/256GB",    @"2815 mAh", 14.0, 18.0},
    {@"iPhone13,3", @"iPhone 12 Pro",   @"A14 Bionic",     @"Apple GPU (4-core)", 6, @"6 GB",  @"128/256/512GB",@"2815 mAh", 14.0, 18.0},
    {@"iPhone14,2", @"iPhone 13 Pro",   @"A15 Bionic",     @"Apple GPU (5-core)", 6, @"6 GB",  @"128/256/512GB/1TB",@"3095 mAh", 15.0, 18.3},
    {@"iPhone14,5", @"iPhone 13",       @"A15 Bionic",     @"Apple GPU (4-core)", 6, @"4 GB",  @"128/256/512GB",@"3227 mAh", 15.0, 18.3},
    {@"iPhone14,7", @"iPhone 14",       @"A15 Bionic",     @"Apple GPU (5-core)", 6, @"6 GB",  @"128/256/512GB",@"3279 mAh", 16.0, 18.3},
    {@"iPhone15,2", @"iPhone 14 Pro",   @"A16 Bionic",     @"Apple GPU (5-core)", 6, @"6 GB",  @"128/256/512GB/1TB",@"3200 mAh", 16.0, 18.3},
    {@"iPhone15,3", @"iPhone 14 Pro Max",@"A16 Bionic",    @"Apple GPU (5-core)", 6, @"6 GB",  @"128/256/512GB/1TB",@"4323 mAh", 16.0, 18.3},
    {@"iPhone15,4", @"iPhone 15",       @"A16 Bionic",     @"Apple GPU (5-core)", 6, @"6 GB",  @"128/256/512GB",@"3349 mAh", 17.0, 18.3},
    {@"iPhone16,1", @"iPhone 15 Pro",   @"A17 Pro",        @"Apple GPU (6-core)", 6, @"8 GB",  @"256/512GB/1TB",@"3274 mAh", 17.0, 18.3},
    {@"iPhone16,2", @"iPhone 15 Pro Max",@"A17 Pro",       @"Apple GPU (6-core)", 6, @"8 GB",  @"256/512GB/1TB",@"4422 mAh", 17.0, 18.3},
};

static NSUInteger deviceSpecsCount = sizeof(deviceSpecs) / sizeof(DeviceSpec);

static DeviceSpec *selectRandomDeviceSpec(void) {
    NSUInteger idx = arc4random_uniform((uint32_t)deviceSpecsCount);
    return &deviceSpecs[idx];
}

static NSString *selectSystemVersionForDevice(DeviceSpec *spec) {
    CGFloat minVer = spec->minVersion;
    CGFloat maxVer = spec->maxVersion;

    // Pick from common iOS versions within range
    CGFloat versions[] = {minVer, 14.1, 14.3, 14.4, 14.8, 15.0, 15.1, 15.4, 15.7,
                          16.0, 16.1, 16.3, 16.5, 16.7, 17.0, 17.1, 17.4, 18.0, 18.3};

    NSMutableArray *validVersions = [NSMutableArray array];
    for (int i = 0; i < sizeof(versions)/sizeof(CGFloat); i++) {
        if (versions[i] >= minVer && versions[i] <= maxVer) {
            [validVersions addObject:@(versions[i])];
        }
    }

    if (validVersions.count == 0) {
        return [NSString stringWithFormat:@"%.1f", minVer];
    }

    CGFloat selected = [validVersions[arc4random_uniform((uint32_t)validVersions.count)] floatValue];
    return [NSString stringWithFormat:@"%.1f", selected];
}

static NSString *buildVersionForSystemVersion(NSString *sysVer) {
    NSDictionary *map = @{
        @"14.1": @"18A8395", @"14.3": @"18C66", @"14.4": @"18D52",
        @"14.8": @"18H17", @"15.0": @"19A346", @"15.1": @"19B74",
        @"15.4": @"19E241", @"15.7": @"19H12", @"16.0": @"20A362",
        @"16.1": @"20B79", @"16.3": @"20D47", @"16.5": @"20F66",
        @"16.7": @"20H19", @"17.0": @"21A334", @"17.1": @"21B74",
        @"17.4": @"21E258", @"18.0": @"22A5301e", @"18.3": @"22E245",
    };
    return map[sysVer] ?: @"Unknown";
}

#pragma mark - Preference Loading

static void loadPreferences(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:heavenPrefsPath()];
    if (!prefs) {
        isEnabled = YES;
        antiJailbreakEnabled = YES;
        targetBundleID = nil;
        currentProfile = nil;
        return;
    }

    isEnabled = [prefs[@"Enabled"] boolValue];
    antiJailbreakEnabled = [prefs[@"AntiJailbreak"] boolValue];
    targetBundleID = prefs[@"TargetBundleID"];

    if (!currentProfile) currentProfile = [[HVDeviceProfile alloc] init];

    currentProfile.deviceName = prefs[@"DeviceName"];
    currentProfile.machineModel = prefs[@"MachineModel"];
    currentProfile.systemVersion = prefs[@"SystemVersion"];
    currentProfile.buildVersion = prefs[@"BuildVersion"];
    currentProfile.serialNumber = prefs[@"SerialNumber"];
    currentProfile.cpuMode = prefs[@"CPUMode"];
    currentProfile.gpuModel = prefs[@"GPUModel"];
    currentProfile.processorCount = prefs[@"ProcessorCount"];
    currentProfile.memorySize = prefs[@"MemorySize"];
    currentProfile.diskSize = prefs[@"DiskSize"];
    currentProfile.batteryCapacity = prefs[@"BatteryCapacity"];
    currentProfile.batteryHealth = prefs[@"BatteryHealth"];
    currentProfile.idfa = prefs[@"IDFA"];
    currentProfile.idfv = prefs[@"IDFV"];
    currentProfile.internalIP = prefs[@"InternalIP"];
    currentProfile.macAddress = prefs[@"MACAddress"];
    currentProfile.carrierName = prefs[@"CarrierName"];
    currentProfile.networkType = prefs[@"NetworkType"];
    currentProfile.wifiSSID = prefs[@"WifiSSID"];
    currentProfile.wifiBSSID = prefs[@"WifiBSSID"];
    currentProfile.cellularAddress = prefs[@"CellularAddress"];
    currentProfile.deviceIdentifier = prefs[@"DeviceIdentifier"];
    currentProfile.cpuArchitecture = prefs[@"CPUArchitecture"];
    currentProfile.bluetoothAddress = prefs[@"BluetoothAddress"];
    currentProfile.wifiSerial = prefs[@"WifiSerial"];
    currentProfile.locationName = prefs[@"LocationName"];
    currentProfile.latitude = prefs[@"Latitude"];
    currentProfile.longitude = prefs[@"Longitude"];
    currentProfile.userAgent = prefs[@"UserAgent"];
    currentProfile.imei = prefs[@"IMEI"];
    currentProfile.meid = prefs[@"MEID"];
    currentProfile.udid = prefs[@"UDID"];
    currentProfile.ecid = prefs[@"ECID"];
}

#pragma mark - Target Bundle Filtering

static BOOL shouldApplySpoofing(void) {
    if (!isEnabled) return NO;
    if (!targetBundleID || targetBundleID.length == 0) return YES;
    NSString *currentBundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!currentBundleID) return NO;
    return [currentBundleID isEqualToString:targetBundleID];
}

#pragma mark - Cleanup Functions

static void HVClearKeychain(void) {
    @try {
        NSArray *secClasses = @[
            (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecClassInternetPassword,
            (__bridge id)kSecClassCertificate,
            (__bridge id)kSecClassKey,
            (__bridge id)kSecClassIdentity,
        ];

        for (id secClass in secClasses) {
            NSDictionary *spec = @{
                (__bridge id)kSecClass: secClass,
                (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
                (__bridge id)kSecReturnAttributes: @YES,
                (__bridge id)kSecReturnData: @YES,
            };

            CFArrayRef result = NULL;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)spec, (CFTypeRef *)&result);

            if (status == errSecSuccess && result) {
                NSArray *items = (__bridge_transfer NSArray *)result;
                for (NSDictionary *item in items) {
                    NSMutableDictionary *deleteSpec = [NSMutableDictionary dictionary];
                    deleteSpec[(__bridge id)kSecClass] = secClass;
                    deleteSpec[(__bridge id)kSecAttrService] = item[(__bridge id)kSecAttrService];
                    deleteSpec[(__bridge id)kSecAttrAccount] = item[(__bridge id)kSecAttrAccount];
                    deleteSpec[(__bridge id)kSecAttrAccessGroup] = item[(__bridge id)kSecAttrAccessGroup];
                    SecItemDelete((__bridge CFDictionaryRef)deleteSpec);
                }
            }
        }
        NSLog(@"[Heaven] Keychain cleared");
    } @catch (NSException *exception) {
        NSLog(@"[Heaven] HVClearKeychain exception: %@", exception);
    }
}

static void HVClearCookies(void) {
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [storage.cookies copy];
    for (NSHTTPCookie *cookie in cookies) {
        [storage deleteCookie:cookie];
    }
    NSLog(@"[Heaven] Cookies cleared");
}

static void HVClearWebKitData(void) {
    WKWebsiteDataStore *dataStore = [WKWebsiteDataStore defaultDataStore];
    NSSet *types = [WKWebsiteDataStore allWebsiteDataTypes];
    NSDate *since = [NSDate dateWithTimeIntervalSince1970:0];
    [dataStore removeDataOfTypes:types modifiedSince:since completionHandler:^{
        NSLog(@"[Heaven] WebKit data cleared");
    }];
}

static void HVClearClipboard(void) {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = @"";
    pasteboard.URL = nil;
    pasteboard.image = nil;
    NSLog(@"[Heaven] Clipboard cleared");
}

static void HVClearCache(void) {
    // Clear file-based caches in common paths
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *paths = @[
        ROOT_PATH_NS(@"/var/mobile/Library/Caches"),
        ROOT_PATH_NS(@"/var/mobile/Library/WebKit"),
        ROOT_PATH_NS(@"/var/mobile/Library/Cookies"),
    ];

    for (NSString *path in paths) {
        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:nil];
        for (NSString *file in contents) {
            if ([file hasPrefix:@"."]) continue;
            NSString *fullPath = [path stringByAppendingPathComponent:file];
            [fm removeItemAtPath:fullPath error:nil];
        }
    }
    NSLog(@"[Heaven] Cache cleared");
}

static void HVForceCleanupAfterRegenerate(void) {
    @try {
        HVClearKeychain();
        HVClearCookies();
        HVClearWebKitData();
        HVClearClipboard();
        HVClearCache();
        NSLog(@"[Heaven] Force cleanup completed");
    } @catch (NSException *exception) {
        NSLog(@"[Heaven] HVForceCleanupAfterRegenerate exception: %@", exception);
    }
}

#pragma mark - Anti-Jailbreak Detection

static BOOL isJBProcess(void) {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    NSArray *jbProcesses = @[@"cydia", @"sileo", @"zbra", @"installer5",
                              @"filza", @"undecimus", @"uicache"];
    for (NSString *name in jbProcesses) {
        if ([processName.lowercaseString containsString:name]) {
            return YES;
        }
    }
    return NO;
}

static BOOL isInjected(void) {
    // Check for common jailbreak injection libraries
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        NSString *name = [NSString stringWithUTF8String:_dyld_get_image_name(i)];
        if ([name containsString:@"Substrate"] ||
            [name containsString:@"libhooker"] ||
            [name containsString:@"substitute"] ||
            [name containsString:@"frida"] ||
            [name containsString:@"cycript"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL checkJailbreakFiles(void) {
    NSArray *jbPaths = @[
        ROOT_PATH_NS(@"/Applications/Cydia.app"),
        ROOT_PATH_NS(@"/Applications/Sileo.app"),
        ROOT_PATH_NS(@"/Applications/Filza.app"),
        ROOT_PATH_NS(@"/Applications/Icy.app"),
        ROOT_PATH_NS(@"/bin/bash"),
        ROOT_PATH_NS(@"/usr/sbin/sshd"),
        ROOT_PATH_NS(@"/usr/bin/cycript"),
        ROOT_PATH_NS(@"/etc/apt"),
        ROOT_PATH_NS(@"/var/lib/cydia"),
        ROOT_PATH_NS(@"/var/cache/apt"),
        ROOT_PATH_NS(@"/var/log/syslog"),
        ROOT_PATH_NS(@"/var/tmp/frida-server"),
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in jbPaths) {
        if ([fm fileExistsAtPath:path]) {
            return YES;
        }
    }
    return NO;
}

static BOOL detectDebugger(void) {
    // Check for debugger via sysctl
    int name[] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct kinfo_proc info;
    size_t info_size = sizeof(info);
    info.kp_proc.p_flag = 0;

    if (sysctl(name, 4, &info, &info_size, NULL, 0) == 0) {
        return (info.kp_proc.p_flag & P_TRACED) != 0;
    }
    return NO;
}


#pragma mark - sysctlbyname Hook

static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!shouldApplySpoofing() || !currentProfile) {
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }

    if (strcmp(name, "hw.machine") == 0 ||
        strcmp(name, "hw.model") == 0 ||
        strcmp(name, "machdep.cpu.brand_string") == 0) {

        NSString *sValue = nil;
        if (strcmp(name, "hw.machine") == 0) {
            sValue = currentProfile.machineModel ?: orig_sysctlbyname ? nil : @"iPhone14,2";
        } else if (strcmp(name, "hw.model") == 0) {
            sValue = currentProfile.machineModel ?: @"iPhone14,2";
        } else {
            sValue = currentProfile.cpuMode ?: @"Apple A15 Bionic";
        }

        if (sValue && oldp && oldlenp) {
            const char *cStr = [sValue UTF8String];
            size_t len = strlen(cStr) + 1;
            if (*oldlenp >= len) {
                memcpy(oldp, cStr, len);
            }
            *oldlenp = len;
            return 0;
        }
    }

    if (strcmp(name, "hw.memsize") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            uint64_t memSize = 6ULL * 1024 * 1024 * 1024; // 6 GB default
            if ([currentProfile.memorySize hasPrefix:@"8"]) {
                memSize = 8ULL * 1024 * 1024 * 1024;
            } else if ([currentProfile.memorySize hasPrefix:@"4"]) {
                memSize = 4ULL * 1024 * 1024 * 1024;
            } else if ([currentProfile.memorySize hasPrefix:@"3"]) {
                memSize = 3ULL * 1024 * 1024 * 1024;
            }
            memcpy(oldp, &memSize, sizeof(uint64_t));
            *oldlenp = sizeof(uint64_t);
            return 0;
        }
    }

    if (strcmp(name, "hw.ncpu") == 0 ||
        strcmp(name, "hw.activecpu") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(int)) {
            int ncpu = (int)[currentProfile.processorCount integerValue] ?: 6;
            memcpy(oldp, &ncpu, sizeof(int));
            *oldlenp = sizeof(int);
            return 0;
        }
    }

    if (strcmp(name, "hw.cpufrequency") == 0) {
        if (oldp && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            uint64_t freq = 3000000000ULL; // 3 GHz
            memcpy(oldp, &freq, sizeof(uint64_t));
            *oldlenp = sizeof(uint64_t);
            return 0;
        }
    }

    if (strcmp(name, "kern.boottime") == 0) {
        if (antiJailbreakEnabled) {
            // Spoof boot time to a recent time
            struct timeval boottime = {0};
            time_t now = time(NULL);
            boottime.tv_sec = now - (86400 * 7); // 7 days ago
            boottime.tv_usec = 0;
            if (oldp && oldlenp && *oldlenp >= sizeof(boottime)) {
                memcpy(oldp, &boottime, sizeof(boottime));
                *oldlenp = sizeof(boottime);
                return 0;
            }
        }
    }

    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

#pragma mark - getifaddrs Hook

static int hooked_getifaddrs(struct ifaddrs **ifap) {
    int ret = orig_getifaddrs(ifap);
    if (ret != 0 || !ifap || !*ifap) return ret;
    if (!shouldApplySpoofing() || !currentProfile) return ret;

    struct ifaddrs *ifa = *ifap;
    while (ifa) {
        if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_LINK) {
            NSString *ifname = [NSString stringWithUTF8String:ifa->ifa_name];

            // Spoof en0 MAC address (WiFi)
            if ([ifname isEqualToString:@"en0"] && currentProfile.macAddress) {
                struct sockaddr_dl *sdl = (struct sockaddr_dl *)ifa->ifa_addr;
                if (sdl->sdl_alen == 6) {
                    NSArray *bytes = [currentProfile.macAddress componentsSeparatedByString:@":"];
                    if (bytes.count == 6) {
                        for (int i = 0; i < 6; i++) {
                            unsigned int byte;
                            sscanf([bytes[i] UTF8String], "%02x", &byte);
                            ((uint8_t *)LLADDR(sdl))[i] = (uint8_t)byte;
                        }
                    }
                }
            }

            // Spoof awdl0 MAC address (Bluetooth)
            if ([ifname hasPrefix:@"awdl"] && currentProfile.bluetoothAddress) {
                struct sockaddr_dl *sdl = (struct sockaddr_dl *)ifa->ifa_addr;
                if (sdl->sdl_alen == 6) {
                    NSArray *bytes = [currentProfile.bluetoothAddress componentsSeparatedByString:@":"];
                    if (bytes.count == 6) {
                        for (int i = 0; i < 6; i++) {
                            unsigned int byte;
                            sscanf([bytes[i] UTF8String], "%02x", &byte);
                            ((uint8_t *)LLADDR(sdl))[i] = (uint8_t)byte;
                        }
                    }
                }
            }
        }
        ifa = ifa->ifa_next;
    }

    return ret;
}

#pragma mark - fork Hook

static pid_t hooked_fork(void) {
    if (antiJailbreakEnabled && shouldApplySpoofing()) {
        // Block fork - prevent debugging tools
        errno = EPERM;
        return -1;
    }
    return orig_fork();
}

#pragma mark - UIDevice Hooks

static NSString *hooked_UIDevice_name(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.deviceName) {
        return orig_UIDevice_name(self, _cmd);
    }
    return currentProfile.deviceName;
}

static NSString *hooked_UIDevice_model(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.machineModel) {
        return orig_UIDevice_model(self, _cmd);
    }
    // Return user-facing model name
    for (NSUInteger i = 0; i < deviceSpecsCount; i++) {
        if ([deviceSpecs[i].modelIdentifier isEqualToString:currentProfile.machineModel]) {
            return deviceSpecs[i].displayName;
        }
    }
    return @"iPhone";
}

static NSString *hooked_UIDevice_localizedModel(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.machineModel) {
        return orig_UIDevice_localizedModel(self, _cmd);
    }
    for (NSUInteger i = 0; i < deviceSpecsCount; i++) {
        if ([deviceSpecs[i].modelIdentifier isEqualToString:currentProfile.machineModel]) {
            return deviceSpecs[i].displayName;
        }
    }
    return @"iPhone";
}

static NSString *hooked_UIDevice_systemVersion(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.systemVersion) {
        return orig_UIDevice_systemVersion(self, _cmd);
    }
    return currentProfile.systemVersion;
}

static NSString *hooked_UIDevice_systemName(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_UIDevice_systemName(self, _cmd);
    }
    return @"iPhone OS";
}

static NSUUID *hooked_UIDevice_identifierForVendor(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.idfv) {
        return orig_UIDevice_identifierForVendor(self, _cmd);
    }
    return [[NSUUID alloc] initWithUUIDString:currentProfile.idfv];
}

static float hooked_UIDevice_batteryLevel(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_UIDevice_batteryLevel(self, _cmd);
    }
    // Return a realistic random battery level between 0.15 and 1.0
    return 0.15 + ((float)arc4random_uniform(8500) / 10000.0);
}

static NSInteger hooked_UIDevice_batteryState(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_UIDevice_batteryState(self, _cmd);
    }
    return 2; // Unplugged (charging via USB = 1, unplugged = 2, full = 3)
}

#pragma mark - NSProcessInfo Hooks

static NSString *hooked_NSProcessInfo_operatingSystemVersionString(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.systemVersion) {
        return orig_NSProcessInfo_operatingSystemVersionString(self, _cmd);
    }
    return [NSString stringWithFormat:@"Version %@ (Build %@)",
            currentProfile.systemVersion, currentProfile.buildVersion ?: @"Unknown"];
}

static NSOperatingSystemVersion hooked_NSProcessInfo_operatingSystemVersion(id self, SEL _cmd) {
    NSOperatingSystemVersion version = orig_NSProcessInfo_operatingSystemVersion(self, _cmd);
    if (!shouldApplySpoofing() || !currentProfile.systemVersion) return version;

    NSArray *parts = [currentProfile.systemVersion componentsSeparatedByString:@"."];
    version.majorVersion = parts.count > 0 ? [parts[0] integerValue] : version.majorVersion;
    version.minorVersion = parts.count > 1 ? [parts[1] integerValue] : version.minorVersion;
    version.patchVersion = parts.count > 2 ? [parts[2] integerValue] : 0;
    return version;
}

static NSUInteger hooked_NSProcessInfo_processorCount(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.processorCount) {
        return orig_NSProcessInfo_processorCount(self, _cmd);
    }
    return (NSUInteger)[currentProfile.processorCount integerValue];
}

static NSUInteger hooked_NSProcessInfo_activeProcessorCount(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.processorCount) {
        return orig_NSProcessInfo_activeProcessorCount(self, _cmd);
    }
    return (NSUInteger)[currentProfile.processorCount integerValue];
}

static NSString *hooked_NSProcessInfo_hostName(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_NSProcessInfo_hostName(self, _cmd);
    }
    return currentProfile.deviceName ?: orig_NSProcessInfo_hostName(self, _cmd);
}

#pragma mark - UIScreen Hooks

static CGFloat hooked_UIScreen_brightness(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_UIScreen_brightness(self, _cmd);
    }
    return 0.6 + ((float)arc4random_uniform(3500) / 10000.0);
}

static CGFloat hooked_UIScreen_scale(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_UIScreen_scale(self, _cmd);
    }
    return 3.0; // All modern iPhones have 3x display
}

#pragma mark - ASIdentifierManager Hook

static NSUUID *(*orig_ASIdentifierManager_advertisingIdentifier)(id, SEL);
static BOOL (*orig_ASIdentifierManager_isAdvertisingTrackingEnabled)(id, SEL);

static NSUUID *hooked_ASIdentifierManager_advertisingIdentifier(id self, SEL _cmd) {
    if (!shouldApplySpoofing() || !currentProfile.idfa) {
        return orig_ASIdentifierManager_advertisingIdentifier(self, _cmd);
    }
    return [[NSUUID alloc] initWithUUIDString:currentProfile.idfa];
}

static BOOL hooked_ASIdentifierManager_isAdvertisingTrackingEnabled(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_ASIdentifierManager_isAdvertisingTrackingEnabled(self, _cmd);
    }
    return YES;
}

#pragma mark - ATTrackingManager Hook

static NSUInteger (*orig_ATTrackingManager_trackingAuthorizationStatus)(id, SEL);

static NSUInteger hooked_ATTrackingManager_trackingAuthorizationStatus(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_ATTrackingManager_trackingAuthorizationStatus(self, _cmd);
    }
    return 3; // ATTrackingManagerAuthorizationStatusAuthorized
}

#pragma mark - CLLocationManager Hook

static void (*orig_CLLocationManager_setDelegate)(id, SEL, id);
static void (*orig_CLLocationManager_startUpdatingLocation)(id, SEL);
static void (*orig_CLLocationManager_stopUpdatingLocation)(id, SEL);
static void (*orig_CLLocationManager_requestLocation)(id, SEL);
static CLAuthorizationStatus (*orig_CLLocationManager_authorizationStatus)(id, SEL);

static void hooked_CLLocationManager_setDelegate(id self, SEL _cmd, id delegate);

@interface HVLocationManager : NSObject <CLLocationManagerDelegate>
@property (nonatomic, strong) CLLocation *spoofedLocation;
@property (nonatomic, weak) id<CLLocationManagerDelegate> realDelegate;
+ (instancetype)sharedInstance;
- (void)updateSpoofedLocation;
@end

@implementation HVLocationManager

+ (instancetype)sharedInstance {
    static HVLocationManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (void)updateSpoofedLocation {
    double latitude = [currentProfile.latitude doubleValue] ?: 39.9042;
    double longitude = [currentProfile.longitude doubleValue] ?: 116.4074;

    self.spoofedLocation = [[CLLocation alloc]
        initWithCoordinate:CLLocationCoordinate2DMake(latitude, longitude)
                  altitude:50.0
        horizontalAccuracy:100.0
          verticalAccuracy:50.0
                    course:0.0
                     speed:0.0
                 timestamp:[NSDate date]];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    // Call delegate with spoofed location
    if ([self.realDelegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [self.realDelegate locationManager:manager didUpdateLocations:@[self.spoofedLocation ?: locations.firstObject]];
    }
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status API_DEPRECATED_WITH_REPLACEMENT("-locationManagerDidChangeAuthorization:", ios(4.2, 14.0)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if ([self.realDelegate respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
        [self.realDelegate locationManager:manager didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedWhenInUse];
    }
#pragma clang diagnostic pop
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    if ([self.realDelegate respondsToSelector:@selector(locationManagerDidChangeAuthorization:)]) {
        [self.realDelegate locationManagerDidChangeAuthorization:manager];
    }
}

@end

static void hooked_CLLocationManager_setDelegate(id self, SEL _cmd, id delegate) {
    orig_CLLocationManager_setDelegate(self, _cmd, [HVLocationManager sharedInstance]);
    [HVLocationManager sharedInstance].realDelegate = delegate;
}

static void hooked_CLLocationManager_startUpdatingLocation(id self, SEL _cmd) {
    orig_CLLocationManager_startUpdatingLocation(self, _cmd);
}

static void hooked_CLLocationManager_stopUpdatingLocation(id self, SEL _cmd) {
    orig_CLLocationManager_stopUpdatingLocation(self, _cmd);
}

static void hooked_CLLocationManager_requestLocation(id self, SEL _cmd) {
    orig_CLLocationManager_requestLocation(self, _cmd);
}

static CLAuthorizationStatus hooked_CLLocationManager_authorizationStatus(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_CLLocationManager_authorizationStatus(self, _cmd);
    }
    return kCLAuthorizationStatusAuthorizedWhenInUse;
}

#pragma mark - UIApplication Hook

static BOOL (*orig_UIApplication_canOpenURL)(id, SEL, NSURL *);

static BOOL hooked_UIApplication_canOpenURL(id self, SEL _cmd, NSURL *url) {
    if (antiJailbreakEnabled && shouldApplySpoofing()) {
        NSString *scheme = url.scheme.lowercaseString;
        NSArray *jbSchemes = @[@"cydia", @"sileo", @"filza", @"zbra", @"installer"];
        for (NSString *jbScheme in jbSchemes) {
            if ([scheme containsString:jbScheme]) {
                return NO;
            }
        }
    }
    return orig_UIApplication_canOpenURL(self, _cmd, url);
}

#pragma mark - CNCopyCurrentNetworkInfo Hook

typedef CFDictionaryRef (*CNCopyCurrentNetworkInfo_t)(CFStringRef);

static CNCopyCurrentNetworkInfo_t orig_CNCopyCurrentNetworkInfo = NULL;

static CFDictionaryRef hooked_CNCopyCurrentNetworkInfo(CFStringRef interfaceName) {
    if (!shouldApplySpoofing()) {
        return orig_CNCopyCurrentNetworkInfo(interfaceName);
    }

    // Return spoofed WiFi info
    NSDictionary *spoofedInfo = @{};
    if (currentProfile.wifiSSID && currentProfile.wifiBSSID) {
        spoofedInfo = @{
            (__bridge NSString *)kCNNetworkInfoKeySSID: currentProfile.wifiSSID,
            (__bridge NSString *)kCNNetworkInfoKeyBSSID: currentProfile.wifiBSSID,
        };
    }

    return (CFDictionaryRef)CFBridgingRetain(spoofedInfo);
}

#pragma mark - Audio Session Hook

static float (*orig_AVAudioSession_outputVolume)(id, SEL);

static float hooked_AVAudioSession_outputVolume(id self, SEL _cmd) {
    if (!shouldApplySpoofing()) {
        return orig_AVAudioSession_outputVolume(self, _cmd);
    }
    return 0.5 + ((float)arc4random_uniform(4000) / 10000.0);
}

#pragma mark - Preference Change Notification

static void onPreferenceChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    loadPreferences();

    if (currentProfile) {
        [[HVLocationManager sharedInstance] updateSpoofedLocation];
    }
}

static void onRegenerateNotification(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                      const void *object, CFDictionaryRef userInfo) {
    loadPreferences();

    // Regenerate all device info
    DeviceSpec *spec = selectRandomDeviceSpec();
    currentProfile.machineModel = spec->modelIdentifier;
    currentProfile.deviceName = [NSString stringWithFormat:@"%@的用户", spec->displayName];
    currentProfile.systemVersion = selectSystemVersionForDevice(spec);
    currentProfile.buildVersion = buildVersionForSystemVersion(currentProfile.systemVersion);
    currentProfile.serialNumber = randomSerialNumber();
    currentProfile.cpuMode = spec->cpuName;
    currentProfile.gpuModel = spec->gpuName;
    currentProfile.processorCount = [NSString stringWithFormat:@"%ld", (long)spec->processorCount];
    currentProfile.memorySize = spec->memorySize;
    currentProfile.diskSize = spec->diskSize;
    currentProfile.batteryCapacity = spec->batteryCapacity;
    currentProfile.batteryHealth = [NSString stringWithFormat:@"%d%%", arc4random_uniform(21) + 80];
    currentProfile.idfa = randomUUIDString();
    currentProfile.idfv = randomUUIDString();
    currentProfile.internalIP = randomInternalIP();
    currentProfile.macAddress = randomMACAddress();
    currentProfile.cellularAddress = randomMACAddress();
    currentProfile.bluetoothAddress = randomMACAddress();
    currentProfile.wifiSerial = randomWifiSerial();
    currentProfile.wifiSSID = [NSString stringWithFormat:@"Nwm-%@", randomHexString(4).uppercaseString];
    currentProfile.wifiBSSID = randomMACAddress();
    currentProfile.deviceIdentifier = randomUUIDString();
    currentProfile.cpuArchitecture = @"arm64";
    currentProfile.imei = randomIMEI();
    currentProfile.meid = randomMEID();
    currentProfile.udid = randomUDID();
    currentProfile.ecid = randomECID();
    currentProfile.userAgent = [NSString stringWithFormat:
        @"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) "
        @"AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        currentProfile.systemVersion];
    currentProfile.locationName = @"中国";
    currentProfile.latitude = [NSString stringWithFormat:@"%.6f", 39.9 + (double)arc4random_uniform(1000) / 10000.0];
    currentProfile.longitude = [NSString stringWithFormat:@"%.6f", 116.3 + (double)arc4random_uniform(2000) / 10000.0];

    // Save to preferences
    NSMutableDictionary *prefs = [[NSMutableDictionary alloc] initWithContentsOfFile:heavenPrefsPath()];
    if (!prefs) prefs = [NSMutableDictionary dictionary];

    prefs[@"DeviceName"] = currentProfile.deviceName;
    prefs[@"MachineModel"] = currentProfile.machineModel;
    prefs[@"SystemVersion"] = currentProfile.systemVersion;
    prefs[@"BuildVersion"] = currentProfile.buildVersion;
    prefs[@"SerialNumber"] = currentProfile.serialNumber;
    prefs[@"CPUMode"] = currentProfile.cpuMode;
    prefs[@"GPUModel"] = currentProfile.gpuModel;
    prefs[@"ProcessorCount"] = currentProfile.processorCount;
    prefs[@"MemorySize"] = currentProfile.memorySize;
    prefs[@"DiskSize"] = currentProfile.diskSize;
    prefs[@"BatteryCapacity"] = currentProfile.batteryCapacity;
    prefs[@"BatteryHealth"] = currentProfile.batteryHealth;
    prefs[@"IDFA"] = currentProfile.idfa;
    prefs[@"IDFV"] = currentProfile.idfv;
    prefs[@"InternalIP"] = currentProfile.internalIP;
    prefs[@"MACAddress"] = currentProfile.macAddress;
    prefs[@"CellularAddress"] = currentProfile.cellularAddress;
    prefs[@"BluetoothAddress"] = currentProfile.bluetoothAddress;
    prefs[@"WifiSerial"] = currentProfile.wifiSerial;
    prefs[@"WifiSSID"] = currentProfile.wifiSSID;
    prefs[@"WifiBSSID"] = currentProfile.wifiBSSID;
    prefs[@"DeviceIdentifier"] = currentProfile.deviceIdentifier;
    prefs[@"CPUArchitecture"] = currentProfile.cpuArchitecture;
    prefs[@"IMEI"] = currentProfile.imei;
    prefs[@"MEID"] = currentProfile.meid;
    prefs[@"UDID"] = currentProfile.udid;
    prefs[@"ECID"] = currentProfile.ecid;
    prefs[@"UserAgent"] = currentProfile.userAgent;
    prefs[@"LocationName"] = currentProfile.locationName;
    prefs[@"Latitude"] = currentProfile.latitude;
    prefs[@"Longitude"] = currentProfile.longitude;

    [prefs writeToFile:heavenPrefsPath() atomically:YES];

    [[HVLocationManager sharedInstance] updateSpoofedLocation];

    // Force cleanup after regenerating
    HVForceCleanupAfterRegenerate();
}

#pragma mark - Hook Installation

static void HVInstallAllHooks(void) {
    @try {
        MSHookMessage(
            objc_getClass("UIDevice"),
            @selector(name),
            &hooked_UIDevice_name,
            &orig_UIDevice_name
        );

        MSHookMessage(
            objc_getClass("UIDevice"),
            @selector(model),
            &hooked_UIDevice_model,
            &orig_UIDevice_model
        );

        MSHookMessage(
            objc_getClass("UIDevice"),
            @selector(localizedModel),
            &hooked_UIDevice_localizedModel,
            &orig_UIDevice_localizedModel
        );

        MSHookMessage(
            objc_getClass("UIDevice"),
            @selector(systemVersion),
            &hooked_UIDevice_systemVersion,
            &orig_UIDevice_systemVersion
        );

        MSHookMessage(
            objc_getClass("UIDevice"),
            @selector(systemName),
            &hooked_UIDevice_systemName,
            &orig_UIDevice_systemName
        );

        MSHookMessage(
            objc_getClass("UIDevice"),
            @selector(identifierForVendor),
            &hooked_UIDevice_identifierForVendor,
            &orig_UIDevice_identifierForVendor
        );

        MSHookMessage(
            objc_getClass("UIDevice"),
            @selector(batteryLevel),
            &hooked_UIDevice_batteryLevel,
            &orig_UIDevice_batteryLevel
        );

        MSHookMessage(
            objc_getClass("UIDevice"),
            @selector(batteryState),
            &hooked_UIDevice_batteryState,
            &orig_UIDevice_batteryState
        );

        MSHookMessage(
            objc_getClass("NSProcessInfo"),
            @selector(operatingSystemVersionString),
            &hooked_NSProcessInfo_operatingSystemVersionString,
            &orig_NSProcessInfo_operatingSystemVersionString
        );

        MSHookMessage(
            objc_getClass("NSProcessInfo"),
            @selector(operatingSystemVersion),
            &hooked_NSProcessInfo_operatingSystemVersion,
            &orig_NSProcessInfo_operatingSystemVersion
        );

        MSHookMessage(
            objc_getClass("NSProcessInfo"),
            @selector(processorCount),
            &hooked_NSProcessInfo_processorCount,
            &orig_NSProcessInfo_processorCount
        );

        MSHookMessage(
            objc_getClass("NSProcessInfo"),
            @selector(activeProcessorCount),
            &hooked_NSProcessInfo_activeProcessorCount,
            &orig_NSProcessInfo_activeProcessorCount
        );

        MSHookMessage(
            objc_getClass("NSProcessInfo"),
            @selector(hostName),
            &hooked_NSProcessInfo_hostName,
            &orig_NSProcessInfo_hostName
        );

        MSHookMessage(
            objc_getClass("UIScreen"),
            @selector(brightness),
            &hooked_UIScreen_brightness,
            &orig_UIScreen_brightness
        );

        MSHookMessage(
            objc_getClass("UIScreen"),
            @selector(scale),
            &hooked_UIScreen_scale,
            &orig_UIScreen_scale
        );

        MSHookMessage(
            objc_getClass("UIApplication"),
            @selector(canOpenURL:),
            &hooked_UIApplication_canOpenURL,
            &orig_UIApplication_canOpenURL
        );

        // Hook ASIdentifierManager
        Class asIdClass = objc_getClass("ASIdentifierManager");
        if (asIdClass) {
            MSHookMessage(
                asIdClass,
                @selector(advertisingIdentifier),
                &hooked_ASIdentifierManager_advertisingIdentifier,
                &orig_ASIdentifierManager_advertisingIdentifier
            );
            MSHookMessage(
                asIdClass,
                @selector(isAdvertisingTrackingEnabled),
                &hooked_ASIdentifierManager_isAdvertisingTrackingEnabled,
                &orig_ASIdentifierManager_isAdvertisingTrackingEnabled
            );
        }

        // Hook ATTrackingManager
        Class attClass = objc_getClass("ATTrackingManager");
        if (attClass) {
            MSHookMessage(
                attClass,
                @selector(trackingAuthorizationStatus),
                &hooked_ATTrackingManager_trackingAuthorizationStatus,
                &orig_ATTrackingManager_trackingAuthorizationStatus
            );
        }

        // Hook CLLocationManager
        MSHookMessage(
            objc_getClass("CLLocationManager"),
            @selector(setDelegate:),
            &hooked_CLLocationManager_setDelegate,
            &orig_CLLocationManager_setDelegate
        );

        MSHookMessage(
            objc_getClass("CLLocationManager"),
            @selector(authorizationStatus),
            &hooked_CLLocationManager_authorizationStatus,
            &orig_CLLocationManager_authorizationStatus
        );

        // Hook AVAudioSession outputVolume
        Class audioSessionClass = objc_getClass("AVAudioSession");
        if (audioSessionClass) {
            MSHookMessage(
                audioSessionClass,
                @selector(outputVolume),
                &hooked_AVAudioSession_outputVolume,
                &orig_AVAudioSession_outputVolume
            );
        }

        // Hook sysctlbyname C function
        MSHookFunction(
            (void *)&sysctlbyname,
            (void *)&hooked_sysctlbyname,
            (void **)&orig_sysctlbyname
        );

        // Hook getifaddrs C function
        MSHookFunction(
            (void *)&getifaddrs,
            (void *)&hooked_getifaddrs,
            (void **)&orig_getifaddrs
        );

        // Hook fork C function
        MSHookFunction(
            (void *)&fork,
            (void *)&hooked_fork,
            (void **)&orig_fork
        );

        // Hook CNCopyCurrentNetworkInfo
        void *handle = dlopen(ROOT_PATH("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration"), RTLD_LAZY);
        if (handle) {
            orig_CNCopyCurrentNetworkInfo = (CNCopyCurrentNetworkInfo_t)dlsym(handle, "CNCopyCurrentNetworkInfo");
            if (orig_CNCopyCurrentNetworkInfo) {
                MSHookFunction(
                    (void *)orig_CNCopyCurrentNetworkInfo,
                    (void *)&hooked_CNCopyCurrentNetworkInfo,
                    (void **)&orig_CNCopyCurrentNetworkInfo
                );
            }
            dlclose(handle);
        }

        NSLog(@"[Heaven] All hooks installed successfully");

    } @catch (NSException *exception) {
        NSLog(@"[Heaven] HVInstallAllHooks exception: %@", exception);
    }
}

#pragma mark - Constructor

__attribute__((constructor)) static void HeavenInit(void) {
    @autoreleasepool {
        // Load preferences first
        loadPreferences();

        if (!isEnabled) {
            NSLog(@"[Heaven] Disabled, skipping hook installation");
            return;
        }

        // Install all hooks
        HVInstallAllHooks();

        // Register for preference change notifications
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            onPreferenceChanged,
            (__bridge CFStringRef)kNotifyPrefsChanged,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            onRegenerateNotification,
            (__bridge CFStringRef)kNotifyRegenerate,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        // Initialize location spoofing
        [[HVLocationManager sharedInstance] updateSpoofedLocation];
    }
}
