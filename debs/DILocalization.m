#import "DILocalization.h"

static NSString *DIResourcePath(void) {
#ifdef THEOS_PACKAGE_INSTALL_PREFIX
    return @THEOS_PACKAGE_INSTALL_PREFIX "/Library/PreferenceLoader/Preferences";
#else
    return @"/Library/PreferenceLoader/Preferences";
#endif
}

NSString *DILocalizedString(NSString *key) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundle = [NSBundle bundleWithPath:DIResourcePath()];
    });

    NSString *value = bundle ? [bundle localizedStringForKey:key value:key table:@"DynamicIslandTweak"] : key;
    return value ?: key;
}
