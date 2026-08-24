#import "PMOriginal.h"

@interface PMPreferencesRootController : PSListController @end
@implementation PMPreferencesRootController
- (NSArray *)specifiers { if (!_specifiers) _specifiers=[[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy]; return _specifiers; }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"图片视频模块"; }
@end

@interface PMModule1PrefsController : PMOriginalListController @end
@implementation PMModule1PrefsController
- (instancetype)init { return [super initWithIdentifier:@"com.4nni3.picturemodule_1"]; }
@end
@interface PMModule2PrefsController : PMOriginalListController @end
@implementation PMModule2PrefsController
- (instancetype)init { return [super initWithIdentifier:@"com.4nni3.picturemodule_2"]; }
@end
@interface PMModule3PrefsController : PMOriginalListController @end
@implementation PMModule3PrefsController
- (instancetype)init { return [super initWithIdentifier:@"com.4nni3.picturemodule_3"]; }
@end
@interface PMModule4PrefsController : PMOriginalListController @end
@implementation PMModule4PrefsController
- (instancetype)init { return [super initWithIdentifier:@"com.4nni3.picturemodule_4"]; }
@end
@interface PMModule5PrefsController : PMOriginalListController @end
@implementation PMModule5PrefsController
- (instancetype)init { return [super initWithIdentifier:@"com.4nni3.picturemodule_5"]; }
@end
