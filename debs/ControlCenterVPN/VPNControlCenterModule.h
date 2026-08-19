#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ControlCenterUIKit 私有协议的最小声明；运行时由 SpringBoard 提供实现。
@protocol CCUIContentModule <NSObject>
@property(nonatomic, readonly) UIViewController *contentViewController;
@property(nonatomic, readonly) UIViewController *backgroundViewController;
@end

@protocol CCUIContentModuleContentViewController <NSObject>
@optional
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (void)willTransitionToExpandedContentMode:(BOOL)animated;
- (void)willReturnToExpandedContentModule;
- (CGFloat)preferredExpandedContentHeight;
- (CGFloat)preferredExpandedContentWidth;
- (BOOL)providesOwnPlatter;
@end

@interface VPNControlCenterModule : NSObject <CCUIContentModule>
@property(nonatomic, strong, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property(nonatomic, strong, readonly) UIViewController *backgroundViewController;
@end

@interface VPNControlCenterModuleViewController : UIViewController <CCUIContentModuleContentViewController>
@end
