#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface AmberSettingsController : PSListController
@end

@implementation AmberSettingsController
- (NSArray *)specifiers {
    if (!_specifiers)
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
@end
