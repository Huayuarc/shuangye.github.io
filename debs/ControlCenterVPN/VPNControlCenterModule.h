#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@protocol CCUIContentModule;
@protocol CCUIContentModuleContentViewController;

@interface VPNControlCenterModule : NSObject <CCUIContentModule>
@property(nonatomic, strong, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property(nonatomic, strong, readonly) UIViewController *backgroundViewController;
@end

@interface VPNControlCenterModuleViewController : UIViewController <CCUIContentModuleContentViewController>
@end
