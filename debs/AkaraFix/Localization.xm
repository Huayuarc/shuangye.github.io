#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

static NSDictionary<NSString *, NSString *> *AKRTranslations(void) {
    return @{
      @"Minimal design without compromise": @"极简设计，绝不妥协",
      @"Tweak Enabled": @"启用 Akara", @"Reset Module Defaults": @"重置模块布局",
      @"Reset Preference Defaults": @"重置所有设置", @"Layout Settings": @"布局设置",
      @"Large Mode": @"大尺寸模式", @"SE Compatibility": @"小屏设备兼容模式",
      @"Background Settings": @"背景设置", @"Use Background Blur": @"使用背景模糊",
      @"Blur Style": @"模糊样式", @"Use Background Image": @"使用背景图片",
      @"Choose image": @"选择图片", @"Radius Settings": @"圆角设置",
      @"Use Custom Corner Radius": @"使用自定义圆角", @"Custom Corner Radius": @"自定义圆角半径",
      @"Connectivity Settings": @"连接模块设置", @"Use Static Wi-Fi Icon": @"使用静态 Wi‑Fi 图标",
      @"Use Static Bluetooth Icon": @"使用静态蓝牙图标",
      @"Use Native Language Label Names": @"使用系统语言显示名称",
      @"Reset Page When Opened": @"每次打开时返回第一页",
      @"Connectivity Order Settings (Separated by comma)": @"连接模块顺序（使用逗号分隔）",
      @"Slider Settings": @"滑块设置", @"Use Static Brightness Slider Icon": @"使用静态亮度图标",
      @"Use Static Volume Slider Icon": @"使用静态音量图标", @"Slider Height": @"滑块高度",
      @"Module Settings": @"模块设置", @"Use Custom Transparency Alpha": @"使用自定义透明度",
      @"Transparency Alpha": @"透明度", @"Media Module Width": @"媒体模块宽度",
      @"Media Module Height": @"媒体模块高度", @"Show Radio Button": @"显示广播按钮",
      @"LockScreen Settings": @"锁屏设置", @"Ease Lockscreen Gesture": @"简化锁屏唤出手势",
      @"StatusBar Settings": @"状态栏设置", @"Show Akara StatusBar": @"显示 Akara 状态栏",
      @"Show Normal StatusBar": @"显示系统状态栏", @"Extra Settings (Respring required)": @"附加设置（需要注销）",
      @"Use Standard CC in Landscape Mode": @"横屏时使用系统控制中心",
      @"Enable top-right gesture": @"启用右上角手势",
      @"Enable top-right and bottom gesture": @"同时启用右上角和底部手势",
      @"Extra Light": @"超浅色", @"Light": @"浅色", @"Dark": @"深色",
      @"Prominent": @"突出", @"Regular": @"常规", @"System Material": @"系统材质",
      @"System Material Light": @"浅色系统材质", @"System Material Dark": @"深色系统材质",
      @"System Material Chrome": @"系统铬材质", @"System Material Ultra Thin": @"超薄系统材质",
      @"System Material Thin": @"薄系统材质", @"System Material Thick": @"厚系统材质",
      @"System Material Ultra Thin Dark": @"深色超薄系统材质", @"System Material Thin Dark": @"深色薄系统材质",
      @"System Material Thick Dark": @"深色厚系统材质", @"System Material Chrome Dark": @"深色系统铬材质",
      @"Choose Modules": @"选择模块", @"First Module": @"第一个模块",
      @"Second Module": @"第二个模块", @"Save": @"保存", @"Apply": @"应用"
    };
}

static NSString *AKRTranslate(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return text;
    NSString *translated = AKRTranslations()[text];
    if (translated) return translated;
    if ([text hasPrefix:@"Press Apply after enabling SE Compatibility"]) return @"启用小屏设备兼容模式后，请点击右上角“应用”。";
    if ([text hasPrefix:@"This remains an experimental feature"]) return @"此功能仍处于实验阶段。数值过大时模块可能超出边界。";
    if ([text hasPrefix:@"First Page Order"]) return @"第一页顺序：1 飞行模式 · 2 Wi‑Fi · 3 蓝牙";
    if ([text hasPrefix:@"Second Page Order"]) return @"第二页顺序：4 蜂窝网络 · 5 个人热点 · 6 隔空投送";
    if ([text hasPrefix:@"Press Apply after changing the size"]) return @"修改媒体模块尺寸后，请点击右上角“应用”。";
    if ([text hasPrefix:@"Enabling this option will open Akara"]) return @"开启后，在锁屏界面轻扫即可打开 Akara；仅适用于底部手势。";
    if ([text hasPrefix:@"Enable \"Show Akara StatusBar\""]) return @"刘海屏设备可显示 Akara 状态栏；“显示系统状态栏”适用于所有设备。";
    if ([text hasPrefix:@"Enabling the top-right gesture,"]) return @"开启后可从右上角下滑打开 Akara，同时停用底部上滑唤出方式。";
    if ([text hasPrefix:@"Enabling both gestures will allow"]) return @"开启后可同时使用底部和右上角手势。请关闭上方单独的“右上角手势”，避免冲突。";
    return text;
}

static NSArray *(*OrigSpecifiers)(id, SEL);
static NSArray *FixSpecifiers(id self, SEL cmd) {
    NSArray *items = OrigSpecifiers(self, cmd);
    for (id item in items) {
        for (NSString *key in @[@"label", @"footerText", @"staticTextMessage", @"title", @"subtitle"]) {
            id value = nil;
            @try { value = [item propertyForKey:key]; } @catch (__unused NSException *e) {}
            if ([value isKindOfClass:NSString.class]) [item setProperty:AKRTranslate(value) forKey:key];
        }
        id titles = nil;
        @try { titles = [item propertyForKey:@"validTitles"]; } @catch (__unused NSException *e) {}
        if ([titles isKindOfClass:NSArray.class]) {
            NSMutableArray *translated = [NSMutableArray array];
            for (id title in titles) [translated addObject:AKRTranslate(title) ?: title];
            [item setProperty:translated forKey:@"validTitles"];
        }
    }
    return items;
}

static void (*OrigViewWillAppear)(id, SEL, BOOL);
static void FixViewWillAppear(id self, SEL cmd, BOOL animated) {
    OrigViewWillAppear(self, cmd, animated);
    UINavigationItem *nav = [self navigationItem];
    nav.title = @"Akara";
    nav.rightBarButtonItem.title = @"应用";
}

static void AKRTryInstallLocalization(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class cls = objc_getClass("AKRRootListController");
    if (!cls) return;
    Method specifiers = class_getInstanceMethod(cls, NSSelectorFromString(@"specifiers"));
    Method appear = class_getInstanceMethod(cls, @selector(viewWillAppear:));
    if (specifiers) MSHookMessageEx(cls, method_getName(specifiers), (IMP)FixSpecifiers, (IMP *)&OrigSpecifiers);
    if (appear) MSHookMessageEx(cls, @selector(viewWillAppear:), (IMP)FixViewWillAppear, (IMP *)&OrigViewWillAppear);
    installed = specifiers != NULL;
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.Preferences"]) return;
    AKRTryInstallLocalization();
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(__unused NSTimer *timer) { AKRTryInstallLocalization(); }];
}
