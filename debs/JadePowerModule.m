// JadePowerModule.m
// Power control module with shutdown, restart, respring, safe mode, and lock buttons

#import "JadePowerModule.h"
#import <spawn.h>
#import <UIKit/UIKit.h>

@interface JadePowerModule ()
@property (nonatomic, strong) NSUserDefaults *powerPrefs;
@end

@implementation JadePowerModule

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _powerPrefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.huayuarc.jade.power"];
        _showsConfirmationDialogs = YES;
        _buttonsPerRow = 5;
        _isExpanded = NO;

        [self setupViews];
        [self setupConstraints];
    }
    return self;
}

#pragma mark - View Setup

- (void)setupViews {
    // Title Label
    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"Power";
    _titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor labelColor];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_titleLabel];

    // Buttons Stack View
    _buttonsStackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _buttonsStackView.axis = UILayoutConstraintAxisHorizontal;
    _buttonsStackView.distribution = UIStackViewDistributionEqualSpacing;
    _buttonsStackView.alignment = UIStackViewAlignmentCenter;
    _buttonsStackView.spacing = 8;
    _buttonsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_buttonsStackView];

    // Action Buttons Array
    _actionButtons = [NSMutableArray array];

    // Create default buttons
    [self addButtonWithActionType:JadePowerActionTypeRestart];
    [self addButtonWithActionType:JadePowerActionTypeShutdown];
    [self addButtonWithActionType:JadePowerActionTypeRespring];
    [self addButtonWithActionType:JadePowerActionTypeSafeMode];
    [self addButtonWithActionType:JadePowerActionTypeLockDevice];

    [self applyButtonColors];
}

- (void)setupConstraints {
    [NSLayoutConstraint activateConstraints:@[
        // Title Label
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],

        // Buttons Stack View
        [_buttonsStackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [_buttonsStackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [_buttonsStackView.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:12],
        [_buttonsStackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
    ]];
}

#pragma mark - Button Management

- (void)reloadButtons {
    // Remove all existing buttons
    for (JadePowerModuleButton *button in self.actionButtons) {
        [self.buttonsStackView removeArrangedSubview:button];
        [button removeFromSuperview];
    }
    [self.actionButtons removeAllObjects];

    // Re-add default buttons
    [self addButtonWithActionType:JadePowerActionTypeRestart];
    [self addButtonWithActionType:JadePowerActionTypeShutdown];
    [self addButtonWithActionType:JadePowerActionTypeRespring];
    [self addButtonWithActionType:JadePowerActionTypeSafeMode];
    [self addButtonWithActionType:JadePowerActionTypeLockDevice];

    [self applyButtonColors];
}

- (void)addButtonWithActionType:(JadePowerActionType)actionType {
    JadePowerModuleButton *button = [JadePowerModuleButton buttonWithActionType:actionType];
    [button addTarget:self action:@selector(_buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.actionButtons addObject:button];
    [self.buttonsStackView addArrangedSubview:button];
}

- (void)removeButtonWithActionType:(JadePowerActionType)actionType {
    JadePowerModuleButton *foundButton = nil;
    for (JadePowerModuleButton *button in self.actionButtons) {
        if (button.actionType == actionType) {
            foundButton = button;
            break;
        }
    }
    if (foundButton) {
        [self.actionButtons removeObject:foundButton];
        [self.buttonsStackView removeArrangedSubview:foundButton];
        [foundButton removeFromSuperview];
    }
}

#pragma mark - Button Actions

- (void)_buttonTapped:(JadePowerModuleButton *)button {
    [self performAction:button.actionType];
}

- (void)performAction:(JadePowerActionType)actionType {
    switch (actionType) {
        case JadePowerActionTypeRestart:
            [self _performReboot];
            break;
        case JadePowerActionTypeShutdown:
            [self _performShutdown];
            break;
        case JadePowerActionTypeRespring:
            [self _performRespring];
            break;
        case JadePowerActionTypeSafeMode:
            [self _performSafeMode];
            break;
        case JadePowerActionTypeLockDevice:
            [self _performLock];
            break;
        case JadePowerActionTypeExit:
            // No-op
            break;
    }
}

#pragma mark - Reboot

- (void)_performReboot {
    if (!self.showsConfirmationDialogs) {
        [self _executeReboot];
        return;
    }

    BOOL useUserspace = [self.powerPrefs boolForKey:@"useUserspaceRebootInsteadOfReboot"];

    NSString *titleKey = useUserspace ? @"USERSPACE_REBOOT_DEVICE" : @"REBOOT_DEVICE";
    NSString *messageKey = useUserspace ? @"USERSPACE_REBOOT_DEVICE_DISCLAIMER" : @"REBOOT_DEVICE_DISCLAIMER";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(titleKey, nil)
                                                                   message:NSLocalizedString(messageKey, nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"CANCEL", nil)
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil];
    UIAlertAction *continueAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"CONTINUE", nil)
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(UIAlertAction *action) {
                                                              [self _executeReboot];
                                                          }];

    [alert addAction:cancelAction];
    [alert addAction:continueAction];

    [self._topViewController presentViewController:alert animated:YES completion:nil];
}

- (void)_executeReboot {
    BOOL useUserspace = [self.powerPrefs boolForKey:@"useUserspaceRebootInsteadOfReboot"];

    if (useUserspace) {
        [self _posixSpawnWithArguments:@[@"/var/jb/usr/bin/launchctl", @"reboot", @"userspace"]];
    } else {
        [self _posixSpawnWithArguments:@[@"/sbin/reboot"]];
    }
}

#pragma mark - Shutdown

- (void)_performShutdown {
    if (!self.showsConfirmationDialogs) {
        [self _executeShutdown];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"SHUTDOWN_DEVICE", nil)
                                                                   message:NSLocalizedString(@"SHUTDOWN_DEVICE_DISCLAIMER", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"CANCEL", nil)
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil];
    UIAlertAction *continueAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"CONTINUE", nil)
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(UIAlertAction *action) {
                                                              [self _executeShutdown];
                                                          }];

    [alert addAction:cancelAction];
    [alert addAction:continueAction];

    [self._topViewController presentViewController:alert animated:YES completion:nil];
}

- (void)_executeShutdown {
    // FBSystemService shutdownWithOptions:
    Class fbSystemService = NSClassFromString(@"FBSystemService");
    if (fbSystemService) {
        SEL sharedServiceSel = NSSelectorFromString(@"sharedInstance");
        SEL shutdownSel = NSSelectorFromString(@"shutdownWithOptions:");

        IMP sharedImp = [fbSystemService methodForSelector:sharedServiceSel];
        id (*sharedFunc)(id, SEL) = (void *)sharedImp;
        id service = sharedFunc(fbSystemService, sharedServiceSel);

        IMP shutdownImp = [service methodForSelector:shutdownSel];
        void (*shutdownFunc)(id, SEL, id) = (void *)shutdownImp;
        shutdownFunc(service, shutdownSel, @{});
    }
}

#pragma mark - Respring

- (void)_performRespring {
    BOOL useSbreload = [self.powerPrefs boolForKey:@"useSbreloadInsteadOfBackboardd"];
    if (useSbreload) {
        [self _posixSpawnWithArguments:@[@"/var/jb/usr/bin/sbreload"]];
    } else {
        [self _posixSpawnWithArguments:@[@"/var/jb/usr/bin/killall", @"SpringBoard"]];
    }
}

#pragma mark - Safe Mode

- (void)_performSafeMode {
    // Create safe mode touch file, then kill SpringBoard
    NSString *safeModePath = @"/var/mobile/Library/Preferences/com.apple.springboard.safemode";
    [[NSFileManager defaultManager] createFileAtPath:safeModePath
                                            contents:[NSData data]
                                          attributes:nil];

    [self _posixSpawnWithArguments:@[@"/var/jb/usr/bin/killall", @"SpringBoard"]];
}

#pragma mark - Lock Device

- (void)_performLock {
    // SBLockScreenManager _simulateLockButtonPress
    Class lockScreenManagerClass = NSClassFromString(@"SBLockScreenManager");
    if (lockScreenManagerClass) {
        SEL sharedManagerSel = NSSelectorFromString(@"sharedInstance");
        SEL simulateLockSel = NSSelectorFromString(@"_simulateLockButtonPress");

        IMP sharedImp = [lockScreenManagerClass methodForSelector:sharedManagerSel];
        id (*sharedFunc)(id, SEL) = (void *)sharedImp;
        id manager = sharedFunc(lockScreenManagerClass, sharedManagerSel);

        if ([manager respondsToSelector:simulateLockSel]) {
            IMP simulateImp = [manager methodForSelector:simulateLockSel];
            void (*simulateFunc)(id, SEL) = (void *)simulateImp;
            simulateFunc(manager, simulateLockSel);
        }
    }
}

#pragma mark - posix_spawn Helper

- (void)_posixSpawnWithArguments:(NSArray<NSString *> *)arguments {
    if (arguments.count == 0) return;

    // Prepare argv
    NSUInteger argc = [arguments count];
    char **argv = (char **)calloc(argc + 1, sizeof(char *));

    for (NSUInteger i = 0; i < argc; i++) {
        argv[i] = (char *)[arguments[i] UTF8String];
    }
    argv[argc] = NULL;

    // Spawn with no special flags - detach from process
    pid_t pid;
    int status = posix_spawn(&pid, argv[0], NULL, NULL, argv, NULL);
    if (status != 0) {
        NSLog(@"[Jade] posix_spawn failed for %s: %d (%s)", argv[0], status, strerror(status));
    }

    free(argv);
}

#pragma mark - Color Preferences

- (void)applyButtonColors {
    NSDictionary *colorKeys = @{
        @(JadePowerActionTypeRestart): @"rebootColor",
        @(JadePowerActionTypeShutdown): @"shutdownColor",
        @(JadePowerActionTypeRespring): @"respringColor",
        @(JadePowerActionTypeSafeMode): @"safeModeColor",
        @(JadePowerActionTypeLockDevice): @"lockColor",
    };

    BOOL colorGlyphs = [self.powerPrefs boolForKey:@"colorPowerGlyphsInsteadOfBackgrounds"];

    for (JadePowerModuleButton *button in self.actionButtons) {
        NSString *colorKey = colorKeys[@(button.actionType)];
        NSString *colorHex = [self.powerPrefs stringForKey:colorKey];

        UIColor *color = [UIColor systemGrayColor];
        if (colorHex) {
            color = [self _colorFromHexString:colorHex] ?: [UIColor systemGrayColor];
        }

        if (colorGlyphs) {
            button.buttonColor = [UIColor secondarySystemBackgroundColor];
            button.iconTintColor = color;
        } else {
            button.buttonColor = color;
            button.iconTintColor = [UIColor whiteColor];
        }
    }
}

- (void)setModuleTintColor:(UIColor *)moduleTintColor {
    _moduleTintColor = moduleTintColor;
    self.titleLabel.textColor = moduleTintColor;
}

#pragma mark - Expanded State

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    _isExpanded = expanded;
    NSTimeInterval duration = animated ? 0.25 : 0.0;

    [UIView animateWithDuration:duration animations:^{
        self.buttonsStackView.alpha = expanded ? 1.0 : 0.0;
    }];
}

#pragma mark - Utility

- (UIColor *)_colorFromHexString:(NSString *)hexString {
    NSString *cleanString = [hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([cleanString hasPrefix:@"#"]) {
        cleanString = [cleanString substringFromIndex:1];
    }
    if ([cleanString hasPrefix:@"0x"]) {
        cleanString = [cleanString substringFromIndex:2];
    }

    NSUInteger length = [cleanString length];
    if (length != 6 && length != 8) return nil;

    NSScanner *scanner = [NSScanner scannerWithString:cleanString];
    unsigned long long hexValue = 0;
    if (![scanner scanHexLongLong:&hexValue]) return nil;

    CGFloat red, green, blue, alpha;
    if (length == 8) {
        red   = ((hexValue & 0xFF000000) >> 24) / 255.0;
        green = ((hexValue & 0x00FF0000) >> 16) / 255.0;
        blue  = ((hexValue & 0x0000FF00) >> 8)  / 255.0;
        alpha =  (hexValue & 0x000000FF)         / 255.0;
    } else {
        red   = ((hexValue & 0xFF0000) >> 16) / 255.0;
        green = ((hexValue & 0x00FF00) >> 8)  / 255.0;
        blue  =  (hexValue & 0x0000FF)        / 255.0;
        alpha = 1.0;
    }

    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

- (UIWindow *)_activeKeyWindow {
    if (@available(iOS 13.0, *)) {
        UIWindow *fallbackWindow = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (!fallbackWindow) fallbackWindow = window;
                if (window.isKeyWindow) return window;
            }
        }
        return fallbackWindow;
    }

    return nil;
}

- (UIViewController *)_topViewController {
    UIViewController *topController = [self _activeKeyWindow].rootViewController;

    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}


@end
