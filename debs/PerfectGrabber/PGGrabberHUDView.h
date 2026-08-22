#import <UIKit/UIKit.h>

@interface PGGrabberHUDView : UIView
@property (nonatomic, copy) void (^interactionHandler)(void);
- (void)startUpdating;
- (void)stopUpdating;
@end
