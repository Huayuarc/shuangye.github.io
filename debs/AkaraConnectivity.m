#import "AkaraConnectivity.h"

@implementation AkaraConnectivity

- (AkaraConnectivityModuleContentViewController *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [[AkaraConnectivityModuleContentViewController alloc] initWithModuleIdentifier:@"com.huayuarc.akara.connectivitymodule" options:nil];
    }
    return _contentViewController;
}

- (UIViewController<CCUIContentModuleBackgroundViewController> *)backgroundViewController {
    return _backgroundViewController;
}

- (NSURL *)moduleBundleURL {
    NSURL *bundleURL = [NSBundle bundleForClass:self.class].bundleURL;
    if (bundleURL) {
        return bundleURL;
    }
    return [NSURL fileURLWithPath:@"/var/jb/Library/ControlCenter/Bundles/AkaraConnectivity.bundle"];
}

- (void)setContentModuleContext:(id)context {
    if ([self.contentViewController respondsToSelector:@selector(setContentModuleContext:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.contentViewController performSelector:@selector(setContentModuleContext:) withObject:context];
#pragma clang diagnostic pop
    }
}

- (void)_updateAvailableModuleMetadata {
    [self.contentViewController updateNotExpandedConnectivityButtons];
}

@end
