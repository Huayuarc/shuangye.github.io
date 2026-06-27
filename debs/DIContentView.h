#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, DIState) {
    DIStateHidden,
    DIStateCompact,
    DIStateExpanded,
    DIStateExpandedFull
};

typedef NS_ENUM(NSInteger, DIContentType) {
    DIContentTypeMedia,
    DIContentTypeNotification
};

@class DIContentView;

@protocol DIContentViewDelegate <NSObject>
- (void)contentViewDidRequestDismiss:(DIContentView *)view;
- (void)contentViewDidRequestOpenApp:(DIContentView *)view;
- (void)contentViewDidRequestPlayPause:(DIContentView *)view;
- (void)contentViewDidRequestPrevious:(DIContentView *)view;
- (void)contentViewDidRequestNext:(DIContentView *)view;
- (void)contentViewDidRequestSeek:(DIContentView *)view toPosition:(float)position;
@optional
- (void)contentViewDidRequestDismissNotification:(DIContentView *)view;
- (void)contentViewDidExpandNotification:(DIContentView *)view;
- (void)contentViewDidCollapseNotification:(DIContentView *)view;
@end

@interface DIContentView : UIView

@property (nonatomic, weak) id<DIContentViewDelegate> delegate;
@property (nonatomic, assign) DIState state;
@property (nonatomic, assign) DIContentType contentType;
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, copy) NSString *subtitleText;
@property (nonatomic, assign) BOOL isPlaying;
@property (nonatomic, strong) UIImage *artworkImage;
@property (nonatomic, copy) NSString *notifBundleID;

- (void)showWithTitle:(NSString *)title subtitle:(NSString *)subtitle;
- (void)hide;
- (void)expand;
- (void)collapse;
- (void)expandFull;
- (void)collapseFull;
- (void)updatePlaybackState:(BOOL)playing;
- (void)updateTitleDisplay;
- (void)updateArtwork:(UIImage *)image;
- (void)updateElapsed:(NSTimeInterval)elapsed duration:(NSTimeInterval)duration;
- (void)reloadPrefs;

// 通知显示
- (void)showNotificationWithTitle:(NSString *)title message:(NSString *)message icon:(UIImage *)icon;
- (void)hideNotification;
- (void)hideNotificationImmediate; // 立即隐藏（无动画延迟）
- (void)switchToMedia;
- (void)expandNotification;
- (void)collapseNotification;

@end
