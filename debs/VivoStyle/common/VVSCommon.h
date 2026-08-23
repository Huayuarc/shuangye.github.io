#import <Foundation/Foundation.h>

// Shared identifiers between the SpringBoard tweak and the Settings prefs bundle.

#define kVVSPrefsAppID         CFSTR("com.vivostyle.prefs")
#define kVVSPrefsSuite         @"com.vivostyle.prefs"

// Darwin notification posted by the prefs bundle when settings/images change.
#define kVVSReloadNotification "com.vivostyle.reload"

// Preference keys
#define kVVSKeyEnabled         @"enabled"
#define kVVSKeyImageCount      @"imageCount"      // number of images selected
#define kVVSKeySensitivity     @"sensitivity"    // 0..1  (higher = less tilt needed to flip)
#define kVVSKeyParallax        @"parallax"       // 0..1  (depth/parallax strength)
#define kVVSKeyLoop            @"loop"           // BOOL  wrap around at the ends
#define kVVSKeySmoothing       @"smoothing"      // 0..1  motion low-pass strength
#define kVVSKeyFill            @"fill"           // BOOL  YES=crop-to-fill, NO=fit whole photo
#define kVVSKeyTransition      @"transition"     // int   0=fade 1=slide 2=flip 3=zoom
#define kVVSKeyVideoEnabled    @"videoEnabled"   // BOOL  play a video wallpaper instead of photos
#define kVVSKeyHasVideo        @"hasVideo"       // BOOL  a video file has been chosen

// Images live in the (shared) data domain, NOT under the jailbreak prefix, so
// both SpringBoard and the Preferences bundle resolve the same path.
static inline NSString *VVSImagesDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/VivoStyle/Images"];
}

// Full-screen JPEGs are stored as 0.jpg, 1.jpg, ... in selection order.
static inline NSString *VVSImagePathAtIndex(NSInteger idx) {
    return [VVSImagesDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%ld.jpg", (long)idx]];
}

// The chosen video wallpaper file.
static inline NSString *VVSVideoPath(void) {
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/VivoStyle"]
            stringByAppendingPathComponent:@"video.mov"];
}
