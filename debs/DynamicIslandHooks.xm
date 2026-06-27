#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <sys/syslog.h>
#import "DIDisplayManager.h"
#import "DILocalization.h"

// C 层日志：不依赖 Foundation，dyld 阶段也可用
#define DIRawLog(fmt, ...) syslog(LOG_NOTICE, "[Systempro-DynamicIsland] " fmt, ##__VA_ARGS__)

// 文件日志宏：同时写 /tmp/Systempro-DynamicIsland.log、syslog 和 NSLog，便于崩溃后定位
#define DILog(fmt, ...) do { \
    DIRawLog("%s", [[NSString stringWithFormat:fmt, ##__VA_ARGS__] UTF8String]); \
    NSString *_diMsg = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    NSString *_diLine = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], _diMsg]; \
    @try { \
        NSString *_diPath = @"/tmp/Systempro-DynamicIsland.log"; \
        if (![[NSFileManager defaultManager] fileExistsAtPath:_diPath]) \
            [[NSData data] writeToFile:_diPath atomically:YES]; \
        NSFileHandle *_diH = [NSFileHandle fileHandleForWritingAtPath:_diPath]; \
        if (_diH) { \
            [_diH seekToEndOfFile]; \
            [_diH writeData:[_diLine dataUsingEncoding:NSUTF8StringEncoding]]; \
            [_diH closeFile]; \
        } \
    } @catch (NSException *e) {} \
    NSLog(@"[Tweak] %@", _diMsg); \
} while(0)

typedef void (^MRMediaRemoteGetNowPlayingInfoCompletion)(CFDictionaryRef info);
typedef void (^MRMediaRemoteGetNowPlayingClientCompletion)(id client);
typedef void (*MRMediaRemoteRegisterForNowPlayingNotifications_t)(dispatch_queue_t queue);
typedef void (*MRMediaRemoteGetNowPlayingInfo_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingInfoCompletion completion);
typedef void (*MRMediaRemoteGetNowPlayingClient_t)(dispatch_queue_t queue, MRMediaRemoteGetNowPlayingClientCompletion completion);
typedef NSString *(*MRNowPlayingClientGetBundleIdentifier_t)(id client);
typedef NSString *(*MRNowPlayingClientGetParentAppBundleIdentifier_t)(id client);

static void syncTick(void);
static void fetchNowPlayingInfo(void);
static void initializeTweakAfterLaunch(void);
static BOOL tweakEnabledFromPrefs(void);
static BOOL notificationEnabledFromPrefs(void);
static void scheduleTweakInitialization(void);
static void registerPrefsObserverIfNeeded(void);
static void initializeNotificationHooksIfNeeded(void);
static void startAfterInjection(void);

static NSString *const kDIPrefPath = @"/var/mobile/Library/Preferences/com.huayuarc.systempro.plist";

static void *_mrHandle = NULL;
static MRMediaRemoteRegisterForNowPlayingNotifications_t _MRRegister = NULL;
static MRMediaRemoteGetNowPlayingInfo_t _MRGetNowPlaying = NULL;
static MRMediaRemoteGetNowPlayingClient_t _MRGetNowPlayingClient = NULL;
static MRNowPlayingClientGetBundleIdentifier_t _MRClientGetBundleID = NULL;
static MRNowPlayingClientGetParentAppBundleIdentifier_t _MRClientGetParentBundleID = NULL;
static NSString *_kInfoTitle = nil;
static NSString *_kInfoArtist = nil;
static NSString *_kInfoPlaybackRate = nil;
static NSString *_kInfoArtworkData = nil;
static NSString *_kInfoArtworkURL = nil;
static NSString *_kInfoBundleID = nil;
static NSString *_kPlayingDidChange = nil;
static NSString *_kInfoDidChange = nil;
static NSString *_kInfoElapsedTime = nil;
static NSString *_kInfoDuration = nil;
static NSTimer *_syncTimer = nil;
static BOOL _didInitializeTweak = NO;
static BOOL _didScheduleTweakInitialization = NO;
static BOOL _didRegisterPrefsObserver = NO;
static BOOL _didInitializeNotificationHooks = NO;

static NSString *safeString(id value) {
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL tweakEnabledFromPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kDIPrefPath];
    id value = prefs[@"islandEnabled"];
    return value ? [value boolValue] : NO;
}

static BOOL notificationEnabledFromPrefs(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kDIPrefPath];
    id value = prefs[@"notificationEnabled"];
    return value ? [value boolValue] : NO;
}

static void runOnMainQueue(dispatch_block_t block) {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

static id dictionaryValue(NSDictionary *dictionary, NSString *key) {
    return key ? dictionary[key] : nil;
}

static BOOL loadMediaRemote(void) {
    if (_mrHandle) {
        BOOL cached = (_MRRegister && _MRGetNowPlaying && _kInfoTitle && _kInfoDidChange);
        return cached;
    }

    DILog(@"loadMediaRemote: dlopen MediaRemote...");
    _mrHandle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    if (!_mrHandle) {
        DILog(@"loadMediaRemote: dlopen FAILED: %s", dlerror());
        return NO;
    }
    DILog(@"loadMediaRemote: dlopen ok, handle=%p", _mrHandle);

    _MRRegister = (MRMediaRemoteRegisterForNowPlayingNotifications_t)dlsym(_mrHandle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    _MRGetNowPlaying = (MRMediaRemoteGetNowPlayingInfo_t)dlsym(_mrHandle, "MRMediaRemoteGetNowPlayingInfo");
    _MRGetNowPlayingClient = (MRMediaRemoteGetNowPlayingClient_t)dlsym(_mrHandle, "MRMediaRemoteGetNowPlayingClient");
    _MRClientGetBundleID = (MRNowPlayingClientGetBundleIdentifier_t)dlsym(_mrHandle, "MRNowPlayingClientGetBundleIdentifier");
    _MRClientGetParentBundleID = (MRNowPlayingClientGetParentAppBundleIdentifier_t)dlsym(_mrHandle, "MRNowPlayingClientGetParentAppBundleIdentifier");

    CFStringRef *titlePtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoTitle");
    CFStringRef *artistPtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoArtist");
    CFStringRef *ratePtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoPlaybackRate");
    CFStringRef *artworkPtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoArtworkData");
    CFStringRef *artworkURLPtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoArtworkURL");
    CFStringRef *bundlePtr = (CFStringRef *)dlsym(_mrHandle, "kMRNowPlayingClientBundleIdentifier");
    if (!bundlePtr) bundlePtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoBundleIdentifier");
    CFStringRef *playingChangePtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
    CFStringRef *infoChangePtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoDidChangeNotification");
    CFStringRef *elapsedPtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoElapsedTime");
    CFStringRef *durationPtr = (CFStringRef *)dlsym(_mrHandle, "kMRMediaRemoteNowPlayingInfoDuration");

    DILog(@"sym ptrs: title=%p artist=%p rate=%p artwork=%p artworkURL=%p bundle=%p playingChange=%p infoChange=%p elapsed=%p duration=%p",
        titlePtr, artistPtr, ratePtr, artworkPtr, artworkURLPtr, bundlePtr, playingChangePtr, infoChangePtr, elapsedPtr, durationPtr);
    DILog(@"sym funcs: register=%p get=%p getClient=%p getBundleID=%p getParentBundleID=%p",
        _MRRegister, _MRGetNowPlaying, _MRGetNowPlayingClient, _MRClientGetBundleID, _MRClientGetParentBundleID);

    if (titlePtr) _kInfoTitle = (__bridge NSString *)*titlePtr;
    if (artistPtr) _kInfoArtist = (__bridge NSString *)*artistPtr;
    if (ratePtr) _kInfoPlaybackRate = (__bridge NSString *)*ratePtr;
    if (artworkPtr) _kInfoArtworkData = (__bridge NSString *)*artworkPtr;
    if (artworkURLPtr) _kInfoArtworkURL = (__bridge NSString *)*artworkURLPtr;
    if (bundlePtr) _kInfoBundleID = (__bridge NSString *)*bundlePtr;
    if (playingChangePtr) _kPlayingDidChange = (__bridge NSString *)*playingChangePtr;
    if (infoChangePtr) _kInfoDidChange = (__bridge NSString *)*infoChangePtr;
    if (elapsedPtr) _kInfoElapsedTime = (__bridge NSString *)*elapsedPtr;
    if (durationPtr) _kInfoDuration = (__bridge NSString *)*durationPtr;

    BOOL ok = (_MRRegister && _MRGetNowPlaying && _kInfoTitle && _kInfoDidChange);
    DILog(@"loadMediaRemote result: ok=%d, _kInfoArtworkData=%@, _kInfoArtworkURL=%@, _kInfoBundleID=%@", ok, _kInfoArtworkData, _kInfoArtworkURL, _kInfoBundleID);
    return ok;
}

static void updateSyncTimer(BOOL playing) {
    if (!tweakEnabledFromPrefs()) {
        [_syncTimer invalidate];
        _syncTimer = nil;
        return;
    }
    if (playing) {
        if (!_syncTimer) {
            _syncTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(__unused NSTimer *timer) {
                syncTick();
            }];
        }
    } else {
        [_syncTimer invalidate];
        _syncTimer = nil;
    }
}

static void fetchNowPlayingInfo(void) {
    if (!tweakEnabledFromPrefs()) return;
    if (!_MRGetNowPlaying || !_kInfoTitle) return;

    _MRGetNowPlaying(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        if (!info) {
            DILog(@"fetchNowPlayingInfo: info=nil");
            return;
        }
        NSDictionary *dict = (__bridge NSDictionary *)info;
        if (![dict isKindOfClass:[NSDictionary class]]) {
            DILog(@"fetchNowPlayingInfo: dict wrong class");
            return;
        }

        NSString *title = safeString(dictionaryValue(dict, _kInfoTitle));
        NSString *artist = safeString(dictionaryValue(dict, _kInfoArtist));
        id rateValue = dictionaryValue(dict, _kInfoPlaybackRate);
        NSNumber *rate = [rateValue isKindOfClass:[NSNumber class]] ? rateValue : nil;
        BOOL playing = rate.floatValue > 0;

        UIImage *artwork = nil;
        NSData *artData = dictionaryValue(dict, _kInfoArtworkData);
        NSUInteger artLen = ([artData isKindOfClass:[NSData class]]) ? [artData length] : 0;
        if ([artData isKindOfClass:[NSData class]] && artData.length > 0 && artData.length < 5 * 1024 * 1024) {
            @autoreleasepool {
                artwork = [UIImage imageWithData:artData];
            }
            DILog(@"fetchNowPlayingInfo: title=%@ artist=%@ playing=%d | artData len=%lu image=%@ size=%@",
                title, artist, playing, (unsigned long)artLen, artwork, artwork ? NSStringFromCGSize(artwork.size) : @"(nil)");
        } else {
            DILog(@"fetchNowPlayingInfo: title=%@ artist=%@ playing=%d | artData unavailable (key=%@ dataClass=%@ len=%lu)",
                title, artist, playing, _kInfoArtworkData, [artData class], (unsigned long)artLen);
            // artData 为空，尝试 artworkURL fallback
            if (_kInfoArtworkURL) {
                id artworkURLValue = dictionaryValue(dict, _kInfoArtworkURL);
                NSURL *artworkURL = nil;
                if ([artworkURLValue isKindOfClass:[NSURL class]]) {
                    artworkURL = artworkURLValue;
                } else if ([artworkURLValue isKindOfClass:[NSString class]]) {
                    artworkURL = [NSURL URLWithString:artworkURLValue];
                }
                if (artworkURL) {
                    DILog(@"fetchNowPlayingInfo: trying artworkURL=%@", artworkURL);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        @autoreleasepool {
                            NSData *urlData = [NSData dataWithContentsOfURL:artworkURL];
                            NSUInteger urlLen = (urlData && [urlData isKindOfClass:[NSData class]]) ? [urlData length] : 0;
                            UIImage *urlImage = nil;
                            if (urlLen > 0 && urlLen < 5 * 1024 * 1024) {
                                urlImage = [UIImage imageWithData:urlData];
                            }
                            DILog(@"artworkURL download: dataLen=%lu image=%@ size=%@",
                                (unsigned long)urlLen, urlImage, urlImage ? NSStringFromCGSize(urlImage.size) : @"(nil)");
                            if (urlImage) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [[DIDisplayManager sharedInstance] updateMediaArtwork:urlImage];
                                });
                            }
                        }
                    });
                } else {
                    DILog(@"fetchNowPlayingInfo: artworkURL value missing/invalid (key=%@ valueClass=%@)",
                        _kInfoArtworkURL, [artworkURLValue class]);
                }
            }
        }

        __block NSString *bundleID = safeString(dictionaryValue(dict, _kInfoBundleID));
        NSTimeInterval elapsed = 0;
        NSTimeInterval duration = 0;
        NSNumber *elapsedNumber = dictionaryValue(dict, _kInfoElapsedTime);
        NSNumber *durationNumber = dictionaryValue(dict, _kInfoDuration);
        if ([elapsedNumber isKindOfClass:[NSNumber class]]) elapsed = elapsedNumber.doubleValue;
        if ([durationNumber isKindOfClass:[NSNumber class]]) duration = durationNumber.doubleValue;

        void (^deliver)(NSString *) = ^(NSString *resolvedBundleID) {
            if (title.length > 0 || artist.length > 0) {
                DIDisplayManager *manager = [DIDisplayManager sharedInstance];
                [manager showMediaWithTitle:title artist:artist playing:playing artwork:artwork bundleID:resolvedBundleID];
                [manager updateElapsed:elapsed duration:duration];
            }
            updateSyncTimer(playing);
        };

        if (!bundleID && _MRGetNowPlayingClient && (_MRClientGetBundleID || _MRClientGetParentBundleID)) {
            _MRGetNowPlayingClient(dispatch_get_main_queue(), ^(id client) {
                NSString *resolvedBundleID = nil;
                if (client && _MRClientGetBundleID) resolvedBundleID = _MRClientGetBundleID(client);
                if (resolvedBundleID.length == 0 && client && _MRClientGetParentBundleID) resolvedBundleID = _MRClientGetParentBundleID(client);
                deliver(resolvedBundleID);
            });
        } else {
            deliver(bundleID);
        }
    });
}

static void syncTick(void) {
    if (!tweakEnabledFromPrefs()) return;
    if (!_MRGetNowPlaying) return;

    _MRGetNowPlaying(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        if (!info) return;
        NSDictionary *dict = (__bridge NSDictionary *)info;
        if (![dict isKindOfClass:[NSDictionary class]]) return;

        NSTimeInterval elapsed = 0;
        NSTimeInterval duration = 0;
        NSNumber *elapsedNumber = dictionaryValue(dict, _kInfoElapsedTime);
        NSNumber *durationNumber = dictionaryValue(dict, _kInfoDuration);
        if ([elapsedNumber isKindOfClass:[NSNumber class]]) elapsed = elapsedNumber.doubleValue;
        if ([durationNumber isKindOfClass:[NSNumber class]]) duration = durationNumber.doubleValue;
        [[DIDisplayManager sharedInstance] updateElapsed:elapsed duration:duration];
    });
}

static void prefsChanged(__unused CFNotificationCenterRef center, __unused void *observer, __unused CFStringRef name, __unused const void *object, __unused CFDictionaryRef userInfo) {
    runOnMainQueue(^{
        DIDisplayManager *manager = [DIDisplayManager sharedInstance];
        [manager reloadPrefs];
        if (notificationEnabledFromPrefs()) {
            initializeNotificationHooksIfNeeded();
        }
        if (tweakEnabledFromPrefs()) {
            if (_didInitializeTweak) {
                fetchNowPlayingInfo();
            } else {
                scheduleTweakInitialization();
            }
        } else {
            [_syncTimer invalidate];
            _syncTimer = nil;
        }
    });
}

static void initializeTweakAfterLaunch(void) {
    if (_didInitializeTweak) return;
    if (!tweakEnabledFromPrefs()) {
        DILog(@"initializeTweakAfterLaunch: disabled, skip");
        return;
    }
    _didInitializeTweak = YES;
    DILog(@"initializeTweakAfterLaunch begin");

    DIDisplayManager *manager = [DIDisplayManager sharedInstance];
    [manager setup];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!tweakEnabledFromPrefs()) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BOOL mediaRemoteLoaded = loadMediaRemote();
            DILog(@"mediaRemoteLoaded=%d", mediaRemoteLoaded);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!mediaRemoteLoaded || !tweakEnabledFromPrefs()) return;
                @try {
                    _MRRegister(dispatch_get_main_queue());
                    DILog(@"MRRegister called");
                } @catch (NSException *e) {
                    DILog(@"MRRegister exception: %@", e);
                }

                if (_kInfoDidChange) {
                    [[NSNotificationCenter defaultCenter] addObserverForName:_kInfoDidChange object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
                        @try {
                            fetchNowPlayingInfo();
                        } @catch (NSException *e) {
                            DILog(@"infoDidChange exception: %@", e);
                        }
                    }];
                    DILog(@"observer infoDidChange registered");
                }
                if (_kPlayingDidChange) {
                    [[NSNotificationCenter defaultCenter] addObserverForName:_kPlayingDidChange object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *note) {
                        @try {
                            fetchNowPlayingInfo();
                        } @catch (NSException *e) {
                            DILog(@"playingDidChange exception: %@", e);
                        }
                    }];
                    DILog(@"observer playingDidChange registered");
                }

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    DILog(@"initial fetchNowPlayingInfo trigger");
                    fetchNowPlayingInfo();
                });
            });
        });
    });
}

static void scheduleTweakInitialization(void) {
    if (_didInitializeTweak || _didScheduleTweakInitialization) return;
    _didScheduleTweakInitialization = YES;
    DILog(@"scheduleTweakInitialization scheduled (+15s)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        _didScheduleTweakInitialization = NO;
        @try {
            initializeTweakAfterLaunch();
        } @catch (NSException *e) {
            DILog(@"scheduled init exception: %@", e);
        }
    });
}

static void registerPrefsObserverIfNeeded(void) {
    if (_didRegisterPrefsObserver) return;
    _didRegisterPrefsObserver = YES;
    @try {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, prefsChanged, CFSTR("com.huayuarc.systempro.prefschanged"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        DILog(@"prefs observer registered");
    } @catch (NSException *e) {
        DILog(@"registerPrefsObserver exception: %@", e);
    }
}

@interface NCNotificationRequest : NSObject
@property (nonatomic, readonly) id content;
@property (nonatomic, readonly) NSString *sectionIdentifier;
@end

@interface NCNotificationViewController : UIViewController
@property (nonatomic, copy) NCNotificationRequest *notificationRequest;
@end

@interface NCNotificationShortLookViewController : NCNotificationViewController
@end

static BOOL isVCInBannerContext(UIViewController *viewController) {
    if (!viewController.isViewLoaded) return NO;

    UIView *view = viewController.view.superview;
    while (view) {
        NSString *className = NSStringFromClass([view class]);
        if ([className rangeOfString:@"Banner" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([className containsString:@"NotificationList"] || [className containsString:@"CoverSheet"] || [className containsString:@"LockScreen"]) return NO;
        view = view.superview;
    }

    UIViewController *parent = viewController.parentViewController;
    while (parent) {
        NSString *className = NSStringFromClass([parent class]);
        if ([className rangeOfString:@"Banner" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([className containsString:@"NotificationList"] || [className containsString:@"CoverSheet"] || [className containsString:@"LockScreen"]) return NO;
        parent = parent.parentViewController;
    }
    return NO;
}

static void extractNotificationContent(NCNotificationRequest *request, NSString **titleOut, NSString **messageOut, UIImage **iconOut, NSString **bundleIDOut) {
    NSString *title = nil;
    NSString *message = nil;
    UIImage *icon = nil;
    NSString *bundleID = nil;

    @try {
        if ([request respondsToSelector:@selector(sectionIdentifier)]) {
            bundleID = safeString([request sectionIdentifier]);
        }

        id content = [request respondsToSelector:@selector(content)] ? [request content] : nil;
        if (content) {
            if ([content respondsToSelector:@selector(title)]) title = safeString([content performSelector:@selector(title)]);
            if ([content respondsToSelector:@selector(message)]) message = safeString([content performSelector:@selector(message)]);
            if (message.length == 0 && [content respondsToSelector:@selector(header)]) message = safeString([content performSelector:@selector(header)]);
            if ([content respondsToSelector:@selector(icon)]) {
                id iconObject = [content performSelector:@selector(icon)];
                if ([iconObject isKindOfClass:[UIImage class]]) icon = iconObject;
            }
        }
    } @catch (__unused NSException *exception) { }

    if (title.length == 0 && message.length == 0) title = DILocalizedString(@"DI_NOTIFICATION_FALLBACK");
    if (titleOut) *titleOut = title;
    if (messageOut) *messageOut = message;
    if (iconOut) *iconOut = icon;
    if (bundleIDOut) *bundleIDOut = bundleID;
}

%group NotificationHooks
%hook NCNotificationShortLookViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    if (!tweakEnabledFromPrefs()) return;
    DIDisplayManager *manager = [DIDisplayManager sharedInstance];
    if (!manager.bannerEnabled || !isVCInBannerContext(self)) return;

    NCNotificationRequest *request = nil;
    @try {
        request = [self respondsToSelector:@selector(notificationRequest)] ? [self notificationRequest] : nil;
    } @catch (__unused NSException *exception) { }
    if (!request) return;

    NSString *title = nil;
    NSString *message = nil;
    UIImage *icon = nil;
    NSString *bundleID = nil;
    extractNotificationContent(request, &title, &message, &icon, &bundleID);
    [manager showNotificationWithTitle:title message:message icon:icon bundleID:bundleID];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;

    if (!tweakEnabledFromPrefs()) return;
    DIDisplayManager *manager = [DIDisplayManager sharedInstance];
    if (!manager.bannerEnabled || !isVCInBannerContext(self)) return;
    [manager cancelDelayedHide];
    manager.delayedHideTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:manager selector:@selector(hideNotification) userInfo:nil repeats:NO];
}

%end
%end

static void initializeNotificationHooksIfNeeded(void) {
    if (_didInitializeNotificationHooks) return;
    if (!objc_lookUpClass("NCNotificationShortLookViewController")) return;
    _didInitializeNotificationHooks = YES;
    %init(NotificationHooks);
}

static void startAfterInjection(void) {
    DIRawLog("startAfterInjection begin");
    DILog(@"startAfterInjection begin");
    // 不在 %ctor 里 dispatch_async 到主线程
    // 改为监听 UIApplication 启动完成通知，确保 SpringBoard 完全初始化后再执行
    __block id _launchObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) {
        // 移除观察者，只执行一次
        if (_launchObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:_launchObserver];
            _launchObserver = nil;
        }
        DIRawLog("UIApplicationDidFinishLaunching received");
        DILog(@"UIApplicationDidFinishLaunching received");
        @try {
            registerPrefsObserverIfNeeded();
            BOOL islandOn = tweakEnabledFromPrefs();
            BOOL notifOn = notificationEnabledFromPrefs();
            DILog(@"prefs: islandEnabled=%d notificationEnabled=%d", islandOn, notifOn);
            if (notifOn) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @try {
                        initializeNotificationHooksIfNeeded();
                    } @catch (NSException *e) {
                        DILog(@"initNotificationHooks exception: %@", e);
                    }
                });
            }
            if (islandOn) {
                scheduleTweakInitialization();
            }
        } @catch (NSException *e) {
            DILog(@"startAfterInjection dispatch exception: %@", e);
        }
    }];
    // Fallback: 如果 30 秒内没收到启动通知（异常情况），直接初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (_launchObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:_launchObserver];
            _launchObserver = nil;
            DIRawLog("launch notification fallback triggered");
            DILog(@"launch notification fallback triggered");
            @try {
                registerPrefsObserverIfNeeded();
                BOOL islandOn = tweakEnabledFromPrefs();
                BOOL notifOn = notificationEnabledFromPrefs();
                DILog(@"fallback prefs: islandEnabled=%d notificationEnabled=%d", islandOn, notifOn);
                if (notifOn) initializeNotificationHooksIfNeeded();
                if (islandOn) scheduleTweakInitialization();
            } @catch (NSException *e) {
                DILog(@"fallback exception: %@", e);
            }
        }
    });
}

%ctor {
    // C 层日志优先：不依赖 Foundation，dyld 阶段也能输出
    DIRawLog("========== ctor entered (dylib loaded) ==========");
    // 再用 Foundation 层日志写文件
    DILog(@"========== ctor entered (dylib loaded) ==========");
    @try {
        startAfterInjection();
    } @catch (NSException *e) {
        DILog(@"ctor exception: %@", e);
    }
}
