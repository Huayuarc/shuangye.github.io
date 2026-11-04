// 只读诊断：用 CCSIMTool 自带的权限问 CommCenter 要 SIM 卡（plan item）列表。
// 不带参数只列；带 `<index> <0|1>` 才真的调用 didSelectPlanItem:isEnable:。
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

static id sendId(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    if (![obj respondsToSelector:s]) return [NSString stringWithFormat:@"<no %@>", sel];
    return ((id (*)(id, SEL))objc_msgSend)(obj, s);
}

static id sendIdIdBool(id obj, NSString *sel, id a, BOOL b) {
    SEL s = NSSelectorFromString(sel);
    if (![obj respondsToSelector:s]) return [NSString stringWithFormat:@"<no %@>", sel];
    return ((id (*)(id, SEL, id, BOOL))objc_msgSend)(obj, s, a, b);
}

static id sendIdBool(id obj, NSString *sel, BOOL b) {
    SEL s = NSSelectorFromString(sel);
    if (![obj respondsToSelector:s]) return [NSString stringWithFormat:@"<no %@>", sel];
    return ((id (*)(id, SEL, BOOL))objc_msgSend)(obj, s, b);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        void *fw = dlopen("/System/Library/PrivateFrameworks/CellularPlanManager.framework/CellularPlanManager", RTLD_LAZY);
        printf("framework=%s\n", fw ? "loaded" : dlerror());
        Class pm = objc_getClass("CTCellularPlanManager");
        printf("CTCellularPlanManager=%p\n", (void *)pm);
        if (!pm) return 2;

        id manager = ((id (*)(id, SEL))objc_msgSend)(pm, NSSelectorFromString(@"sharedManager"));
        printf("sharedManager=%p\n", (void *)manager);
        if (!manager) return 3;

        BOOL q = getenv("Q") ? atoi(getenv("Q")) : 1;
        NSArray *items = sendIdBool(manager, @"planItemsShouldUpdate:", q);
        printf("query=%d\n", q);
        printf("planItems=%s count=%lu\n",
               items ? class_getName(object_getClass(items)) : "nil",
               (unsigned long)[items count]);

        for (NSUInteger i = 0; i < [items count]; i++) {
            id item = items[i];
            printf("  [%lu] %s\n", (unsigned long)i, class_getName(object_getClass(item)));
            printf("        %s\n", [[item description] UTF8String]);
            for (NSString *sel in @[@"identifier", @"label", @"isSelected", @"isEnabled",
                                    @"isActive", @"isInstalled", @"type", @"slotID"]) {
                SEL s = NSSelectorFromString(sel);
                if (![item respondsToSelector:s]) continue;
                NSMethodSignature *sig = [item methodSignatureForSelector:s];
                if (sig.methodReturnLength == 0) continue;
                if (strcmp(sig.methodReturnType, "@") == 0) {
                    id v = ((id (*)(id, SEL))objc_msgSend)(item, s);
                    printf("        %-12s = %s\n", [sel UTF8String], [[v description] UTF8String]);
                } else if (strcmp(sig.methodReturnType, "B") == 0 || strcmp(sig.methodReturnType, "c") == 0
                           || strcmp(sig.methodReturnType, "i") == 0) {
                    int v = ((int (*)(id, SEL))objc_msgSend)(item, s);
                    printf("        %-12s = %d\n", [sel UTF8String], v);
                }
            }
        }

        if (argc >= 3) {
            NSInteger idx = [[NSString stringWithUTF8String:argv[1]] integerValue];
            BOOL enable = [[NSString stringWithUTF8String:argv[2]] integerValue] != 0;
            if (idx < 0 || (NSUInteger)idx >= [items count]) {
                printf("index out of range\n");
                return 4;
            }
            id item = items[idx];
            printf("calling didSelectPlanItem:%lu isEnable:%d ...\n", (unsigned long)idx, (int)enable);
            id r = sendIdIdBool(manager, @"didSelectPlanItem:isEnable:", item, enable);
            printf("result=%s\n", r ? [[r description] UTF8String] : "nil");
        }
    }
    return 0;
}
