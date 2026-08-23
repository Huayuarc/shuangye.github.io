#import <UIKit/UIKit.h>

// A looping, muted video wallpaper layer. Independent of motion/gyroscope.
@interface VVSVideoView : UIView
- (void)reloadFromPreferences;   // (re)load the chosen video file
- (void)play;
- (void)pause;
@property (nonatomic, readonly) BOOL hasVideo;
@end
