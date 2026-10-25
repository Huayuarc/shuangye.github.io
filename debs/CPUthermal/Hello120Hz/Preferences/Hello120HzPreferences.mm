#import <Preferences/PSViewController.h>
#import "H120SettingsController.h"

@interface hello120hzPreRootListController : PSViewController
@property(nonatomic, strong) H120SettingsController *settingsController;
@end

@implementation hello120hzPreRootListController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Hello 120Hz";
    self.settingsController = [H120SettingsController new];
    self.settingsController.navigationOwner = self;
    [self addChildViewController:self.settingsController];
    self.settingsController.view.frame = self.view.bounds;
    self.settingsController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.settingsController.view];
    [self.settingsController didMoveToParentViewController:self];
}
@end

@interface LBPreRootListController : hello120hzPreRootListController @end
@implementation LBPreRootListController @end

@interface Mode3Controller : PSViewController
@property(nonatomic, strong) H120ExclusionsController *exclusionsController;
@end

@implementation Mode3Controller
- (void)viewDidLoad {
    [super viewDidLoad];
    self.exclusionsController = [H120ExclusionsController new];
    self.exclusionsController.navigationOwner = self;
    [self addChildViewController:self.exclusionsController];
    self.exclusionsController.view.frame = self.view.bounds;
    self.exclusionsController.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.exclusionsController.view];
    [self.exclusionsController didMoveToParentViewController:self];
}
@end
