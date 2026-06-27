#import <UIKit/UIKit.h>
#import "DIContentView.h"

@interface DIDisplayManager : NSObject <DIContentViewDelegate>

// 通知灵动岛偏好
@property (nonatomic, assign, readonly) BOOL bannerEnabled;
@property (nonatomic, assign, readonly) CGFloat bannerCornerRadius;
@property (nonatomic, assign, readonly) CGFloat bannerDamping;
@property (nonatomic, assign, readonly) CGFloat bannerInitialScale;
@property (nonatomic, assign, readonly) CGFloat notifDuration;

// 双圆角
@property (nonatomic, assign, readonly) CGFloat mediaCornerRadius;
@property (nonatomic, assign, readonly) CGFloat notifCornerRadius;

// 当前是否有音乐在播放
@property (nonatomic, assign, readonly) BOOL mediaActive;

// 当前是否在显示通知（优先级判断）
@property (nonatomic, assign, readonly) BOOL showingNotification;

// 延迟隐藏通知 timer（用于防止连续通知一闪而过）
@property (nonatomic, strong) NSTimer *delayedHideTimer;

+ (instancetype)sharedInstance;
- (void)setup;
- (void)showMediaWithTitle:(NSString *)title artist:(NSString *)artist playing:(BOOL)playing artwork:(UIImage *)artwork bundleID:(NSString *)bundleID;
- (void)updateMediaArtwork:(UIImage *)artwork;
- (void)updateElapsed:(NSTimeInterval)elapsed duration:(NSTimeInterval)duration;
- (void)reloadPrefs;

// 通知整合接口
- (void)showNotificationWithTitle:(NSString *)title message:(NSString *)message icon:(UIImage *)icon bundleID:(NSString *)bundleID;
- (void)hideNotification;
- (void)hideNotificationImmediate;
- (void)cancelDelayedHide;

// 通知 timer 暂停 / 恢复（长按展开时使用）
- (void)pauseNotificationTimer;
- (void)resumeNotificationTimer;

@end
