// Dump CoreTelephony / CellularPlanManager method signatures (type encodings)
// used to hook them safely. Read only; changes nothing.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static void dumpClass(const char *clsName, const char *const *sels, int n)
{
    Class c = objc_getClass(clsName);
    if (!c) {
        printf("[%s] class not loaded\n", clsName);
        return;
    }
    printf("[%s]\n", clsName);
    for (int i = 0; i < n; i++) {
        SEL s = sel_registerName(sels[i]);
        Method m = class_getInstanceMethod(c, s);
        if (!m) {
            printf("  %-46s MISSING\n", sels[i]);
            continue;
        }
        printf("  %-46s ret=%-8s enc=%s\n", sels[i],
               method_copyReturnType(m), method_getTypeEncoding(m));
    }
    // also list every method whose name contains SIM/Status/Label/Equipment
    unsigned int count = 0;
    Method *list = class_copyMethodList(c, &count);
    printf("  -- %u own methods matching:\n", count);
    for (unsigned int i = 0; i < count; i++) {
        const char *nm = sel_getName(method_getName(list[i]));
        if (strstr(nm, "SIM") || strstr(nm, "Sim") || strstr(nm, "Status") ||
            strstr(nm, "Label") || strstr(nm, "Equipment") || strstr(nm, "Subscription")) {
            printf("  %-52s ret=%-8s enc=%s\n", nm,
                   method_copyReturnType(list[i]), method_getTypeEncoding(list[i]));
        }
    }
    free(list);
}

int main(void)
{
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/CellularPlanManager.framework/CellularPlanManager", RTLD_LAZY);

        printf("systemVersion=%s\n", [[[NSProcessInfo processInfo] operatingSystemVersionString] UTF8String]);

        static const char *a[] = {
            "getSIMStatus:error:", "copyLabel:error:", "copyMobileEquipmentInfo:",
            "copyMobileEquipmentInfo:error:", "getMobileEquipmentInfo:",
            "getSimStatus:error:", "getSubscriptionInfo:",
            "getCurrentDataSubscriptionContext:",
            "getActiveSubscriptions:", "setActiveSubscriptions:",
        };
        dumpClass("CoreTelephonyClient", a, sizeof(a) / sizeof(a[0]));

        static const char *b[] = {
            "sharedManager", "planItemsShouldUpdate:", "didSelectPlanItem:isEnable:",
            "planItems", "didSelectPlanItem:isEnable:completion:",
        };
        dumpClass("CTCellularPlanManager", b, sizeof(b) / sizeof(b[0]));

        Class ctx = objc_getClass("CTXPCServiceSubscriptionContext");
        printf("[CTXPCServiceSubscriptionContext]=%p\n", (void *)ctx);
        if (ctx) {
            static const char *c[] = { "contextWithSlot:", "slotID", "labelID", "uuid" };
            dumpClass("CTXPCServiceSubscriptionContext", c, sizeof(c) / sizeof(c[0]));
        }
        printf("[CCUIToggleModule]=%p\n", (void *)objc_getClass("CCUIToggleModule"));
        if (objc_getClass("CCUIToggleModule")) {
            static const char *d[] = { "iconGlyph", "isSelected", "setSelected:", "refreshState", "selectedColor", "onSelected", "toggle" };
            dumpClass("CCUIToggleModule", d, sizeof(d) / sizeof(d[0]));
        }
    }
    return 0;
}
