#import <UIKit/UIKit.h>

@class DIContentView;

@interface DIWindow : UIWindow

@property (nonatomic, strong, readonly) DIContentView *contentView;

- (void)show;
- (void)hide;

@end
