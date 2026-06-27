#import "DILocalization.h"
#import <dlfcn.h>

static NSString *DIResolvedBundlePath(void) {
    NSString *relativePath = @"/Library/PreferenceBundles/LSILLSettings.bundle";
    char *(*jbrootFunction)(const char *) = (char *(*)(const char *))dlsym(RTLD_DEFAULT, "jbroot");
    if (jbrootFunction) {
        char *resolvedPath = jbrootFunction(relativePath.UTF8String);
        if (resolvedPath) {
            NSString *path = [NSString stringWithUTF8String:resolvedPath];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
        }
    }

    NSArray<NSString *> *paths = @[
        @"/var/jb/Library/PreferenceBundles/LSILLSettings.bundle",
        relativePath,
    ];
    for (NSString *path in paths) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return relativePath;
}

NSString *DILocalizedString(NSString *key) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundle = [NSBundle bundleWithPath:DIResolvedBundlePath()];
    });

    NSString *value = bundle ? [bundle localizedStringForKey:key value:key table:nil] : key;
    return value ?: key;
}
