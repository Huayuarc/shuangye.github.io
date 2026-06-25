//==============================================================================
// InsulationCCModuleViewController.m
// 逆向来源: com.be-huge.insulation v0.1.36
//==============================================================================

#import "InsulationCCModuleViewController.h"
#import "../Tweak/Insulation.h"

@interface InsulationCCModuleViewController ()

@property (nonatomic, strong) NSArray<CCUIMenuModuleItem *> *menuItems;

@end

@implementation InsulationCCModuleViewController

//==============================================================================
#pragma mark - Initialization
//==============================================================================

- (instancetype)init {
self = [super init];
if (self) {
_modeValues = @[kInsulationPowerModeOff, kInsulationPowerModeLowPower, kInsulationPowerModeFullPower];
_modeTitles = @[@"低功耗", @"解除温控"];
_modeSubtitles = @[@"", @"", @""];

// 读取当前设置的模式
NSString *currentMode = InsulationCurrentPowerModeString();
_selectedIndex = [_modeValues indexOfObject:currentMode];
if (_selectedIndex == NSNotFound) {
_selectedIndex = 0;
}
}
return self;
}

//==============================================================================
#pragma mark - UIViewController Lifecycle
//==============================================================================

- (void)viewDidLoad {
[super viewDidLoad];

// 设置标题
self.title = @"CPUthermal";

// 设置控制中心图标
UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
UIImage *glyphImage = [UIImage systemImageNamed:@"thermometer.sun.fill" withConfiguration:config];
[self setGlyphImage:glyphImage];
[self setSelectedGlyphColor:[UIColor systemOrangeColor]];

// 布局 UI
[self _setupView];
}

- (void)viewWillAppear:(BOOL)animated {
[super viewWillAppear:animated];

// 刷新选中状态
NSString *currentMode = InsulationCurrentPowerModeString();
NSInteger newIndex = [self.modeValues indexOfObject:currentMode];
if (newIndex != NSNotFound && newIndex != self.selectedIndex) {
self.selectedIndex = newIndex;
}
}

- (void)viewDidDisappear:(BOOL)animated {
[super viewDidDisappear:animated];
}

//==============================================================================
#pragma mark - CCUIContentModuleContentViewController
//==============================================================================

- (BOOL)shouldBeginTransitionToExpandedContentModule {
return YES;
}

- (void)willTransitionToExpandedContentMode:(BOOL)animated {
[super willTransitionToExpandedContentMode:animated];
// 展开时刷新菜单
[self _setupModeButtons];
}

- (BOOL)_toggleModuleExpanded {
// 切换展开/折叠状态
return YES;
}

//==============================================================================
#pragma mark - Setup
//==============================================================================

- (void)_setupView {
// 获取当前模式并计算选中索引
NSString *currentMode = InsulationCurrentPowerModeString();
self.selectedIndex = [self.modeValues indexOfObject:currentMode];
if (self.selectedIndex == NSNotFound) {
self.selectedIndex = 0;
}

// 设置菜单项
[self _setupModeButtons];

// 应用当前选中状态
[self setSelected:(self.selectedIndex == 0) ? NO : YES];
}

- (void)_setupModeButtons {
// 获取当前电源模式决定按钮颜色
BOOL isFullPower = InsulationFullPowerModeEnabled();
BOOL isLowPower = InsulationLowPowerModeEnabled();

NSMutableArray *items = [NSMutableArray array];
for (NSInteger i = 0; i < self.modeValues.count; i++) {
NSString *title = self.modeTitles[i];
NSString *subtitle = self.modeSubtitles[i];
BOOL isSelected = (i == self.selectedIndex);

CCUIMenuModuleItem *item = [[CCUIMenuModuleItem alloc] init];
item.title = title;

// 根据模式设置选中状态和颜色
if (isSelected) {
if (isFullPower) {
[item setSelectedGlyphColor:[UIColor systemOrangeColor]];
} else if (isLowPower) {
[item setSelectedGlyphColor:[UIColor systemGreenColor]];
} else {
[item setSelectedGlyphColor:[UIColor systemBlueColor]];
}
}

[items addObject:item];
}

self.menuItems = items;
[self setMenuItems:items];
}

//==============================================================================
#pragma mark - Button Actions
//==============================================================================

- (void)buttonTapped:(id)arg forEvent:(id)event {
// 处理按钮点击
// 展开控制中心菜单
[super buttonTapped:arg forEvent:event];
}

- (void)buttonModeTapped:(CCUIMenuModuleItem *)sender {
// 处理模式切换
NSInteger index = [self.menuItems indexOfObject:sender];
if (index != NSNotFound && index < self.modeValues.count) {
self.selectedIndex = index;
NSString *modeValue = self.modeValues[index];

// 写入偏好设置
NSMutableDictionary *prefs = [[InsulationPrefsRead() mutableCopy] init];
if (!prefs) {
prefs = [NSMutableDictionary dictionary];
}
prefs[kInsulationPrefsKeyPowerMode] = modeValue;
InsulationPrefsWrite([prefs copy]);

// 发送通知触发模式切换
InsulationPrefsPostDarwinNotification(kInsulationPrefsNotificationExecutePuppetEvent);

// 刷新 UI
[self _setupModeButtons];
[self setSelected:YES];

// 短暂延迟后折叠
dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
dispatch_get_main_queue(), ^{
[self dismissViewControllerAnimated:YES completion:nil];
});
}
}

//==============================================================================
#pragma mark - Properties
//==============================================================================

- (NSArray<NSString *> *)modeValues {
return _modeValues;
}

- (void)setModeValues:(NSArray<NSString *> *)modeValues {
_modeValues = [modeValues copy];
[self _setupModeButtons];
}

- (NSArray<NSString *> *)modeTitles {
return _modeTitles;
}

- (void)setModeTitles:(NSArray<NSString *> *)modeTitles {
_modeTitles = [modeTitles copy];
[self _setupModeButtons];
}

- (NSArray<NSString *> *)modeSubtitles {
return _modeSubtitles;
}

- (void)setModeSubtitles:(NSArray<NSString *> *)modeSubtitles {
_modeSubtitles = [modeSubtitles copy];
[self _setupModeButtons];
}

- (NSInteger)selectedIndex {
return _selectedIndex;
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
_selectedIndex = selectedIndex;
[self _setupModeButtons];
}

@end
