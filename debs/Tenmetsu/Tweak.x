#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <rootless.h>

// ============================================================
// Global state
// ============================================================
static BOOL g_prefsEnabled = NO;
static BOOL g_strobeEnabled = YES;
static BOOL g_morseEnabled = YES;
static BOOL g_timerEnabled = YES;

static BOOL g_strobeActive = NO;    // strobe currently flashing
static BOOL g_sosActive = NO;       // SOS currently in progress
static BOOL g_timerActive = NO;     // timer-based flashlight on

static int g_selectedSeconds = 10;  // user-selected seconds from picker
static NSUserDefaults *g_prefs = nil;
static NSMutableArray *g_arrPicker = nil;

// ============================================================
// Association keys for dynamic properties
// ============================================================
static const void *kStrobeKey = &kStrobeKey;
static const void *kStrobeTimerKey = &kStrobeTimerKey;
static const void *kSosKey = &kSosKey;
static const void *kTimerBtnKey = &kTimerBtnKey;
static const void *kTimerKey = &kTimerKey;
static const void *kPickerKey = &kPickerKey;
static const void *kToolBarKey = &kToolBarKey;

// ============================================================
// Inline property helpers
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
ASSOC_GETTER(NSTimer *, kStrobeTimerKey)
ASSOC_SETTER(NSTimer *, kStrobeTimerKey)
ASSOC_GETTER(UIButton *, kSosKey)
ASSOC_SETTER(UIButton *, kSosKey)
ASSOC_GETTER(UIButton *, kTimerBtnKey)
ASSOC_SETTER(UIButton *, kTimerBtnKey)
ASSOC_GETTER(NSTimer *, kTimerKey)
ASSOC_SETTER(NSTimer *, kTimerKey)
ASSOC_GETTER(UIPickerView *, kPickerKey)
ASSOC_SETTER(UIPickerView *, kPickerKey)
ASSOC_GETTER(UIToolbar *, kToolBarKey)
ASSOC_SETTER(UIToolbar *, kToolBarKey)

// ============================================================
// Preferences helpers
// ============================================================
static void readPrefs(void) {
    if (!g_prefs) {
        g_prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.platykor.tenprefs"];
    }
    [g_prefs registerDefaults:@{
        @"isenabled": @YES,
        @"seconds": @10,
        @"strobeEnabled": @YES,
        @"morseEnabled": @YES,
        @"timerEnabled": @YES
    }];
    g_prefsEnabled = [g_prefs boolForKey:@"isenabled"];
    g_strobeEnabled = [g_prefs boolForKey:@"strobeEnabled"];
    g_morseEnabled = [g_prefs boolForKey:@"morseEnabled"];
    g_timerEnabled = [g_prefs boolForKey:@"timerEnabled"];

    NSNumber *saved = [g_prefs objectForKey:@"seconds"];
    g_selectedSeconds = saved ? [saved intValue] : 10;
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

// ============================================================
// Helper: create a styled button
// ============================================================
static UIButton *createButton(id target, SEL action, NSString *imagePath) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, 50, 50);
    btn.tintColor = [UIColor labelColor];
    btn.translatesAutoresizingMaskIntoConstraints = YES;
    btn.userInteractionEnabled = YES;
    [btn addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOffset = CGSizeMake(0, 3);
    btn.layer.shadowOpacity = 0.5;
    UIImage *img = [UIImage imageWithContentsOfFile:imagePath];
    [btn setBackgroundImage:img forState:UIControlStateNormal];
    btn.alpha = 0.25;
    return btn;
}

// ============================================================
// Main hook: CCUIFlashlightBackgroundViewController
// ============================================================
%hook CCUIFlashlightBackgroundViewController

// MARK: - loadView (hooked)
- (void)loadView {
    %orig;
    readPrefs();

    // Remove any existing custom subviews to avoid duplicates
    UIButton *b;
    b = getter_kStrobeKey(self); [b removeFromSuperview];
    b = getter_kSosKey(self); [b removeFromSuperview];
    b = getter_kTimerBtnKey(self); [b removeFromSuperview];
    [getter_kPickerKey(self) removeFromSuperview];
    [getter_kToolBarKey(self) removeFromSuperview];

    // Also clean up any running state from previous session
    [getter_kStrobeTimerKey(self) invalidate];
    [getter_kTimerKey(self) invalidate];
    g_strobeActive = NO;
    g_sosActive = NO;
    g_timerActive = NO;
    setFlashlightLevel(0.0f);

    if (!g_prefsEnabled) return;

    UIView *view = ((UIView * (*)(id, SEL))objc_msgSend)(self, sel_getUid("view"));
    if (!view) return;

    CGFloat midX = CGRectGetMidX(view.bounds);
    CGFloat maxY = CGRectGetMaxY(view.bounds);
    CGFloat btnY = maxY - 90;

    // ---- Strobe Button (center) ----
    if (g_strobeEnabled) {
        UIButton *strobeBtn = createButton(self, @selector(strobe_on),
            ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/sos.png"));
        setter_kStrobeKey(self, strobeBtn);
        strobeBtn.center = CGPointMake(midX, btnY);
        [view addSubview:strobeBtn];
    }

    // ---- SOS Button (left) ----
    if (g_morseEnabled) {
        UIButton *sosBtn = createButton(self, @selector(morse),
            ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/sos.png"));
        setter_kSosKey(self, sosBtn);
        sosBtn.center = CGPointMake(midX - 90, btnY);
        [view addSubview:sosBtn];
    }

    // ---- Timer Button (right) ----
    if (g_timerEnabled) {
        UIButton *timerBtn = createButton(self, @selector(tempo),
            ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/timer.png"));
        setter_kTimerBtnKey(self, timerBtn);
        timerBtn.center = CGPointMake(midX + 90, btnY);
        [view addSubview:timerBtn];
    }
}

// MARK: - viewWillDisappear: (hooked)
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    // Stop all running timers and turn off flashlight
    [getter_kStrobeTimerKey(self) invalidate];
    setter_kStrobeTimerKey(self, nil);
    [getter_kTimerKey(self) invalidate];
    setter_kTimerKey(self, nil);
    setFlashlightLevel(0.0f);
    g_strobeActive = NO;
    g_sosActive = NO;
    g_timerActive = NO;
}

// ============================================================
// STROBOSCOPIC LIGHT EFFECT
// Rapidly flashes the flashlight on/off
// ============================================================
%new
- (void)strobe_on {
    AudioServicesPlaySystemSound(1519);

    // Prevent conflicting with other modes
    if (g_sosActive || g_timerActive) return;

    g_strobeActive = !g_strobeActive;

    if (g_strobeActive) {
        // Hide other buttons
        [getter_kSosKey(self) setHidden:YES];
        [getter_kTimerBtnKey(self) setHidden:YES];
        [getter_kStrobeKey(self) setAlpha:1.0];

        // Stroboscopic timer: rapidly toggle flashlight at ~12.5 Hz (80ms interval)
        __weak id weakSelf = self;
        NSTimer *st = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES
            block:^(NSTimer *t) {
                // Toggle flashlight on/off for stroboscopic effect
                static BOOL flashOn = NO;
                flashOn = !flashOn;
                setFlashlightLevel(flashOn ? 1.0f : 0.0f);

                // Animate button image through mirrorball frames for visual feedback
                static int frame = 0;
                frame++;
                if (frame > 12) frame = 1;
                NSString *path = [NSString stringWithFormat:
                    ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/mirrorball/%i.png"), frame];
                [getter_kStrobeKey(weakSelf) setBackgroundImage:
                    [UIImage imageWithContentsOfFile:path] forState:UIControlStateNormal];
            }];
        setter_kStrobeTimerKey(self, st);
    } else {
        // Stop stroboscopic effect
        [getter_kStrobeTimerKey(self) invalidate];
        setter_kStrobeTimerKey(self, nil);
        setFlashlightLevel(0.0f);
        [getter_kStrobeKey(self) setAlpha:0.25];

        // Restore buttons & original image
        if (g_morseEnabled) [getter_kSosKey(self) setHidden:NO];
        if (g_timerEnabled) [getter_kTimerBtnKey(self) setHidden:NO];
        UIImage *img = [UIImage imageWithContentsOfFile:
            ROOT_PATH_NS(@"/var/mobile/Documents/Tenmetsu/sos.png")];
        [getter_kStrobeKey(self) setBackgroundImage:img forState:UIControlStateNormal];
    }
}

// ============================================================
// TIMER — Turn on flashlight, auto-off after selected seconds
// ============================================================
%new
- (void)tempo {
    AudioServicesPlaySystemSound(1519);

    // Prevent conflicting with other modes
    if (g_strobeActive || g_sosActive) return;

    if (!g_timerActive) {
        [(id)self performSelector:@selector(showPicker)];
    } else {
        [(id)self performSelector:@selector(timerOff)];
    }
}

%new
- (void)showPicker {
    // Hide all buttons while picker is shown
    [getter_kStrobeKey(self) setHidden:YES];
    [getter_kSosKey(self) setHidden:YES];
    [getter_kTimerBtnKey(self) setHidden:YES];

    // Clean up any running timers
    [getter_kTimerKey(self) invalidate];
    setter_kTimerKey(self, nil);
    setFlashlightLevel(0.0f);

    UIView *view = ((UIView * (*)(id, SEL))objc_msgSend)(self, sel_getUid("view"));
    if (!view) return;

    // Build picker data array if needed
    if (!g_arrPicker) {
        g_arrPicker = [NSMutableArray array];
        for (int i = 1; i <= 240; i++) {
            [g_arrPicker addObject:@(i)];
        }
    }

    // Remove any existing picker/toolbar
    [getter_kPickerKey(self) removeFromSuperview];
    [getter_kToolBarKey(self) removeFromSuperview];

    // Create picker
    UIPickerView *picker = [[UIPickerView alloc] init];
    picker.frame = CGRectMake(0, 0, view.frame.size.width, view.frame.size.height * 0.25);
    picker.dataSource = (id<UIPickerViewDataSource>)self;
    picker.delegate = (id<UIPickerViewDelegate>)self;
    picker.backgroundColor = [UIColor systemGrayColor];
    picker.alpha = 0.95;
    setter_kPickerKey(self, picker);

    CGFloat pickerH = picker.frame.size.height;
    CGFloat pickerY = CGRectGetMaxY(view.bounds) - pickerH;
    picker.center = CGPointMake(CGRectGetMidX(view.bounds), pickerY - 22);
    [view addSubview:picker];
    [picker reloadAllComponents];

    // Restore previously selected row
    int savedSec = g_selectedSeconds;
    if (savedSec < 1) savedSec = 10;
    [picker selectRow:(savedSec - 1) inComponent:0 animated:NO];

    // Create toolbar with Done button
    UIToolbar *toolBar = [[UIToolbar alloc] init];
    toolBar.frame = CGRectMake(0, pickerY - pickerH - 0, view.frame.size.width, 44);
    toolBar.barStyle = UIBarStyleBlack;
    toolBar.translucent = YES;
    setter_kToolBarKey(self, toolBar);

    UIBarButtonItem *doneBtn = [[UIBarButtonItem alloc] initWithTitle:@"Done"
                                style:UIBarButtonItemStyleDone
                                target:self action:@selector(startTimer)];
    doneBtn.tintColor = [UIColor whiteColor];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc]
                             initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                             target:nil action:nil];
    [toolBar setItems:@[flex, doneBtn]];
    [view addSubview:toolBar];
}

%new
- (void)startTimer {
    // Remove picker & toolbar
    [getter_kPickerKey(self) removeFromSuperview];
    [getter_kToolBarKey(self) removeFromSuperview];

    g_timerActive = YES;

    // Ensure we have a valid duration
    int duration = g_selectedSeconds;
    if (duration < 1) duration = 10;

    // Turn on flashlight
    setFlashlightLevel(1.0f);
    [getter_kTimerBtnKey(self) setAlpha:1.0];
    [getter_kTimerBtnKey(self) setHidden:NO];
    [getter_kStrobeKey(self) setHidden:YES];
    [getter_kSosKey(self) setHidden:YES];

    // Schedule auto-off timer
    __weak id weakSelf = self;
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:duration repeats:NO
        block:^(NSTimer *tm) {
            [weakSelf performSelector:@selector(timerOff)];
        }];
    setter_kTimerKey(self, t);
}

%new
- (void)timerOff {
    AudioServicesPlaySystemSound(1519);
    g_timerActive = NO;

    [getter_kTimerKey(self) invalidate];
    setter_kTimerKey(self, nil);
    setFlashlightLevel(0.0f);

    [getter_kTimerBtnKey(self) setAlpha:0.25];

    // Restore all buttons
    if (g_strobeEnabled) [getter_kStrobeKey(self) setHidden:NO];
    if (g_morseEnabled) [getter_kSosKey(self) setHidden:NO];
    if (g_timerEnabled) [getter_kTimerBtnKey(self) setHidden:NO];
}

// ============================================================
// SOS Morse Code
// ============================================================
%new
- (void)morse {
    AudioServicesPlaySystemSound(1519);

    // Prevent conflicting with other modes
    if (g_strobeActive || g_timerActive) return;

    g_sosActive = !g_sosActive;

    if (g_sosActive) {
        // Starting — hide other buttons
        [getter_kStrobeKey(self) setHidden:YES];
        [getter_kTimerBtnKey(self) setHidden:YES];
        [getter_kSosKey(self) setAlpha:1.0];
        setFlashlightLevel(0.0f);

        // Show "please wait" label
        UILabel *label = [[UILabel alloc] init];
        label.text = @"SOS in progress...";
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

        [UIView animateWithDuration:0.5 delay:2.0
            options:UIViewAnimationOptionCurveEaseInOut
            animations:^{ label.alpha = 0.0; }
            completion:^(BOOL finished) { [label removeFromSuperview]; }];

        // Run SOS morse code in background thread
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            // S O S pattern: dot-dot-dot  dash-dash-dash  dot-dot-dot
            // dot = 0.2s on, 0.2s off; dash = 0.6s on, 0.2s off
            for (int cycle = 0; cycle < 3; cycle++) {
                // Three dots (S)
                for (int j = 0; j < 3; j++) {
                    setFlashlightLevel(1.0f);
                    [NSThread sleepForTimeInterval:0.2];
                    setFlashlightLevel(0.0f);
                    [NSThread sleepForTimeInterval:0.2];
                }
                // Small gap between S and O
                [NSThread sleepForTimeInterval:0.2];
                // Three dashes (O)
                for (int j = 0; j < 3; j++) {
                    setFlashlightLevel(1.0f);
                    [NSThread sleepForTimeInterval:0.6];
                    setFlashlightLevel(0.0f);
                    [NSThread sleepForTimeInterval:0.2];
                }
                // Small gap between O and S
                [NSThread sleepForTimeInterval:0.2];
                // Three dots (S)
                for (int j = 0; j < 3; j++) {
                    setFlashlightLevel(1.0f);
                    [NSThread sleepForTimeInterval:0.2];
                    setFlashlightLevel(0.0f);
                    [NSThread sleepForTimeInterval:0.2];
                }
                // Gap between SOS repetitions
                [NSThread sleepForTimeInterval:0.6];
            }

            // All done — turn off flashlight and restore UI
            dispatch_async(dispatch_get_main_queue(), ^{
                setFlashlightLevel(0.0f);
                g_sosActive = NO;
                [getter_kSosKey(self) setAlpha:0.25];
                if (g_strobeEnabled) [getter_kStrobeKey(self) setHidden:NO];
                if (g_timerEnabled) [getter_kTimerBtnKey(self) setHidden:NO];
            });
        });
    } else {
        // User tapped again to cancel
        g_sosActive = NO;
        [getter_kSosKey(self) setAlpha:0.25];
        setFlashlightLevel(0.0f);
        if (g_strobeEnabled) [getter_kStrobeKey(self) setHidden:NO];
        if (g_timerEnabled) [getter_kTimerBtnKey(self) setHidden:NO];
    }
}

// ============================================================
// Picker dismiss
// ============================================================
%new
- (void)dismissp {
    [getter_kPickerKey(self) removeFromSuperview];
    [getter_kToolBarKey(self) removeFromSuperview];
    if (g_strobeEnabled) [getter_kStrobeKey(self) setHidden:NO];
    if (g_morseEnabled) [getter_kSosKey(self) setHidden:NO];
    if (g_timerEnabled) [getter_kTimerBtnKey(self) setHidden:NO];
}

// ============================================================
// UIPickerViewDataSource
// ============================================================
%new
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

%new
- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return (NSInteger)[g_arrPicker count];
}

// ============================================================
// UIPickerViewDelegate
// ============================================================
%new
- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row
   forComponent:(NSInteger)component {
    return [NSString stringWithFormat:@"%ld seconds", (long)[g_arrPicker[row] integerValue]];
}

%new
- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row
   inComponent:(NSInteger)component {
    g_selectedSeconds = (int)[g_arrPicker[row] integerValue];
    [g_prefs setInteger:g_selectedSeconds forKey:@"seconds"];
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
