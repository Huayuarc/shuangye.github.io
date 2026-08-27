#import <Preferences/PSListController.h>
#import <CPUthermalPaths.h>

@interface FRootListController : PSListController
@end

@implementation FRootListController
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:S("Root") target:self];
    return _specifiers;
}
@end
