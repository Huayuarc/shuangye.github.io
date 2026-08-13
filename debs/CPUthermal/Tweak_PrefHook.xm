#import <Foundation/Foundation.h>
#import <substrate.h>
#import <CPUthermalPaths.h>
#import <objc/runtime.h>
#import <syslog.h>
#import <ctype.h>
#import <stdlib.h>
#import <string.h>

typedef NS_ENUM(NSUInteger, CPUthermalHookKind) {
    CPUthermalHookKindSuppressObject,
    CPUthermalHookKindEmptyArray,
    CPUthermalHookKindFilterSpecifiers,
    CPUthermalHookKindMaximumCapacityObject,
};

typedef struct {
    Class targetClass;
    SEL selector;
    IMP original;
    CPUthermalHookKind kind;
} CPUthermalHookRecord;

static BOOL gEnabled = NO;
static BOOL gSimulateMaximumCapacity = NO;
static CFStringRef gNotifCFName = NULL;
static CPUthermalHookRecord gHookRecords[24];
static NSUInteger gHookRecordCount = 0;

typedef struct {
    Class targetClass;
    SEL selector;
    IMP original;
    char returnType;
} CPUthermalCapacityHookRecord;
static CPUthermalCapacityHookRecord gCapacityHooks[16];
static NSUInteger gCapacityHookCount = 0;

static NSDictionary *readPrefsDictionary(void) {
    return CPUthermalReadPrefs();
}

static void loadPrefs(void) {
    @autoreleasepool {
        NSDictionary *preferences = readPrefsDictionary();
        if (!preferences) {
            gEnabled = NO;
            gSimulateMaximumCapacity = NO;
            return;
        }

        id suppressValue = [preferences objectForKey:S("suppressBatteryServiceWarnings")];
        id capacityValue = [preferences objectForKey:S("simulateMaximumCapacity")];
        gEnabled = suppressValue ? [suppressValue boolValue] : NO;
        gSimulateMaximumCapacity = capacityValue ? [capacityValue boolValue] : NO;
    }
}

static BOOL cStringContainsInsensitive(const char *value, const char *token) {
    if (!value || !token || !token[0]) {
        return NO;
    }

    size_t tokenLength = strlen(token);
    for (const char *cursor = value; *cursor; cursor++) {
        size_t index = 0;
        while (index < tokenLength && cursor[index] &&
               tolower((unsigned char)cursor[index]) == tolower((unsigned char)token[index])) {
            index++;
        }
        if (index == tokenLength) {
            return YES;
        }
    }

    return NO;
}

static BOOL cStringEndsWithInsensitive(const char *value, const char *suffix) {
    if (!value || !suffix) {
        return NO;
    }

    size_t valueLength = strlen(value);
    size_t suffixLength = strlen(suffix);
    if (suffixLength > valueLength) {
        return NO;
    }

    return strncasecmp(value + valueLength - suffixLength, suffix, suffixLength) == 0;
}

static id callObjectNoArgument(id object, const char *selectorName) {
    if (!object || !selectorName) {
        return nil;
    }

    SEL selector = sel_registerName(selectorName);
    if (![object respondsToSelector:selector]) {
        return nil;
    }

    IMP implementation = [object methodForSelector:selector];
    return implementation ? ((id (*)(id, SEL))implementation)(object, selector) : nil;
}

static id callObjectWithObject(id object, const char *selectorName, id argument) {
    if (!object || !selectorName) return nil;
    SEL selector = sel_registerName(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    IMP implementation = [object methodForSelector:selector];
    return implementation ? ((id (*)(id, SEL, id))implementation)(object, selector, argument) : nil;
}

static void setSpecifierProperty(id specifier, id value, NSString *key) {
    if (!specifier || !key) return;
    SEL selector = sel_registerName("setProperty:forKey:");
    if (![specifier respondsToSelector:selector]) return;
    IMP implementation = [specifier methodForSelector:selector];
    if (implementation) ((void (*)(id, SEL, id, id))implementation)(specifier, selector, value, key);
}

static NSString *inspectionStringForValue(id value) {
    if (!value) {
        return nil;
    }

    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }

    if ([value isKindOfClass:[NSURL class]]) {
        return [(NSURL *)value absoluteString];
    }

    Class metaClass = object_getClass(value);
    if (metaClass && class_isMetaClass(metaClass)) {
        return NSStringFromClass((Class)value);
    }

    return nil;
}

static BOOL stringContainsBatteryWarningToken(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) {
        return NO;
    }

    static const char *tokens[] = {
        "importantbatterymessage",
        "important_battery",
        "important battery message",
        "batteryservicesuggestion",
        "battery_service",
        "battery service",
        "servicerecommended",
        "service_recommended",
        "service recommended",
        "nongenuinebattery",
        "nongenuine_battery",
        "non-genuine battery",
        "batteryhealthunknown",
        "battery_health_unknown",
        "battery health unknown",
        "battery not trusted",
        "untrusted battery",
        "recalibrat",
        "plfollowupheadercell",
        "plfollowupsecondaryheadercell",
        "significantly degraded",
        "unable to verify",
        "unable to determine battery health",
        "重要电池信息",
        "电池健康状况显著下降",
        "无法验证",
        "无法确定电池健康状况",
        "重新校准",
        "建议维修",
    };

    NSString *lowercaseValue = [value lowercaseString];
    for (NSUInteger index = 0; index < sizeof(tokens) / sizeof(tokens[0]); index++) {
        if ([lowercaseValue rangeOfString:S(tokens[index])].location != NSNotFound) {
            return YES;
        }
    }

    return NO;
}

static BOOL valueContainsBatteryWarning(id value) {
    NSString *inspectionString = inspectionStringForValue(value);
    if (stringContainsBatteryWarningToken(inspectionString)) {
        return YES;
    }

    if ([value isKindOfClass:[NSDictionary class]]) {
        for (id key in (NSDictionary *)value) {
            if (valueContainsBatteryWarning(key) || valueContainsBatteryWarning([(NSDictionary *)value objectForKey:key])) {
                return YES;
            }
        }
    }

    return NO;
}

static BOOL specifierIsMaximumCapacity(id specifier) {
    if (!specifier) return NO;
    NSMutableArray *values = [NSMutableArray array];
    id identifier = callObjectNoArgument(specifier, "identifier");
    id name = callObjectNoArgument(specifier, "name");
    if (identifier) [values addObject:identifier];
    if (name) [values addObject:name];
    static const char *keys[] = {"id", "identifier", "name", "label", "title"};
    for (NSUInteger i = 0; i < sizeof(keys)/sizeof(keys[0]); i++) {
        id value = callObjectWithObject(specifier, "propertyForKey:", S(keys[i]));
        if (value) [values addObject:value];
    }
    for (id value in values) {
        NSString *text = inspectionStringForValue(value);
        if (![text isKindOfClass:[NSString class]]) continue;
        NSString *lower = [text lowercaseString];
        if ([lower containsString:S("maximumcapacity")] ||
            [lower containsString:S("maximum capacity")] ||
            [lower containsString:S("batteryhealthcapacity")] ||
            [lower containsString:S("最大容量")]) return YES;
    }
    return NO;
}

static void patchMaximumCapacitySpecifier(id specifier) {
    if (!gSimulateMaximumCapacity || !specifierIsMaximumCapacity(specifier)) return;
    setSpecifierProperty(specifier, [NSNumber numberWithInt:100], S("value"));
    setSpecifierProperty(specifier, [NSNumber numberWithInt:100], S("percent"));
    setSpecifierProperty(specifier, S("100%"), S("detailText"));
    setSpecifierProperty(specifier, S("100%"), S("valueText"));
}

static BOOL specifierContainsBatteryWarning(id specifier) {
    if (!specifier) {
        return NO;
    }

    if (stringContainsBatteryWarningToken(NSStringFromClass([specifier class]))) {
        return YES;
    }

    id identifier = callObjectNoArgument(specifier, "identifier");
    id name = callObjectNoArgument(specifier, "name");
    if (valueContainsBatteryWarning(identifier) || valueContainsBatteryWarning(name)) {
        return YES;
    }

    static const char *propertyKeys[] = {
        "id",
        "identifier",
        "name",
        "label",
        "title",
        "text",
        "detailText",
        "footerText",
        "headerText",
        "cellClass",
        "headerCellClass",
        "footerCellClass",
        "url",
        "URL",
        "link",
    };

    for (NSUInteger index = 0; index < sizeof(propertyKeys) / sizeof(propertyKeys[0]); index++) {
        id value = callObjectWithObject(specifier, "propertyForKey:", S(propertyKeys[index]));
        if (valueContainsBatteryWarning(value)) {
            return YES;
        }
    }

    return NO;
}

static id filteredBatteryHealthSpecifiers(id result) {
    if (![result isKindOfClass:[NSArray class]]) {
        return result;
    }

    NSArray *specifiers = (NSArray *)result;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:[specifiers count]];
    BOOL removedWarning = NO;

    for (id specifier in specifiers) {
        patchMaximumCapacitySpecifier(specifier);
        if (gEnabled && specifierContainsBatteryWarning(specifier)) {
            removedWarning = YES;
            continue;
        }
        [filtered addObject:specifier];
    }

    if (removedWarning) {
        syslog(LOG_NOTICE, "[CPUthermalPrefHook] removed Important Battery Information specifiers");
        return filtered;
    }

    return result;
}

static id invokeObjectHook(NSUInteger index, id self, SEL selector) {
    if (index >= gHookRecordCount) {
        return nil;
    }

    CPUthermalHookRecord *record = &gHookRecords[index];
    IMP original = record->original;

    if (record->kind == CPUthermalHookKindFilterSpecifiers) {
        id result = original ? ((id (*)(id, SEL))original)(self, selector) : nil;
        return (gEnabled || gSimulateMaximumCapacity) ? filteredBatteryHealthSpecifiers(result) : result;
    }
    if (record->kind == CPUthermalHookKindMaximumCapacityObject) {
        id result = original ? ((id (*)(id, SEL))original)(self, selector) : nil;
        if (!gSimulateMaximumCapacity) return result;
        if ([result isKindOfClass:[NSNumber class]] && [(NSNumber *)result doubleValue] > 0.0 && [(NSNumber *)result doubleValue] <= 1.0) {
            return [NSNumber numberWithDouble:1.0];
        }
        return [NSNumber numberWithInt:100];
    }

    if (gEnabled) {
        if (record->kind == CPUthermalHookKindEmptyArray) {
            return [NSArray array];
        }
        return nil;
    }

    return original ? ((id (*)(id, SEL))original)(self, selector) : nil;
}

#define DEFINE_OBJECT_HOOK(index) \
    static id objectHook##index(id self, SEL selector) { \
        return invokeObjectHook(index, self, selector); \
    }

DEFINE_OBJECT_HOOK(0)
DEFINE_OBJECT_HOOK(1)
DEFINE_OBJECT_HOOK(2)
DEFINE_OBJECT_HOOK(3)
DEFINE_OBJECT_HOOK(4)
DEFINE_OBJECT_HOOK(5)
DEFINE_OBJECT_HOOK(6)
DEFINE_OBJECT_HOOK(7)
DEFINE_OBJECT_HOOK(8)
DEFINE_OBJECT_HOOK(9)
DEFINE_OBJECT_HOOK(10)
DEFINE_OBJECT_HOOK(11)
DEFINE_OBJECT_HOOK(12)
DEFINE_OBJECT_HOOK(13)
DEFINE_OBJECT_HOOK(14)
DEFINE_OBJECT_HOOK(15)
DEFINE_OBJECT_HOOK(16)
DEFINE_OBJECT_HOOK(17)
DEFINE_OBJECT_HOOK(18)
DEFINE_OBJECT_HOOK(19)
DEFINE_OBJECT_HOOK(20)
DEFINE_OBJECT_HOOK(21)
DEFINE_OBJECT_HOOK(22)
DEFINE_OBJECT_HOOK(23)

static IMP gObjectHookImplementations[] = {
    (IMP)objectHook0,
    (IMP)objectHook1,
    (IMP)objectHook2,
    (IMP)objectHook3,
    (IMP)objectHook4,
    (IMP)objectHook5,
    (IMP)objectHook6,
    (IMP)objectHook7,
    (IMP)objectHook8,
    (IMP)objectHook9,
    (IMP)objectHook10,
    (IMP)objectHook11,
    (IMP)objectHook12,
    (IMP)objectHook13,
    (IMP)objectHook14,
    (IMP)objectHook15,
    (IMP)objectHook16,
    (IMP)objectHook17,
    (IMP)objectHook18,
    (IMP)objectHook19,
    (IMP)objectHook20,
    (IMP)objectHook21,
    (IMP)objectHook22,
    (IMP)objectHook23,
};

static NSUInteger capacityHookIndex(Class cls, SEL selector) {
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        for (NSUInteger i = 0; i < gCapacityHookCount; i++) {
            if (gCapacityHooks[i].targetClass == current && gCapacityHooks[i].selector == selector) return i;
        }
    }
    return NSNotFound;
}

static long long capacityIntegerHook(id self, SEL selector) {
    NSUInteger i = capacityHookIndex([self class], selector);
    if (i == NSNotFound) return 0;
    IMP original = gCapacityHooks[i].original;
    long long value = original ? ((long long (*)(id, SEL))original)(self, selector) : 0;
    return gSimulateMaximumCapacity ? 100 : value;
}

static float capacityFloatHook(id self, SEL selector) {
    NSUInteger i = capacityHookIndex([self class], selector);
    if (i == NSNotFound) return 0.0f;
    IMP original = gCapacityHooks[i].original;
    float value = original ? ((float (*)(id, SEL))original)(self, selector) : 0.0f;
    return gSimulateMaximumCapacity ? ((value > 0.0f && value <= 1.0f) ? 1.0f : 100.0f) : value;
}

static double capacityDoubleHook(id self, SEL selector) {
    NSUInteger i = capacityHookIndex([self class], selector);
    if (i == NSNotFound) return 0.0;
    IMP original = gCapacityHooks[i].original;
    double value = original ? ((double (*)(id, SEL))original)(self, selector) : 0.0;
    return gSimulateMaximumCapacity ? ((value > 0.0 && value <= 1.0) ? 1.0 : 100.0) : value;
}

static Method copyOwnInstanceMethod(Class targetClass, SEL selector) {
    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(targetClass, &methodCount);
    Method result = NULL;

    for (unsigned int index = 0; index < methodCount; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }

    free(methods);
    return result;
}

static BOOL methodReturnsObjectWithoutArguments(Method method) {
    if (!method || method_getNumberOfArguments(method) != 2) {
        return NO;
    }

    const char *typeEncoding = method_getTypeEncoding(method);
    if (!typeEncoding) {
        return NO;
    }

    while (*typeEncoding && strchr("rnNoORV", *typeEncoding)) {
        typeEncoding++;
    }

    return *typeEncoding == '@';
}

static BOOL hookAlreadyInstalled(Class targetClass, SEL selector) {
    for (NSUInteger index = 0; index < gHookRecordCount; index++) {
        if (gHookRecords[index].targetClass == targetClass && gHookRecords[index].selector == selector) {
            return YES;
        }
    }
    return NO;
}

static BOOL installObjectHook(Class targetClass, SEL selector, CPUthermalHookKind kind) {
    if (!targetClass || !selector || hookAlreadyInstalled(targetClass, selector)) {
        return NO;
    }

    Method method = copyOwnInstanceMethod(targetClass, selector);
    if (!methodReturnsObjectWithoutArguments(method)) {
        return NO;
    }

    NSUInteger capacity = sizeof(gHookRecords) / sizeof(gHookRecords[0]);
    if (gHookRecordCount >= capacity) {
        syslog(LOG_ERR, "[CPUthermalPrefHook] hook record capacity reached");
        return NO;
    }

    NSUInteger index = gHookRecordCount++;
    gHookRecords[index].targetClass = targetClass;
    gHookRecords[index].selector = selector;
    gHookRecords[index].kind = kind;
    gHookRecords[index].original = NULL;

    MSHookMessageEx(
        targetClass,
        selector,
        gObjectHookImplementations[index],
        &gHookRecords[index].original
    );

    syslog(
        LOG_NOTICE,
        "[CPUthermalPrefHook] hooked %s.%s",
        class_getName(targetClass),
        sel_getName(selector)
    );
    return YES;
}

static BOOL installCapacityHook(Class targetClass, Method method) {
    if (!targetClass || !method || method_getNumberOfArguments(method) != 2) return NO;
    SEL selector = method_getName(method);
    if (capacityHookIndex(targetClass, selector) != NSNotFound) return NO;
    if (gCapacityHookCount >= sizeof(gCapacityHooks) / sizeof(gCapacityHooks[0])) return NO;

    char returnType[32] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    const char *cursor = returnType;
    while (*cursor && strchr("rnNoORV", *cursor)) cursor++;
    char type = *cursor;
    IMP replacement = NULL;
    if (type == '@') {
        return installObjectHook(targetClass, selector, CPUthermalHookKindMaximumCapacityObject);
    } else if (type == 'f') {
        replacement = (IMP)capacityFloatHook;
    } else if (type == 'd') {
        replacement = (IMP)capacityDoubleHook;
    } else if (strchr("cCsSiIlLqQB", type)) {
        replacement = (IMP)capacityIntegerHook;
    } else {
        return NO;
    }

    NSUInteger index = gCapacityHookCount++;
    gCapacityHooks[index].targetClass = targetClass;
    gCapacityHooks[index].selector = selector;
    gCapacityHooks[index].returnType = type;
    gCapacityHooks[index].original = NULL;
    MSHookMessageEx(targetClass, selector, replacement, &gCapacityHooks[index].original);
    syslog(LOG_NOTICE, "[CPUthermalPrefHook] hooked maximum capacity %s.%s type=%c",
           class_getName(targetClass), sel_getName(selector), type);
    return YES;
}

static BOOL isBatteryHealthControllerClass(Class targetClass) {
    const char *className = class_getName(targetClass);
    if (!className) {
        return NO;
    }

    if (cStringContainsInsensitive(className, "batteryhealth")) {
        return YES;
    }

    return cStringContainsInsensitive(className, "battery") &&
           cStringContainsInsensitive(className, "health") &&
           cStringContainsInsensitive(className, "controller");
}

static BOOL isMaximumCapacitySelector(const char *selectorName) {
    if (!selectorName || strchr(selectorName, ':')) return NO;
    if (cStringContainsInsensitive(selectorName, "raw") ||
        cStringContainsInsensitive(selectorName, "design") ||
        cStringContainsInsensitive(selectorName, "nominal") ||
        cStringContainsInsensitive(selectorName, "current") ||
        cStringContainsInsensitive(selectorName, "remaining") ||
        cStringContainsInsensitive(selectorName, "charge") ||
        cStringContainsInsensitive(selectorName, "performance") ||
        cStringContainsInsensitive(selectorName, "peak") ||
        cStringContainsInsensitive(selectorName, "cycle")) return NO;
    return cStringContainsInsensitive(selectorName, "maximumcapacity") ||
           cStringContainsInsensitive(selectorName, "maxcapacity") ||
           cStringContainsInsensitive(selectorName, "batteryhealthcapacity");
}

static BOOL isWarningSpecifierFactorySelector(const char *selectorName) {
    if (!selectorName || strchr(selectorName, ':') ||
        !cStringEndsWithInsensitive(selectorName, "specifiers")) {
        return NO;
    }

    if (strcasecmp(selectorName, "headerSpecifiers") == 0) {
        return YES;
    }

    return cStringContainsInsensitive(selectorName, "importantbattery") ||
           cStringContainsInsensitive(selectorName, "batteryservice") ||
           cStringContainsInsensitive(selectorName, "servicerecommend") ||
           cStringContainsInsensitive(selectorName, "nongenuine") ||
           cStringContainsInsensitive(selectorName, "recalibration") ||
           cStringContainsInsensitive(selectorName, "unknownheader") ||
           cStringContainsInsensitive(selectorName, "datacollectionnotice");
}

static BOOL isBatteryServiceSuggestionSelector(const char *selectorName) {
    if (!selectorName || strchr(selectorName, ':')) {
        return NO;
    }

    return strcasecmp(selectorName, "getBatteryServiceSuggestion") == 0 ||
           cStringContainsInsensitive(selectorName, "batteryservicesuggestion") ||
           cStringContainsInsensitive(selectorName, "servicebatterysuggestion");
}

static void installHooksForClass(Class targetClass) {
    const char *className = class_getName(targetClass);
    if (!className || !cStringContainsInsensitive(className, "battery")) {
        return;
    }

    BOOL batteryHealthController = isBatteryHealthControllerClass(targetClass);
    if (batteryHealthController) {
        installObjectHook(
            targetClass,
            sel_registerName("specifiers"),
            CPUthermalHookKindFilterSpecifiers
        );
    }

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(targetClass, &methodCount);
    for (unsigned int index = 0; index < methodCount; index++) {
        Method method = methods[index];
        SEL selector = method_getName(method);
        const char *selectorName = sel_getName(selector);

        if (batteryHealthController && isMaximumCapacitySelector(selectorName)) {
            installCapacityHook(targetClass, method);
        } else if (batteryHealthController && isWarningSpecifierFactorySelector(selectorName)) {
            installObjectHook(targetClass, selector, CPUthermalHookKindEmptyArray);
        } else if (isBatteryServiceSuggestionSelector(selectorName)) {
            installObjectHook(targetClass, selector, CPUthermalHookKindSuppressObject);
        }
    }
    free(methods);
}

static void installBatteryHooks(void) {
    @autoreleasepool {
        int classCount = objc_getClassList(NULL, 0);
        if (classCount <= 0) {
            return;
        }

        Class *classes = (Class *)calloc((size_t)classCount, sizeof(Class));
        if (!classes) {
            return;
        }

        int loadedClassCount = objc_getClassList(classes, classCount);
        int scanCount = loadedClassCount < classCount ? loadedClassCount : classCount;
        for (int index = 0; index < scanCount; index++) {
            installHooksForClass(classes[index]);
        }

        free(classes);
    }
}

static void onSettingsChanged(CFNotificationCenterRef center,
                              void *observer,
                              CFStringRef name,
                              const void *object,
                              CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    loadPrefs();
    installBatteryHooks();
    syslog(LOG_NOTICE, "[CPUthermalPrefHook] settings reloaded, warnings=%d maximumCapacity=%d", gEnabled, gSimulateMaximumCapacity);
}

static void onBundleDidLoad(CFNotificationCenterRef center,
                            void *observer,
                            CFStringRef name,
                            const void *object,
                            CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)userInfo;
    NSBundle *bundle = (__bridge NSBundle *)object;
    NSString *bundleIdentifier = [bundle bundleIdentifier];
    if (![bundleIdentifier isKindOfClass:[NSString class]]) {
        return;
    }

    if ([bundleIdentifier rangeOfString:S("battery") options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bundleIdentifier rangeOfString:S("powerui") options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [bundleIdentifier rangeOfString:S("preferences") options:NSCaseInsensitiveSearch].location != NSNotFound) {
        installBatteryHooks();
    }
}

%ctor {
    @autoreleasepool {
        loadPrefs();

        if (!gNotifCFName) {
            gNotifCFName = CFStringCreateWithCString(
                kCFAllocatorDefault,
                kCPUthermalSettingsChangedNotifC,
                kCFStringEncodingUTF8
            );
        }

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetLocalCenter(),
            NULL,
            onBundleDidLoad,
            (__bridge CFStringRef)NSBundleDidLoadNotification,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            onSettingsChanged,
            gNotifCFName,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        installBatteryHooks();
        syslog(LOG_NOTICE, "[CPUthermalPrefHook] loaded, warnings=%d maximumCapacity=%d", gEnabled, gSimulateMaximumCapacity);
    }
}
