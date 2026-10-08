#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSArray *(*OriginalSpecifiers)(id, SEL);
static BOOL Installed = NO;

static NSString *SpecifierName(id specifier) {
    if (![specifier respondsToSelector:@selector(name)]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(specifier, @selector(name));
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSArray *FilteredSpecifiers(id self, SEL command) {
    NSArray *source = OriginalSpecifiers(self, command);
    if (![source isKindOfClass:[NSMutableArray class]]) return source;
    Ivar cache = class_getInstanceVariable([self class], "_specifiers");
    if (!cache || object_getIvar(self, cache) != source) return source;
    NSMutableIndexSet *removed = [NSMutableIndexSet indexSet];
    // Restrict removal to the exact About group with all three known links.
    for (NSUInteger i = 0; i + 3 < [source count]; i++) {
        if (![SpecifierName(source[i]) isEqualToString:@"关于我们"]) continue;
        if ([SpecifierName(source[i + 1]) isEqualToString:@"Sileo 越狱源"] &&
            [SpecifierName(source[i + 2]) isEqualToString:@"TG 分享频道"] &&
            [SpecifierName(source[i + 3]) isEqualToString:@"QQ 交流群组"]) {
            [removed addIndexesInRange:NSMakeRange(i, 4)];
        }
    }
    if ([removed count] == 0) return source;
    // Preserve the original array identity and ownership. In particular,
    // object_setIvar may release a strong ivar's previous value itself;
    // the 1.0.0 explicit release could then over-release that array.
    // Snapper4 already owns a mutable _specifiers cache, so remove in place.
    [(NSMutableArray *)source removeObjectsAtIndexes:removed];
    return source;
}

static void Install(void) {
    if (Installed) return;
    Class target = objc_getClass("Snapper4RootListController");
    if (!target) return;
    NSBundle *bundle = [NSBundle bundleForClass:target];
    if (![[bundle bundleIdentifier] isEqualToString:@"com.axs.snapper4.prefs"]) return;
    if (![target instancesRespondToSelector:@selector(specifiers)]) return;
    MSHookMessageEx(target, @selector(specifiers), (IMP)FilteredSpecifiers,
                   (IMP *)&OriginalSpecifiers);
    Installed = YES;
}

__attribute__((constructor)) static void Initialize(void) {
    @autoreleasepool {
        [[NSNotificationCenter defaultCenter] addObserverForName:NSBundleDidLoadNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                (void)note;
                Install();
            }];
        Install();
    }
}
