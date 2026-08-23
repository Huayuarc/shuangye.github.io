#import <UIKit/UIKit.h>

// A wallpaper-style view that holds N images and cross-fades between them
// continuously as the device is tilted left/right (gyroscope/accelerometer),
// with a subtle parallax/depth shift -- a re-creation of vivo OriginOS
// "Flip Card" lock screen wallpapers.
@interface VVSFlipCardView : UIView

// (Re)load images + tunables from preferences and (re)build the stack.
- (void)reloadFromPreferences;

// Start / stop listening to device motion. Safe to call repeatedly.
- (void)startMotion;
- (void)stopMotion;

// YES when there is at least one image to show.
@property (nonatomic, readonly) BOOL hasContent;

@end
