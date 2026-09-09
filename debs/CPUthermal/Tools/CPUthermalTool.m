#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <dlfcn.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <CPUthermalPaths.h>
#import <CPUthermalPressure.h>

static int runExecutable(NSString *path, char *const argv[]) {
    if (path.length == 0 || !argv || !argv[0]) return 127;
    pid_t pid = 0;
    int status = 0;
    if (posix_spawn(&pid, [path fileSystemRepresentation], NULL, NULL, argv, NULL) != 0) return 126;
    if (waitpid(pid, &status, 0) < 0) return 125;
    return WIFEXITED(status) ? WEXITSTATUS(status) : status;
}

static int rebootUserspace(void) {
    NSString *launchctlPath = CPUthermalLaunchctlPath();
    char *args[] = {(char *)"launchctl", (char *)"reboot", (char *)"userspace", NULL};
    return runExecutable(launchctlPath, args);
}

static int restoreFullPower(void) {
    NSString *prefPath = CPUthermalCurrentPrefPath();
    if (prefPath.length == 0) return 1;
    NSString *directory = [prefPath stringByDeletingLastPathComponent];
    if (directory.length == 0) return 1;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:prefPath];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[S("powerMode")] = S("fullPower");
    if (![prefs writeToFile:prefPath atomically:YES]) return 1;
    return CPUthermalPostPowerMode(S("fullPower")) == NOTIFY_STATUS_OK ? 0 : 1;
}

static int SetThermalPreference(NSString *key, id value, NSString *persistentKey, BOOL persist) {
    typedef CFTypeRef (*CreateFn)(CFAllocatorRef, CFStringRef, CFStringRef);
    typedef Boolean (*SetFn)(CFTypeRef, CFStringRef, CFPropertyListRef);
    typedef Boolean (*RemoveFn)(CFTypeRef, CFStringRef);
    typedef Boolean (*ApplyFn)(CFTypeRef);
    void *framework = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW | RTLD_LOCAL);
    if (!framework) return 1;
    CreateFn create = (CreateFn)dlsym(framework, "SCPreferencesCreate");
    SetFn setValue = (SetFn)dlsym(framework, "SCPreferencesSetValue");
    RemoveFn removeValue = (RemoveFn)dlsym(framework, "SCPreferencesRemoveValue");
    ApplyFn commit = (ApplyFn)dlsym(framework, "SCPreferencesCommitChanges");
    ApplyFn apply = (ApplyFn)dlsym(framework, "SCPreferencesApplyChanges");
    if (!create || !setValue || !removeValue || !commit || !apply) { dlclose(framework); return 1; }
    CFTypeRef preferences = create(kCFAllocatorDefault, CFSTR("CPUthermal"), CFSTR("OSThermalStatus.plist"));
    if (!preferences) { dlclose(framework); return 1; }
    if (value) setValue(preferences, (__bridge CFStringRef)key, (__bridge CFPropertyListRef)value);
    else removeValue(preferences, (__bridge CFStringRef)key);
    if (persistentKey) {
        if (value) setValue(preferences, (__bridge CFStringRef)persistentKey, persist ? kCFBooleanTrue : kCFBooleanFalse);
        else removeValue(preferences, (__bridge CFStringRef)persistentKey);
    }
    BOOL ok = commit(preferences) && apply(preferences);
    CFRelease(preferences); dlclose(framework);
    return ok ? 0 : 2;
}

static int SetHIP(BOOL enabled) {
    return SetThermalPreference(S("hipOverride"), @(enabled), S("hipPersistentlyEnabled"), YES);
}

static int SetSimulatedHIP(BOOL enabled) {
    return SetThermalPreference(S("simulateHip"), @(enabled), nil, NO);
}

static int SetLockedHIP(BOOL enabled) {
    if (enabled) {
        int first=SetThermalPreference(S("hipOverride"), @YES, S("hipPersistentlyEnabled"), YES);
        int second=SetThermalPreference(S("simulateHip"), @YES, nil, NO);
        return first ? first : second;
    }
    int first=SetThermalPreference(S("hipOverride"), nil, S("hipPersistentlyEnabled"), NO);
    int second=SetThermalPreference(S("simulateHip"), nil, nil, NO);
    return first ? first : second;
}

static int SetSunlightAutomatic(void) {
    return SetThermalPreference(S("sunlightOverride"), nil, S("sunlightOverridePersistentlyEnabled"), NO);
}

static int SetSunlightOverride(BOOL enabled) {
    return SetThermalPreference(S("sunlightOverride"), @(enabled), S("sunlightOverridePersistentlyEnabled"), YES);
}

static int ResetThermalLevels(void) {
    int pressure = CPUthermalForceNominalPressure();
    CPUthermalForceNormalNotifLevel();
    return pressure < 0 ? 1 : 0;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && argv[1]) {
            NSString *command = [NSString stringWithUTF8String:argv[1]];
            if ([command isEqualToString:S("userspace-reboot")]) return rebootUserspace();
            if ([command isEqualToString:S("restore-fullpower")]) return restoreFullPower();
            if ([command isEqualToString:S("thermal-reset")]) return ResetThermalLevels();
            if ([command isEqualToString:S("hip-enable")] && argc > 2) return SetHIP(atoi(argv[2]) != 0);
            if ([command isEqualToString:S("hip-simulate")] && argc > 2) return SetSimulatedHIP(atoi(argv[2]) != 0);
            if ([command isEqualToString:S("hip-lock")] && argc > 2) return SetLockedHIP(atoi(argv[2]) != 0);
            if ([command isEqualToString:S("sunlight-auto")]) return SetSunlightAutomatic();
            if ([command isEqualToString:S("sunlight-override")] && argc > 2) return SetSunlightOverride(atoi(argv[2]) != 0);
            return 64;
        }
        printf("CPUthermalTool commands:\n");
        printf("  userspace-reboot\n");
        printf("  restore-fullpower\n");
        return 0;
    }
}
