// JadeLocalization.m
// Shared localization helper for Jade resources

#import "JadeLocalization.h"
#import <rootless.h>

NSString *JadeLocalizedString(NSString *key) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *bundlePaths = @[
            ROOT_PATH_NS(@"/Library/Application Support/Jade/Jade.bundle"),
            ROOT_PATH_NS(@"/Library/Application Support/Jade/JadeLocalization.bundle"),
            ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries/Jade.bundle"),
            ROOT_PATH_NS(@"/Library/MobileSubstrate/DynamicLibraries/JadeLocalization.bundle"),
        ];

        for (NSString *path in bundlePaths) {
            NSBundle *candidate = [NSBundle bundleWithPath:path];
            if (candidate) {
                bundle = candidate;
                break;
            }
        }
    });

    NSString *localized = [bundle localizedStringForKey:key value:nil table:nil];
    if (localized.length == 0 || [localized isEqualToString:key]) {
        localized = [[NSBundle mainBundle] localizedStringForKey:key value:key table:nil];
    }
    return localized ?: key;
}
