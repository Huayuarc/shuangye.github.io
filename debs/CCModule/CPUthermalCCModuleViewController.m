#import "CPUthermalCCModuleViewController.h"
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <Foundation/Foundation.h>

// ============================================================
// 注意: 禁止使用 @"" ObjC 字符串常量
// roothide 重映射会破坏 __cfstring 内部指针，导致 SIGBUS
// 所有字符串通过 C 字符串 + stringWithUTF8String: 动态创建
// ============================================================

#define S(str) [NSString stringWithUTF8String:(str)]

static const char *kPrefRelativePathC = "Library/Preferences/com.huayuarc.CPUthermal.plist";
static const char *kPowerModeChangedNotifC = "com.huayuarc.CPUthermal/powerModeChanged";

@interface CPUthermalCCModuleViewController ()
@end

@implementation CPUthermalCCModuleViewController

@dynamic menuItems;
@synthesize modeValues = _modeValues;
@synthesize modeTitles = _modeTitles;
@synthesize selectedIndex = _selectedIndex;

//==============================================================================
#pragma mark - Prefs Helpers
//==============================================================================

/// 解析 /var/jb 真实路径，拼接 Prefs 路径
- (NSString *)prefPath {
    NSString *resolvedJBRoot = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:S("/var/jb") error:nil];
    if (resolvedJBRoot) {
        return [resolvedJBRoot stringByAppendingPathComponent:S(kPrefRelativePathC)];
    }
    return [S("/var/jb") stringByAppendingPathComponent:S(kPrefRelativePathC)];
}

/// 读取当前功率模式值
- (NSString *)currentPowerMode {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:[self prefPath]];
    NSString *mode = prefs[S("powerMode")];
    if ([mode isKindOfClass:[NSString class]] && [mode length] > 0) {
        return mode;
    }
    return S("fullPower"); // 默认解除温控
}

/// 写入功率模式并发送通知
- (void)savePowerMode:(NSString *)mode {
    NSString *path = [self prefPath];
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[S("powerMode")] = mode ?: S("fullPower");

    // 确保目录存在
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    [prefs writeToFile:path atomically:YES];
    notify_post(kPowerModeChangedNotifC);

    // kill thermalmonitord 使新配置立即生效
    [self restartThermalmonitord];
}

/// 重启 thermalmonitord 进程
- (void)restartThermalmonitord {
    pid_t pid;
    char *args[] = {"killall", "-q", "thermalmonitord", NULL};
    const char *paths[] = {"/var/jb/usr/bin/killall", "/usr/bin/killall", NULL};
    for (int i = 0; paths[i]; i++) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:S(paths[i])]) {
            if (posix_spawn(&pid, paths[i], NULL, NULL, args, NULL) == 0) {
                waitpid(pid, NULL, 0);
            }
            return;
        }
    }
}

//==============================================================================
#pragma mark - Initialization
//==============================================================================

- (instancetype)init {
    self = [super init];
    if (self) {
        _modeValues = @[S("lowPower"), S("fullPower")];
        _modeTitles = @[S("低功耗"), S("解除温控")];

        // 读取当前设置的模式
        NSString *currentMode = [self currentPowerMode];
        _selectedIndex = [_modeValues indexOfObject:currentMode];
        if (_selectedIndex == NSNotFound) {
            _selectedIndex = 1; // 默认选中"解除温控"
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
    self.title = S("CPUthermal");

    // 设置控制中心图标
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
    UIImage *glyphImage = [UIImage systemImageNamed:S("thermometer.sun.fill") withConfiguration:config];
    [self setGlyphImage:glyphImage];
    [self setSelectedGlyphColor:[UIColor systemOrangeColor]];

    // 布局 UI
    [self setupView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshState];
}

//==============================================================================
#pragma mark - Public
//==============================================================================

- (void)refreshState {
    NSString *currentMode = [self currentPowerMode];
    NSInteger newIndex = [self.modeValues indexOfObject:currentMode];
    if (newIndex != NSNotFound && newIndex != self.selectedIndex) {
        self.selectedIndex = newIndex;
    }
    [self setSelected:(self.selectedIndex == 0) ? NO : YES];
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
    [self refreshState];
    [self setupModeButtons];
}

//==============================================================================
#pragma mark - Setup
//==============================================================================

- (void)setupView {
    // 获取当前模式并计算选中索引
    NSString *currentMode = [self currentPowerMode];
    self.selectedIndex = [self.modeValues indexOfObject:currentMode];
    if (self.selectedIndex == NSNotFound) {
        self.selectedIndex = 1;
    }

    // 设置菜单项
    [self setupModeButtons];

    // 应用当前选中状态
    [self setSelected:(self.selectedIndex == 0) ? NO : YES];
}

- (void)setupModeButtons {
    BOOL isFullPower = [self.currentPowerMode isEqualToString:S("fullPower")];

    NSMutableArray *items = [NSMutableArray array];
    for (NSInteger i = 0; i < self.modeValues.count; i++) {
        NSString *title = self.modeTitles[i];
        BOOL isSelected = (i == self.selectedIndex);

        CCUIMenuModuleItem *item = [[CCUIMenuModuleItem alloc] init];
        item.title = title;

        // 根据模式设置选中状态和颜色
        if (isSelected) {
            if (isFullPower) {
                [item setSelectedGlyphColor:[UIColor systemOrangeColor]];
            } else {
                [item setSelectedGlyphColor:[UIColor systemGreenColor]];
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
    // 展开控制中心菜单
    [super buttonTapped:arg forEvent:event];
}

- (void)buttonModeTapped:(CCUIMenuModuleItem *)sender {
    // 处理模式切换
    NSInteger index = [self.menuItems indexOfObject:sender];
    if (index != NSNotFound && index < self.modeValues.count) {
        self.selectedIndex = index;
        NSString *modeValue = self.modeValues[index];

        // 写入偏好设置并通知 tweak
        [self savePowerMode:modeValue];

        // 刷新 UI
        [self setupModeButtons];
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
    [self setupModeButtons];
}

- (NSArray<NSString *> *)modeTitles {
    return _modeTitles;
}

- (void)setModeTitles:(NSArray<NSString *> *)modeTitles {
    _modeTitles = [modeTitles copy];
    [self setupModeButtons];
}

- (NSInteger)selectedIndex {
    return _selectedIndex;
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self setupModeButtons];
}

@end
