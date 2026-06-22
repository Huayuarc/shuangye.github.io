#import "DIDisplayManager.h"
#import "DIWindow.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import "DILocalization.h"

#define kPrefsID @"com.dynamicisland.tweak"

typedef Boolean (*MRMediaRemoteSendCommand_t)(unsigned int command, id userInfo);
typedef void (*MRMediaRemoteSetElapsedTime_t)(double elapsedTime);
static MRMediaRemoteSendCommand_t _MRSendCommand = NULL;
static MRMediaRemoteSetElapsedTime_t _MRSetElapsedTime = NULL;

// LSApplicationWorkspace 用于跳转 App
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID configuration:(id)cfg;
@end

// FBSSystemService — SpringBoard 内激活 App 的标准私有路径
// /System/Library/PrivateFrameworks/FrontBoardServices.framework
@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)openApplication:(NSString *)bundleID
                options:(NSDictionary *)options
             withResult:(void (^)(NSError *error))handler;
@end

enum {
    kMRTogglePlayPause = 2,
    kMRNextTrack = 4,
    kMRPreviousTrack = 5,
};

static void loadMediaRemoteCommandsIfNeeded(void) {
    if (_MRSendCommand && _MRSetElapsedTime) return;
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return;
    _MRSendCommand = (MRMediaRemoteSendCommand_t)dlsym(handle, "MRMediaRemoteSendCommand");
    _MRSetElapsedTime = (MRMediaRemoteSetElapsedTime_t)dlsym(handle, "MRMediaRemoteSetElapsedTime");
}

@interface DIDisplayManager ()
@property (nonatomic, assign) BOOL didSetup;
@property (nonatomic, strong) DIWindow *overlayWindow;
@property (nonatomic, strong) NSTimer *reappearTimer;
@property (nonatomic, strong) NSTimer *notificationTimer;
@property (nonatomic, assign, readwrite) BOOL mediaActive;
@property (nonatomic, copy) NSString *nowPlayingBundleID;
@property (nonatomic, copy) NSString *lastTitle;
@property (nonatomic, copy) NSString *lastArtist;
@property (nonatomic, strong) UIImage *lastArtwork;
@property (nonatomic, assign) BOOL lastPlaying;
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) CGFloat reappearDelay;
@property (nonatomic, assign, readwrite) BOOL showingNotification;
// 通知灵动岛
@property (nonatomic, assign, readwrite) BOOL bannerEnabled;
@property (nonatomic, assign, readwrite) CGFloat bannerCornerRadius;
@property (nonatomic, assign, readwrite) CGFloat bannerDamping;
@property (nonatomic, assign, readwrite) CGFloat bannerInitialScale;
@property (nonatomic, assign, readwrite) CGFloat notifDuration;
// 双圆角
@property (nonatomic, assign, readwrite) CGFloat mediaCornerRadius;
@property (nonatomic, assign, readwrite) CGFloat notifCornerRadius;
@end

@implementation DIDisplayManager

+ (instancetype)sharedInstance {
    static DIDisplayManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (void)setup {
    if (self.didSetup) return;
    self.didSetup = YES;
    [self reloadPrefs];
}

- (DIWindow *)ensureOverlayWindow {
    if (![NSThread isMainThread]) {
        return nil;
    }

    if (!self.overlayWindow && self.enabled) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        self.overlayWindow = [[DIWindow alloc] initWithFrame:bounds];
        self.overlayWindow.contentView.delegate = self;
        if (self.overlayWindow) [self.overlayWindow.contentView reloadPrefs];
    }
    return self.overlayWindow;
}

- (void)reloadPrefs {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kPrefsID];
    self.enabled = [prefs objectForKey:@"islandEnabled"] ? [prefs boolForKey:@"islandEnabled"] : NO;
    self.reappearDelay = [prefs objectForKey:@"reappearDelay"] ? [prefs floatForKey:@"reappearDelay"] : 1.0;
    // 通知灵动岛偏好
    self.bannerEnabled = [prefs objectForKey:@"notificationEnabled"] ? [prefs boolForKey:@"notificationEnabled"] : NO;
    self.bannerCornerRadius = [prefs objectForKey:@"bannerCornerRadius"] ? [prefs floatForKey:@"bannerCornerRadius"] : 22.0;
    self.bannerDamping = [prefs objectForKey:@"bannerDamping"] ? [prefs floatForKey:@"bannerDamping"] : 0.7;
    self.bannerInitialScale = [prefs objectForKey:@"bannerInitialScale"] ? [prefs floatForKey:@"bannerInitialScale"] : 0.8;
    self.notifDuration = [prefs objectForKey:@"notifDuration"] ? [prefs floatForKey:@"notifDuration"] : 3.0;
    if (self.notifDuration < 1.0) self.notifDuration = 1.0;
    if (self.notifDuration > 30.0) self.notifDuration = 30.0;
    // 双圆角
    self.mediaCornerRadius = [prefs objectForKey:@"mediaCornerRadius"] ? [prefs floatForKey:@"mediaCornerRadius"] : 18.0;
    self.notifCornerRadius = [prefs objectForKey:@"notifCornerRadius"] ? [prefs floatForKey:@"notifCornerRadius"] : 22.0;
    if (!self.enabled && self.overlayWindow) {
        [self.reappearTimer invalidate];
        self.reappearTimer = nil;
        [self.notificationTimer invalidate];
        self.notificationTimer = nil;
        [self.overlayWindow.contentView hide];
        [self.overlayWindow hide];
    }
    if (self.overlayWindow) [self.overlayWindow.contentView reloadPrefs];
}

#pragma mark - Notification Integration

- (void)cancelDelayedHide {
    [self.delayedHideTimer invalidate];
    self.delayedHideTimer = nil;
}

- (void)pauseNotificationTimer {
    [self.notificationTimer invalidate];
    self.notificationTimer = nil;
}

- (void)resumeNotificationTimer {
    [self.notificationTimer invalidate];
    self.notificationTimer = [NSTimer scheduledTimerWithTimeInterval:self.notifDuration
                                                             target:self
                                                           selector:@selector(notificationTimerFired)
                                                           userInfo:nil
                                                            repeats:NO];
}

- (void)showNotificationWithTitle:(NSString *)title message:(NSString *)message icon:(UIImage *)icon bundleID:(NSString *)bundleID {
    if (!self.bannerEnabled) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        // 取消任何待执行的延迟隐藏（连续通知场景）
        [self cancelDelayedHide];

        self.showingNotification = YES;
        [self.notificationTimer invalidate];

        // 通知优先级最高：直接关闭音乐 reappear timer
        [self.reappearTimer invalidate];
        self.reappearTimer = nil;

        DIWindow *window = [self ensureOverlayWindow];
        if (!window) return;
        DIContentView *cv = window.contentView;
        cv.notifBundleID = bundleID;

        [window show];
        [cv showNotificationWithTitle:title message:message icon:icon];

        // 自定义时长后自动隐藏通知
        self.notificationTimer = [NSTimer scheduledTimerWithTimeInterval:self.notifDuration
                                                                 target:self
                                                               selector:@selector(notificationTimerFired)
                                                               userInfo:nil
                                                                repeats:NO];
    });
}

- (void)hideNotification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.overlayWindow) return;
        [self.notificationTimer invalidate];
        self.notificationTimer = nil;
        self.showingNotification = NO;

        // 如果音乐还在播放，切回音乐岛
        if (self.mediaActive && self.lastPlaying) {
            [[self ensureOverlayWindow].contentView switchToMedia];
        } else {
            [[self ensureOverlayWindow].contentView hideNotification];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!self.showingNotification && !self.mediaActive) {
                    [self.overlayWindow hide];
                }
            });
        }
    });
}

// 用户上滑 / 左滑立即关闭通知（无动画延迟，避免与音乐岛重叠）
- (void)hideNotificationImmediate {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.overlayWindow) return;
        [self.notificationTimer invalidate];
        self.notificationTimer = nil;
        [self cancelDelayedHide];
        self.showingNotification = NO;

        DIWindow *window = [self ensureOverlayWindow];
        if (!window) return;
        DIContentView *cv = window.contentView;
        if (self.mediaActive && self.lastPlaying) {
            // 立即隐藏通知，再显示音乐
            [cv hideNotificationImmediate];
            // 给一个短暂延迟，等通知收起动画完成再显示音乐
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.mediaActive && self.lastPlaying && !self.showingNotification) {
                    [self showMediaWithTitle:self.lastTitle artist:self.lastArtist playing:YES artwork:self.lastArtwork bundleID:self.nowPlayingBundleID];
                }
            });
        } else {
            [cv hideNotificationImmediate];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!self.showingNotification && !self.mediaActive) {
                    [self.overlayWindow hide];
                }
            });
        }
    });
}

- (void)notificationTimerFired {
    [self hideNotification];
}

- (void)showMediaWithTitle:(NSString *)title artist:(NSString *)artist playing:(BOOL)playing artwork:(UIImage *)artwork bundleID:(NSString *)bundleID {
    if (!self.enabled) return;

    self.lastTitle = title;
    self.lastArtist = artist;
    self.lastPlaying = playing;
    self.lastArtwork = artwork;
    if (bundleID) self.nowPlayingBundleID = bundleID;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!playing) {
            self.mediaActive = NO;
            // 如果当前在显示通知，不要因为音乐停了把通知也隐藏
            if (self.showingNotification) return;
            [self dismiss];
            return;
        }

        self.mediaActive = YES;

        // 通知岛优先级最高：通知期间不更新音乐岛
        if (self.showingNotification) {
            return;
        }

        [self.reappearTimer invalidate];
        DIWindow *window = [self ensureOverlayWindow];
        if (!window) return;
        [window show];

        DIContentView *cv = window.contentView;
        BOOL alreadyVisible = (cv.state != DIStateHidden && cv.contentType == DIContentTypeMedia);

        if (alreadyVisible) {
            cv.titleText = title ?: DILocalizedString(@"DI_UNKNOWN_SONG");
            cv.subtitleText = artist ?: @"";
            [cv updateTitleDisplay];
            [cv updatePlaybackState:playing];
            [cv updateArtwork:artwork];
        } else {
            [cv updateArtwork:artwork];
            [cv showWithTitle:(title ?: DILocalizedString(@"DI_UNKNOWN_SONG")) subtitle:(artist ?: @"")];
            [cv updatePlaybackState:playing];
        }
    });
}

- (void)updateMediaArtwork:(UIImage *)artwork {
    if (!self.enabled) return;
    self.lastArtwork = artwork;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.mediaActive) return;
        DIContentView *cv = self.overlayWindow.contentView;
        if (cv) [cv updateArtwork:artwork];
    });
}

- (void)dismiss {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.overlayWindow) return;
        [self.overlayWindow.contentView hide];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self.overlayWindow.contentView.state == DIStateHidden) {
                [self.overlayWindow hide];
            }
        });
    });
}

- (void)userDismissAndScheduleReappear {
    [self dismiss];
    if (self.mediaActive && self.lastPlaying) {
        [self.reappearTimer invalidate];
        self.reappearTimer = [NSTimer scheduledTimerWithTimeInterval:self.reappearDelay
                                                             target:self
                                                           selector:@selector(reappearFired)
                                                           userInfo:nil
                                                            repeats:NO];
    }
}

- (void)reappearFired {
    if (self.mediaActive && self.lastPlaying && !self.showingNotification) {
        [self showMediaWithTitle:self.lastTitle artist:self.lastArtist playing:YES artwork:self.lastArtwork bundleID:self.nowPlayingBundleID];
    }
}

- (void)updateElapsed:(NSTimeInterval)elapsed duration:(NSTimeInterval)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 通知岛显示时不更新音乐进度 UI
        if (self.showingNotification) return;
        if (!self.overlayWindow) return;
        [self.overlayWindow.contentView updateElapsed:elapsed duration:duration];
    });
}

#pragma mark - App Launch

- (void)openAppWithBundleID:(NSString *)bundleID {
    if (bundleID.length == 0) return;

    // 异步发起：避免阻塞主线程，FBSSystemService 内部会回到主线程做 scene transition
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 路径 1：FBSSystemService（SpringBoard 内激活 App 的标准私有路径，通常 < 50ms）
        dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        Class fbsCls = NSClassFromString(@"FBSSystemService");
        if (fbsCls) {
            id svc = [fbsCls performSelector:@selector(sharedService)];
            if ([svc respondsToSelector:@selector(openApplication:options:withResult:)]) {
                @try {
                    [svc openApplication:bundleID options:nil withResult:^(NSError *error) {}];
                    return;
                } @catch (__unused NSException *e) { }
            }
        }

        // 路径 2：URL Scheme 兜底
        NSDictionary *knownSchemes = @{
            @"com.apple.Music":          @"music://",
            @"com.spotify.client":       @"spotify://",
            @"com.netease.cloudmusic":   @"orpheuswidget://",
            @"com.tencent.QQMusic":      @"qqmusic://",
            @"com.kugou.kugou":          @"kugou://",
            @"com.wenyu.bodian":         @"bodian://",
            @"com.tencent.xin":          @"weixin://",
            @"com.tencent.mqq":          @"mqq://",
            @"com.tencent.mqqi":         @"mqqi://",
            @"com.alipay.iphoneclient":  @"alipay://",
            @"com.taobao.taobao4iphone": @"taobao://",
            @"com.burbn.instagram":      @"instagram://",
        };
        NSString *scheme = knownSchemes[bundleID];
        if (scheme) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] openURL:[NSURL URLWithString:scheme]
                                                   options:@{}
                                         completionHandler:nil];
            });
        }
    });
}

#pragma mark - Delegate

- (void)contentViewDidRequestDismiss:(DIContentView *)view {
    [self userDismissAndScheduleReappear];
}

- (void)contentViewDidRequestDismissNotification:(DIContentView *)view {
    [self hideNotificationImmediate];
}

- (void)contentViewDidExpandNotification:(DIContentView *)view {
    // 长按展开通知 → 暂停自动消失 timer
    [self pauseNotificationTimer];
}

- (void)contentViewDidCollapseNotification:(DIContentView *)view {
    // 通知收回紧凑模式 → 恢复 timer
    [self resumeNotificationTimer];
}

- (void)contentViewDidRequestOpenApp:(DIContentView *)view {
    // 通知模式：跳转通知对应的 App
    if (view.contentType == DIContentTypeNotification) {
        NSString *bid = view.notifBundleID;
        if (bid.length > 0) {
            [self openAppWithBundleID:bid];
        }
        // 点击通知后立即关闭
        [self hideNotificationImmediate];
        return;
    }

    // 音乐模式：跳转当前播放音乐的 App
    NSString *bid = self.nowPlayingBundleID;
    if (bid.length > 0) {
        [self openAppWithBundleID:bid];
    } else {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"music://"] options:@{} completionHandler:nil];
    }
}

- (void)contentViewDidRequestPlayPause:(DIContentView *)view {
    loadMediaRemoteCommandsIfNeeded();
    if (_MRSendCommand) _MRSendCommand(kMRTogglePlayPause, nil);
}

- (void)contentViewDidRequestPrevious:(DIContentView *)view {
    loadMediaRemoteCommandsIfNeeded();
    if (_MRSendCommand) _MRSendCommand(kMRPreviousTrack, nil);
}

- (void)contentViewDidRequestNext:(DIContentView *)view {
    loadMediaRemoteCommandsIfNeeded();
    if (_MRSendCommand) _MRSendCommand(kMRNextTrack, nil);
}

- (void)contentViewDidRequestSeek:(DIContentView *)view toPosition:(float)position {
    loadMediaRemoteCommandsIfNeeded();
    if (_MRSetElapsedTime) _MRSetElapsedTime((double)position);
}

@end
