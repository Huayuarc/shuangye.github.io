#ifndef CPUTHERMAL_THERMAL_PREFS_H
#define CPUTHERMAL_THERMAL_PREFS_H

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <CPUthermalPaths.h>

#if !defined(_SCPREFERENCES_H)
#define _SCPREFERENCES_H

enum {
    kSCStatusOK,
    kSCStatusFailed = 1001,
    kSCStatusStale  = 3005,
};

typedef const struct __SCPreferences *SCPreferencesRef;

__BEGIN_DECLS
SCPreferencesRef SCPreferencesCreate(CFAllocatorRef allocator, CFStringRef name, CFStringRef prefsID);
CFPropertyListRef SCPreferencesGetValue(SCPreferencesRef prefs, CFStringRef key);
Boolean SCPreferencesSetValue(SCPreferencesRef prefs, CFStringRef key, CFPropertyListRef value);
Boolean SCPreferencesRemoveValue(SCPreferencesRef prefs, CFStringRef key);
void SCPreferencesSynchronize(SCPreferencesRef prefs);
Boolean SCPreferencesApplyChanges(SCPreferencesRef prefs);
Boolean SCPreferencesCommitChanges(SCPreferencesRef prefs);
int SCError(void);
const char *SCErrorString(int status);
__END_DECLS

#endif

static inline CFStringRef CPUthermalCreateCFString(const char *string) {
    return string ? CFStringCreateWithCString(kCFAllocatorDefault, string, kCFStringEncodingUTF8) : NULL;
}

static inline SCPreferencesRef CPUthermalCreateOSThermalPrefs(void) {
    CFStringRef name = CPUthermalCreateCFString("CPUthermal");
    CFStringRef prefsID = CPUthermalCreateCFString("OSThermalStatus.plist");
    SCPreferencesRef prefs = SCPreferencesCreate(kCFAllocatorDefault, name, prefsID);
    if (name) CFRelease(name);
    if (prefsID) CFRelease(prefsID);
    return prefs;
}

static inline int CPUthermalSaveOSThermalPrefs(SCPreferencesRef prefs) {
    if (!prefs) return kSCStatusFailed;
    if (!SCPreferencesCommitChanges(prefs)) {
        int status = SCError();
        return status == kSCStatusOK ? kSCStatusFailed : status;
    }
    SCPreferencesApplyChanges(prefs);
    SCPreferencesSynchronize(prefs);
    return kSCStatusOK;
}

static inline BOOL CPUthermalSetOSThermalBool(SCPreferencesRef prefs, const char *key, BOOL enabled) {
    if (!prefs || !key) return NO;
    CFStringRef cfKey = CPUthermalCreateCFString(key);
    if (!cfKey) return NO;
    BOOL ok = SCPreferencesSetValue(prefs, cfKey, enabled ? kCFBooleanTrue : kCFBooleanFalse);
    CFRelease(cfKey);
    return ok;
}

static inline void CPUthermalRemoveOSThermalKey(SCPreferencesRef prefs, const char *key) {
    if (!prefs || !key) return;
    CFStringRef cfKey = CPUthermalCreateCFString(key);
    if (!cfKey) return;
    SCPreferencesRemoveValue(prefs, cfKey);
    CFRelease(cfKey);
}

static inline int CPUthermalApplyManagedThermalStatusOverrides(BOOL manageHotInPocket,
                                                              BOOL disableHotInPocket,
                                                              BOOL manageSunlightExposure,
                                                              BOOL lockSunlightExposure) {
    if (!manageHotInPocket && !manageSunlightExposure) return kSCStatusOK;

    SCPreferencesRef prefs = CPUthermalCreateOSThermalPrefs();
    if (!prefs) return kSCStatusFailed;

    BOOL ok = YES;
    if (manageHotInPocket) {
        if (disableHotInPocket) {
            ok = CPUthermalSetOSThermalBool(prefs, "simulateHip", NO) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "hipOverride", NO) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "hipPersistentlyEnabled", YES) && ok;
        } else {
            CPUthermalRemoveOSThermalKey(prefs, "simulateHip");
            CPUthermalRemoveOSThermalKey(prefs, "hipOverride");
            CPUthermalRemoveOSThermalKey(prefs, "hipPersistentlyEnabled");
        }
    }

    if (manageSunlightExposure) {
        if (lockSunlightExposure) {
            ok = CPUthermalSetOSThermalBool(prefs, "sunlightOverride", YES) && ok;
            ok = CPUthermalSetOSThermalBool(prefs, "sunlightOverridePersistentlyEnabled", YES) && ok;
        } else {
            CPUthermalRemoveOSThermalKey(prefs, "sunlightOverride");
            CPUthermalRemoveOSThermalKey(prefs, "sunlightOverridePersistentlyEnabled");
        }
    }

    int result = ok ? CPUthermalSaveOSThermalPrefs(prefs) : kSCStatusFailed;
    CFRelease(prefs);
    return result;
}

static inline BOOL CPUthermalPrefsContainKey(NSDictionary *prefs, const char *key) {
    if (!prefs || !key) return NO;
    return [prefs objectForKey:S(key)] != nil;
}

static inline BOOL CPUthermalBoolPref(NSDictionary *prefs, const char *key, BOOL defaultValue) {
    if (!prefs || !key) return defaultValue;
    id value = [prefs objectForKey:S(key)];
    return value ? [value boolValue] : defaultValue;
}

static inline int CPUthermalApplyThermalStatusOverridesFromPrefs(NSDictionary *prefs) {
    BOOL enabled = CPUthermalBoolPref(prefs, "enabled", NO);
    BOOL manageHotInPocket = CPUthermalPrefsContainKey(prefs, kCPUthermalDisableHotInPocketKeyC);
    BOOL manageSunlightExposure = CPUthermalPrefsContainKey(prefs, kCPUthermalLockSunlightExposureKeyC);
    BOOL disableHotInPocket = enabled && CPUthermalBoolPref(prefs, kCPUthermalDisableHotInPocketKeyC, NO);
    BOOL lockSunlightExposure = enabled && CPUthermalBoolPref(prefs, kCPUthermalLockSunlightExposureKeyC, NO);

    return CPUthermalApplyManagedThermalStatusOverrides(manageHotInPocket,
                                                       disableHotInPocket,
                                                       manageSunlightExposure,
                                                       lockSunlightExposure);
}

#endif
