#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <rootless.h>

// ============================================================
// Global state
// ============================================================
static int g_ballcount = 0;
static int g_seconds = 0;
static BOOL g_ballsw = NO;
static BOOL g_ballstrobo = NO;
static BOOL g_attivo = NO;
static BOOL g_running = NO;
static BOOL g_tim = 0;
static int g_selected = 0;
static NSUserDefaults *g_prefs = nil;
static NSMutableArray *g_arrPicker = nil;

// ============================================================
// Association keys for dynamic properties
// ============================================================
static const void *kStrobeKey = &kStrobeKey;
static const void *kBalltimerKey = &kBalltimerKey;
static const void *kSosKey = &kSosKey;
static const void *kThetimeKey = &kThetimeKey;
static const void *kTimerKey = &kTimerKey;
static const void *kLongtimeKey = &kLongtimeKey;
static const void *kPickerKey = &kPickerKey;
static const void *kToolBarKey = &kToolBarKey;

// ============================================================
// Inline property helpers (avoid category visibility issues)
// ============================================================
#define ASSOC_GETTER(TYPE, KEY) \
    static TYPE getter_##KEY(id obj) { \
        return objc_getAssociatedObject(obj, KEY); \
    }
#define ASSOC_SETTER(TYPE, KEY) \
    static void setter_##KEY(id obj, TYPE val) { \
        objc_setAssociatedObject(obj, KEY, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC); \
    }

ASSOC_GETTER(UIButton *, kStrobeKey)
ASSOC_SETTER(UIButton *, kStrobeKey)
ASSOC_SETTER(NSTimer *, kBalltimerKey)
ASSOC_GETTER(UIButton *, kSosKey)
ASSOC_SETTER(UIButton *, kSosKey)
ASSOC_GETTER(UIButton *, kThetimeKey)
ASSOC_SETTER(UIButton *, kThetimeKey)
ASSOC_GETTER(NSTimer *, kTimerKey)
ASSOC_SETTER(NSTimer *, kTimerKey)
ASSOC_SETTER(UILongPressGestureRecognizer *, kLongtimeKey)
ASSOC_GETTER(UIPickerView *, kPickerKey)
ASSOC_SETTER(UIPickerView *, kPickerKey)
ASSOC_GETTER(UIToolbar *, kToolBarKey)
ASSOC_SETTER(UIToolbar *, kToolBarKey)

// ============================================================
// Preferences helpers
// ============================================================
static void readPrefs(void) {
    g_prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.platykor.tenprefs"];
    [g_prefs registerDefaults:@{
        @"isenabled": @YES,
        @"seconds": @10,
        @"tim": @0
    }];
    g_running = [g_prefs boolForKey:@"isenabled"];
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object,
                                  CFDictionaryRef userInfo) {
    readPrefs();
}

// ============================================================
// Helper: get SBUIFlashlightController
// ============================================================
static id getFlashlightController(void) {
    Class cls = objc_getClass("SBUIFlashlightController");
    if (cls) return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_getUid("sharedInstance"));
    return nil;
}

static void setFlashlightLevel(float level) {
    id ctrl = getFlashlightController();
    if (ctrl) {
        ((void (*)(id, SEL, float))objc_msgSend)(ctrl, sel_getUid("_setFlashlightLevel:"), level);
    }
}

// Forward declaration so the %hook block knows the category interface
@protocol FlashlightPickerDelegate <UIPickerViewDataSource, UIPickerViewDelegate>
@end

// ============================================================
// Main hook: CCUIFlashlightBackgroundViewController
// ============================================================
%hook CCUIFlashlightBackgroundViewController

// MARK: - loadView (hooked)
- (void)loadView {
    %orig;
    readPrefs();

    if (!g_running) {
        UIButton *b;
        b = getter_kStrobeKey(self); [b removeFromSuperview];
        b = getter_kSosKey(self); [b removeFromSuperview];
        b = getter_kThetimeKey(self); [b removeFromSuperview];
        [getter_kPickerKey(self) removeFromSuperview];
        [getter_kToolBarKey(self) removeFromSuperview];
        return;
    }

    UIView *view = ((UIView * (*)(id, SEL))objc_msgSend)(self, sel_getUid("view"));

    // ---- Strobe Button ----
    UIButton *strobeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    setter_kStrobeKey(self, strobeBtn);
    strobeBtn.frame = CGRectMake(0, 0, 50, 50);
    strobeBtn.tintColor = [UIColor labelColor];
    strobeBtn.translatesAutoresizingMaskIntoConstraints = YES;
    strobeBtn.userInteractionEnabled = YES;
    [strobeBtn addTarget:self action:@selector(strobe_on) forControlEvents:UIControlEventTouchUpInside];
    strobeBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    strobeBtn.layer.shadowOffset = CGSizeMake(0, 3);
    strobeBtn.layer.shadowOpacity = 0.5;

    CGFloat midX = CGRectGetMidX(view.bounds);
    CGFloat maxY = CGRectGetMaxY(view.bounds);
    strobeBtn.center = CGPointMake(midX, maxY - 90);

    UIImage *strobeImg = [UIImage imageWithContentsOfFile:ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/sos.png")];
    [strobeBtn setBackgroundImage:strobeImg forState:UIControlStateNormal];
    [view addSubview:strobeBtn];
    strobeBtn.hidden = NO;

    // ---- SOS Button ----
    UIButton *sosBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    setter_kSosKey(self, sosBtn);
    sosBtn.frame = CGRectMake(0, 0, 50, 50);
    sosBtn.tintColor = [UIColor labelColor];
    sosBtn.translatesAutoresizingMaskIntoConstraints = YES;
    sosBtn.userInteractionEnabled = YES;
    [sosBtn addTarget:self action:@selector(morse) forControlEvents:UIControlEventTouchUpInside];
    sosBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    sosBtn.layer.shadowOffset = CGSizeMake(0, 3);
    sosBtn.layer.shadowOpacity = 0.5;

    CGRect viewFrame = view.frame;
    sosBtn.center = CGPointMake(CGRectGetMidX(viewFrame) - 90, CGRectGetMaxY(viewFrame) - 90);

    UIImage *sosImg = [UIImage imageWithContentsOfFile:ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/sos.png")];
    [sosBtn setBackgroundImage:sosImg forState:UIControlStateNormal];
    [view addSubview:sosBtn];
    sosBtn.hidden = NO;

    // ---- Timer Button ----
    UIButton *timeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    setter_kThetimeKey(self, timeBtn);
    timeBtn.frame = CGRectMake(0, 0, 50, 50);
    timeBtn.tintColor = [UIColor labelColor];
    timeBtn.translatesAutoresizingMaskIntoConstraints = YES;
    timeBtn.userInteractionEnabled = YES;
    [timeBtn addTarget:self action:@selector(tempo) forControlEvents:UIControlEventTouchUpInside];
    timeBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    timeBtn.layer.shadowOffset = CGSizeMake(0, 3);
    timeBtn.layer.shadowOpacity = 0.5;

    timeBtn.center = CGPointMake(CGRectGetMidX(viewFrame) + 90, CGRectGetMaxY(viewFrame) - 90);

    UIImage *timeImg = [UIImage imageWithContentsOfFile:ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/timer.png")];
    [timeBtn setBackgroundImage:timeImg forState:UIControlStateNormal];
    [view addSubview:timeBtn];
    timeBtn.hidden = NO;

    // ---- Long Press Recognizer ----
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(addtime)];
    setter_kLongtimeKey(self, longPress);
    [strobeBtn addGestureRecognizer:longPress];

    // ---- Initial alpha ----
    CGFloat alpha = 0.25;
    strobeBtn.alpha = alpha;
    sosBtn.alpha = alpha;
    timeBtn.alpha = alpha;
}

// MARK: - viewWillDisappear: (hooked)
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [getter_kTimerKey(self) invalidate];
    setFlashlightLevel(0.0f);
    g_running = NO;
}

// MARK: - viewDidLoad
%new
- (void)viewDidLoad {
    readPrefs();
    setFlashlightLevel(0.0f);
    [getter_kTimerKey(self) invalidate];

    // Build picker data: 1...240
    g_arrPicker = [NSMutableArray array];
    for (int i = 1; i <= 240; i++) {
        [g_arrPicker addObject:@(i)];
    }

    UIView *view = ((UIView * (*)(id, SEL))objc_msgSend)(self, sel_getUid("view"));

    // Picker
    UIPickerView *picker = getter_kPickerKey(self);
    if (! [picker window]) {
        picker = [[UIPickerView alloc] initWithFrame:CGRectMake(0, 0, view.frame.size.width,
                                                                 view.frame.size.height * 0.25)];
        setter_kPickerKey(self, picker);
    }
    picker.dataSource = (id<UIPickerViewDataSource>)self;
    picker.delegate = (id<UIPickerViewDelegate>)self;
    picker.backgroundColor = [UIColor systemGrayColor];

    CGFloat pickerCenterY = CGRectGetMaxY(view.bounds) - (picker.frame.size.height * 0.5);
    picker.center = CGPointMake(CGRectGetMidX(view.bounds), pickerCenterY);
    [view addSubview:picker];
    [picker reloadAllComponents];

    // Toolbar
    UIToolbar *toolBar = getter_kToolBarKey(self);
    if (! [toolBar window]) {
        toolBar = [[UIToolbar alloc] init];
        setter_kToolBarKey(self, toolBar);
    }
    toolBar.frame = CGRectMake(0, CGRectGetMinY(view.bounds) - 10, view.frame.size.width, 44);
    toolBar.barStyle = UIBarStyleBlack;

    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc] initWithTitle:@"Done"
                                style:UIBarButtonItemStyleDone
                                target:self action:@selector(dismissp)];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
                             initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil action:nil];
    [toolBar setItems:@[flex, doneBtn]];
    toolBar.translucent = YES;
    doneBtn.tintColor = [UIColor whiteColor];
    [[toolBar superview] addSubview:toolBar];

    // Restore selection
    NSNumber *savedVal = [g_prefs objectForKey:@"seconds"];
    g_selected = savedVal ? [savedVal intValue] : 0;
    [picker selectRow:g_selected inComponent:0 animated:YES];
}

// MARK: - addtime (long press on strobe)
%new
- (void)addtime {
    AudioServicesPlaySystemSound(1519);
    setFlashlightLevel(1.0f);

    UIButton *strobe = getter_kStrobeKey(self);
    strobe.hidden = NO;
    getter_kSosKey(self).hidden = YES;
    getter_kThetimeKey(self).hidden = YES;

    [UIView animateWithDuration:0.25 delay:0.0
        options:UIViewAnimationOptionCurveEaseInOut animations:^{} completion:^(BOOL f){}];

    [getter_kThetimeKey(self) setAlpha:1.0];

    NSNumber *savedSeconds = [g_prefs objectForKey:@"seconds"];
    if (!savedSeconds) savedSeconds = @(10);
    g_selected = [savedSeconds intValue];

    __weak id weakSelf = self;
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:[savedSeconds doubleValue] repeats:NO
        block:^(NSTimer *tm) {
            [weakSelf performSelector:@selector(tempoff)];
        }];
    setter_kTimerKey(self, t);
}

// MARK: - tempo
%new
- (void)tempo {
    AudioServicesPlaySystemSound(1519);
    g_tim = !g_tim;

    if (g_tim) {
        getter_kStrobeKey(self).hidden = YES;
        getter_kSosKey(self).hidden = YES;

        [UIView animateWithDuration:0.25 delay:0.0
            options:UIViewAnimationOptionCurveEaseInOut animations:^{} completion:^(BOOL f){}];

        NSNumber *savedSeconds = [g_prefs objectForKey:@"seconds"];
        g_seconds = savedSeconds ? [savedSeconds intValue] : 10;
        [getter_kThetimeKey(self) setAlpha:1.0];
        setFlashlightLevel(1.0f);

        __weak id weakSelf = self;
        NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:g_seconds repeats:YES
            block:^(NSTimer *tm) {
                [weakSelf performSelector:@selector(tempoff)];
            }];
        setter_kTimerKey(self, t);
    }
    if (!g_tim) {
        [(id)self performSelector:@selector(tempoff)];
    }
}

// MARK: - tempoff
%new
- (void)tempoff {
    AudioServicesPlaySystemSound(1519);
    g_tim = NO;
    [getter_kThetimeKey(self) setAlpha:0.25];
    setFlashlightLevel(0.0f);
    [getter_kTimerKey(self) invalidate];

    [UIView animateWithDuration:0.25 delay:0.0
        options:UIViewAnimationOptionCurveEaseInOut animations:^{} completion:^(BOOL f){}];
}

// MARK: - morse (SOS)
%new
- (void)morse {
    AudioServicesPlaySystemSound(1519);
    g_attivo = !g_attivo;

    if (g_attivo) {
        setFlashlightLevel(0.0f);
        g_running = NO;
        g_attivo = NO;

        UILabel *label = [[UILabel alloc] init];
        label.text = @"Please wait for it to finish.";
        label.font = [[label font] fontWithSize:11];
        label.backgroundColor = [UIColor clearColor];
        label.textColor = [UIColor whiteColor];
        label.opaque = YES;
        label.layer.masksToBounds = YES;
        label.textAlignment = NSTextAlignmentCenter;
        label.layer.cornerRadius = 5;

        UIScreen *screen = [UIScreen mainScreen];
        label.frame = CGRectMake(0, 10, screen.bounds.size.width * 0.5, 12);
        label.center = CGPointMake(screen.bounds.size.width * 0.5, screen.bounds.size.height - 20);
        [[(id)self valueForKey:@"view"] addSubview:label];
        label.layer.zPosition = 100;

        [UIView animateWithDuration:0.5 delay:0.0
            options:UIViewAnimationOptionCurveEaseInOut
            animations:^{ label.alpha = 0.0; }
            completion:^(BOOL finished) { [label removeFromSuperview]; }];

        getter_kStrobeKey(self).hidden = YES;
        getter_kThetimeKey(self).hidden = YES;

        [UIView animateWithDuration:0.25 delay:0.0
            options:UIViewAnimationOptionCurveEaseInOut
            animations:^{}
            completion:^(BOOL finished) { [(id)self performSelector:@selector(morse)]; }];
    } else {
        [getter_kSosKey(self) setAlpha:0.25];
        [getter_kStrobeKey(self) setEnabled:NO];
        setFlashlightLevel(0.0f);
        g_running = NO;
        g_attivo = NO;

        // SOS morse code in background
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            for (int j = 0; j < 3; j++) {
                setFlashlightLevel(1.0f);
                [NSThread sleepForTimeInterval:0.2];
                setFlashlightLevel(0.0f);
                [NSThread sleepForTimeInterval:0.2];
            }
            for (int j = 0; j < 3; j++) {
                setFlashlightLevel(1.0f);
                [NSThread sleepForTimeInterval:0.6];
                setFlashlightLevel(0.0f);
                [NSThread sleepForTimeInterval:0.2];
            }
            for (int j = 0; j < 3; j++) {
                setFlashlightLevel(1.0f);
                [NSThread sleepForTimeInterval:0.2];
                setFlashlightLevel(0.0f);
                [NSThread sleepForTimeInterval:0.2];
            }
        });

        getter_kStrobeKey(self).hidden = NO;
        getter_kThetimeKey(self).hidden = NO;
        [getter_kStrobeKey(self) setAlpha:1.0];

        __weak id weakSelf = self;
        NSTimer *bt = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES
            block:^(NSTimer *t) { [weakSelf performSelector:@selector(strobe)]; }];
        setter_kBalltimerKey(self, bt);
    }
}

// MARK: - strobe_on
%new
- (void)strobe_on {
    AudioServicesPlaySystemSound(1519);
    g_ballsw = !g_ballsw;

    if (g_ballsw) {
        getter_kSosKey(self).hidden = YES;
        getter_kThetimeKey(self).hidden = YES;

        [UIView animateWithDuration:0.25 delay:0.0
            options:UIViewAnimationOptionCurveEaseInOut
            animations:^{} completion:^(BOOL f){ g_ballcount = 0; }];

        g_ballcount = 0;
        NSString *path = [NSString stringWithFormat:ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/mirrorball/%i.png"), g_ballcount];
        [getter_kStrobeKey(self) setBackgroundImage:[UIImage imageWithContentsOfFile:path] forState:UIControlStateNormal];
        setFlashlightLevel(0.0f);

        __weak id weakSelf = self;
        NSTimer *bt = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES
            block:^(NSTimer *t) { [weakSelf performSelector:@selector(strobe)]; }];
        setter_kBalltimerKey(self, bt);
    }

    if (!g_ballsw && !g_ballstrobo && !g_tim) {
        getter_kThetimeKey(self).hidden = YES;
        getter_kSosKey(self).hidden = YES;
        [getter_kStrobeKey(self) setAlpha:1.0];

        __weak id weakSelf = self;
        NSTimer *bt = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES
            block:^(NSTimer *t) { [weakSelf performSelector:@selector(strobe)]; }];
        setter_kBalltimerKey(self, bt);
        setFlashlightLevel(0.0f);
    }
}

// MARK: - strobe (mirrorball frame advance)
%new
- (void)strobe {
    g_ballcount++;
    if (g_ballcount > 12) g_ballcount = 1;
    NSString *path = [NSString stringWithFormat:ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/mirrorball/%i.png"), g_ballcount];
    [getter_kStrobeKey(self) setBackgroundImage:[UIImage imageWithContentsOfFile:path] forState:UIControlStateNormal];
}

// MARK: - dismissp
%new
- (void)dismissp {
    [getter_kPickerKey(self) removeFromSuperview];
    [getter_kToolBarKey(self) removeFromSuperview];
    getter_kStrobeKey(self).hidden = NO;
    getter_kSosKey(self).hidden = NO;
}

// MARK: - UIPickerViewDataSource
%new
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

%new
- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return 113;
}

// MARK: - UIPickerViewDelegate
%new
- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    return [NSString stringWithFormat:@"%ld", (long)[g_arrPicker[row] integerValue]];
}

%new
- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    g_selected = (int)[g_arrPicker[row] integerValue];
    g_seconds = g_selected;
    g_tim = g_selected;

    [g_prefs setInteger:g_selected forKey:@"seconds"];
    [g_prefs setInteger:g_selected forKey:@"tim"];
    [g_prefs synchronize];
}

%end

// ============================================================
// Constructor
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
