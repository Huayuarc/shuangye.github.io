#import <UIKit/UIKit.h>
@protocol CCUIContentModuleContentViewController <NSObject>
@optional
- (CGFloat)preferredExpandedContentHeight;
- (CGFloat)preferredExpandedContentWidth;
- (BOOL)providesOwnPlatter;
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (void)willTransitionToExpandedContentMode:(BOOL)animated;
@end
@protocol CCUIContentModule <NSObject>
@property(nonatomic,strong,readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@optional @property(nonatomic,strong,readonly) UIViewController *backgroundViewController;
@end
