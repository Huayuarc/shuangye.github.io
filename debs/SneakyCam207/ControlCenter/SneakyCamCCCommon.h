#import <UIKit/UIKit.h>
@protocol CCUIContentModuleContentViewController <NSObject>
@required - (CGFloat)preferredExpandedContentHeight;
@optional - (CGFloat)preferredExpandedContentWidth; - (BOOL)providesOwnPlatter; - (BOOL)shouldBeginTransitionToExpandedContentModule; - (void)willTransitionToExpandedContentMode:(BOOL)animated; - (void)willReturnToExpandedContentModule;
@end
@protocol CCUIContentModule <NSObject>
@property(nonatomic,strong,readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@optional @property(nonatomic,strong,readonly) UIViewController *backgroundViewController;
@end
typedef NS_ENUM(NSInteger,SneakyCamCCMode){SneakyCamCCModeToggle,SneakyCamCCModePhoto,SneakyCamCCModeVideo};
FOUNDATION_EXPORT UIViewController<CCUIContentModuleContentViewController> *SneakyCamCCCreateViewController(SneakyCamCCMode mode);
