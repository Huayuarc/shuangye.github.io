#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <rootless.h>

// ============================================================
// 让编译器识别被 Hook 的类
// ============================================================
@interface CCUIFlashlightBackgroundViewController : UIViewController
- (void)toggleStrobe;
- (void)startStrobe;
- (void)stopStrobe;
- (void)freqSliderChanged:(UISlider *)slider;
@end

// ============================================================
// 全局状态
// ============================================================
static BOOL      g_enabled    = NO;
static float     g_frequency  = 5.0f;   // 默认 5 Hz
static NSUserDefaults *g_prefs = nil;

// ============================================================
// 关联键 — 用于在 CCUIFlashlightBackgroundViewController 实例
// 上动态关联子控件和定时器
// ============================================================
static const void *kStrobeBtnKey   = &kStrobeBtnKey;
static const void *kStrobeTimerKey = &kStrobeTimerKey;
static const void *kSliderKey      = &kSliderKey;
static const void *kFreqLabelKey   = &kFreqLabelKey;
static const void *kFlashOnKey     = &kFlashOnKey; // 记录当前亮灭状态

#define ASSOC_GETTER(TYPE, KEY) \
    static TYPE getter_##KEY(id obj) { \
        return objc_getAssociatedObject(obj, KEY); \
    }
#define ASSOC_SETTER(TYPE, KEY) \
    static void setter_##KEY(id obj, TYPE val) { \
        objc_setAssociatedObject(obj, KEY, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC); \
    }

ASSOC_GETTER(UIButton *, kStrobeBtnKey)
ASSOC_SETTER(UIButton *, kStrobeBtnKey)
ASSOC_GETTER(NSTimer *, kStrobeTimerKey)
ASSOC_SETTER(NSTimer *, kStrobeTimerKey)
ASSOC_GETTER(UISlider *, kSliderKey)
ASSOC_SETTER(UISlider *, kSliderKey)
ASSOC_GETTER(UILabel *, kFreqLabelKey)
ASSOC_SETTER(UILabel *, kFreqLabelKey)
ASSOC_GETTER(NSNumber *, kFlashOnKey)    // BOOL 装箱
ASSOC_SETTER(NSNumber *, kFlashOnKey)

// ============================================================
// 偏好设置读写
// ============================================================
static void readPrefs(void) {
    if (!g_prefs) {
        g_prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.platykor.tenprefs"];
    }
    [g_prefs registerDefaults:@{
        @"isenabled": @YES,
        @"frequency": @5.0f
    }];
    g_enabled   = [g_prefs boolForKey:@"isenabled"];
    g_frequency = [g_prefs floatForKey:@"frequency"];
    // 限制频率范围
    if (g_frequency < 1.0f)  g_frequency = 1.0f;
    if (g_frequency > 20.0f) g_frequency = 20.0f;
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object,
                                  CFDictionaryRef userInfo) {
    readPrefs();
}

// ============================================================
// 闪光灯硬件控制 - 使用 AVCaptureDevice
// 比 SBUIFlashlightController._setFlashlightLevel: 更可靠
// ============================================================
static AVCaptureDevice *getCamera(void) {
    return [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
}

static void torchSetOn(BOOL on) {
    AVCaptureDevice *cam = getCamera();
    if (!cam || ![cam hasTorch]) return;

    [cam lockForConfiguration:nil];
    if (on) {
        [cam setTorchModeOnWithLevel:1.0f error:nil];
    } else {
        [cam setTorchMode:AVCaptureTorchModeOff];
    }
    [cam unlockForConfiguration];
}

// 同时停掉 SBUIFlashlightController 的状态同步
static void sbuiflashlightOff(void) {
    Class cls = objc_getClass("SBUIFlashlightController");
    if (!cls) return;
    id ctrl = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_getUid("sharedInstance"));
    if (ctrl) {
        ((void (*)(id, SEL, float))objc_msgSend)(ctrl, sel_getUid("_setFlashlightLevel:"), 0.0f);
    }
}

// ============================================================
// 工具：创建带圆圈的闪电图标按钮
// ============================================================
static UIButton *createStrobeButton(id target, SEL action) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, 64, 64);
    btn.backgroundColor = [UIColor systemYellowColor];
    btn.layer.cornerRadius = 32;
    btn.layer.masksToBounds = YES;
    btn.tintColor = [UIColor blackColor];
    btn.translatesAutoresizingMaskIntoConstraints = YES;
    btn.userInteractionEnabled = YES;

    // 闪电符号
    UILabel *bolt = [[UILabel alloc] initWithFrame:btn.bounds];
    bolt.text = @"⚡";
    bolt.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
    bolt.textAlignment = NSTextAlignmentCenter;
    bolt.textColor = [UIColor blackColor];
    bolt.userInteractionEnabled = NO;
    [btn addSubview:bolt];

    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    btn.alpha = 0.35; // 未激活状态
    return btn;
}

// ============================================================
// 主 Hook — CC 手电筒面板
// ============================================================
%hook CCUIFlashlightBackgroundViewController

// MARK: - loadView: 创建自定义 UI
- (void)loadView {
    %orig;
    readPrefs();

    // 清理旧的子控件 & 定时器（避免重复添加）
    [getter_kStrobeTimerKey(self) invalidate];
    setter_kStrobeTimerKey(self, nil);
    [getter_kStrobeBtnKey(self) removeFromSuperview];
    [getter_kSliderKey(self) removeFromSuperview];
    [getter_kFreqLabelKey(self) removeFromSuperview];
    setter_kFlashOnKey(self, nil);
    torchSetOn(NO);

    if (!g_enabled) return;

    UIView *view = ((UIView *(*)(id, SEL))objc_msgSend)(self, sel_getUid("view"));
    if (!view) return;

    CGFloat midX   = CGRectGetMidX(view.bounds);
    CGFloat bottom = CGRectGetMaxY(view.bounds);

    // ---- 频率值标签 ----
    UILabel *freqLabel = [[UILabel alloc] init];
    freqLabel.text = [NSString stringWithFormat:@"%.0f Hz", g_frequency];
    freqLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    freqLabel.textColor = [UIColor whiteColor];
    freqLabel.textAlignment = NSTextAlignmentCenter;
    freqLabel.frame = CGRectMake(0, 0, 80, 22);
    freqLabel.center = CGPointMake(midX, bottom - 48);
    freqLabel.layer.shadowColor = [UIColor blackColor].CGColor;
    freqLabel.layer.shadowOffset = CGSizeMake(0, 1);
    freqLabel.layer.shadowOpacity = 0.6;
    [view addSubview:freqLabel];
    setter_kFreqLabelKey(self, freqLabel);

    // ---- 频率滑块 ----
    UISlider *slider = [[UISlider alloc] init];
    slider.frame = CGRectMake(midX - 110, bottom - 78, 220, 30);
    slider.minimumValue = 1.0f;
    slider.maximumValue = 20.0f;
    slider.value = g_frequency;
    slider.continuous = YES;
    slider.tintColor = [UIColor systemYellowColor];
    slider.thumbTintColor = [UIColor whiteColor];
    [slider setMinimumTrackTintColor:[UIColor systemYellowColor]];
    [slider setMaximumTrackTintColor:[[UIColor whiteColor] colorWithAlphaComponent:0.3]];
    [slider addTarget:self action:@selector(freqSliderChanged:)
     forControlEvents:UIControlEventValueChanged];
    [view addSubview:slider];
    setter_kSliderKey(self, slider);

    // ---- 频闪开关按钮 ----
    UIButton *strobeBtn = createStrobeButton(self, @selector(toggleStrobe));
    strobeBtn.center = CGPointMake(midX, bottom - 138);
    [view addSubview:strobeBtn];
    setter_kStrobeBtnKey(self, strobeBtn);
}

// MARK: - 离开时确保关闭
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [getter_kStrobeTimerKey(self) invalidate];
    setter_kStrobeTimerKey(self, nil);
    setter_kFlashOnKey(self, nil);
    torchSetOn(NO);
    sbuiflashlightOff();
}

// MARK: - 频闪定时器管理
%new
- (void)startStrobe {
    UIButton *btn = getter_kStrobeBtnKey(self);
    btn.alpha = 1.0;
    [btn setBackgroundColor:[UIColor systemYellowColor]];

    setter_kFlashOnKey(self, @NO);

    NSTimeInterval halfCycle = 1.0f / (g_frequency * 2);
    if (halfCycle < 0.025) halfCycle = 0.025; // 最低 25ms 防止硬件跟不上

    __weak id weakSelf = self;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:halfCycle repeats:YES
        block:^(NSTimer *t) {
            id strongSelf = weakSelf;
            if (!strongSelf) { [t invalidate]; return; }

            BOOL on = ![getter_kFlashOnKey(strongSelf) boolValue];
            setter_kFlashOnKey(strongSelf, @(on));
            torchSetOn(on);
        }];
    setter_kStrobeTimerKey(self, timer);
}

%new
- (void)stopStrobe {
    [getter_kStrobeTimerKey(self) invalidate];
    setter_kStrobeTimerKey(self, nil);
    setter_kFlashOnKey(self, nil);
    torchSetOn(NO);

    UIButton *btn = getter_kStrobeBtnKey(self);
    btn.alpha = 0.35;
}

// MARK: - 频闪开关
%new
- (void)toggleStrobe {
    NSTimer *timer = getter_kStrobeTimerKey(self);
    if (timer && timer.isValid) {
        [self stopStrobe];
    } else {
        [self startStrobe];
    }
}

// MARK: - 频率滑块事件
%new
- (void)freqSliderChanged:(UISlider *)slider {
    // 取整到整数 Hz
    float val = roundf(slider.value);
    if (val < 1.0f)  val = 1.0f;
    if (val > 20.0f) val = 20.0f;
    slider.value = val;
    g_frequency = val;

    // 更新标签
    UILabel *label = getter_kFreqLabelKey(self);
    label.text = [NSString stringWithFormat:@"%.0f Hz", val];

    // 保存到偏好
    [g_prefs setFloat:val forKey:@"frequency"];
    [g_prefs synchronize];

    // 如果频闪正在运行，重启定时器应用新频率
    NSTimer *timer = getter_kStrobeTimerKey(self);
    if (timer && timer.isValid) {
        [timer invalidate];
        setter_kStrobeTimerKey(self, nil);

        NSTimeInterval halfCycle = 1.0f / (val * 2);
        if (halfCycle < 0.025) halfCycle = 0.025;

        __weak id weakSelf = self;
        NSTimer *newTimer = [NSTimer scheduledTimerWithTimeInterval:halfCycle repeats:YES
            block:^(NSTimer *t) {
                id strongSelf = weakSelf;
                if (!strongSelf) { [t invalidate]; return; }

                BOOL on = ![getter_kFlashOnKey(strongSelf) boolValue];
                setter_kFlashOnKey(strongSelf, @(on));
                torchSetOn(on);
            }];
        setter_kStrobeTimerKey(self, newTimer);
    }
}

%end

// ============================================================
// 构造函数
// ============================================================
%ctor {
    @autoreleasepool {
        readPrefs();
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            prefsChangedCallback,
            CFSTR("com.platykor.tenprefs.prefschanged"),
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
    }
}
