#import "VVSVideoView.h"
#import "../common/VVSCommon.h"
#import <AVFoundation/AVFoundation.h>

@interface VVSVideoView ()
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, assign) BOOL fill;
@end

@implementation VVSVideoView

+ (Class)layerClass { return [AVPlayerLayer class]; }

- (AVPlayerLayer *)playerLayer { return (AVPlayerLayer *)self.layer; }

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor blackColor];
        [self reloadFromPreferences];
    }
    return self;
}

- (BOOL)hasVideo { return self.player != nil; }

- (void)reloadFromPreferences {
    CFPreferencesAppSynchronize(kVVSPrefsAppID);
    Boolean ok = false;
    Boolean f = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)kVVSKeyFill, kVVSPrefsAppID, &ok);
    self.fill = ok ? (BOOL)f : NO;

    NSString *path = VVSVideoPath();
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];

    // Tear down any existing playback first.
    [self.player pause];
    self.looper = nil;
    self.player = nil;
    self.playerLayer.player = nil;

    if (!exists) return;

    NSURL *url = [NSURL fileURLWithPath:path];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    self.player = [AVQueuePlayer queuePlayerWithItems:@[]];
    self.player.muted = YES;
    self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.looper = [AVPlayerLooper playerLooperWithPlayer:self.player templateItem:item];

    self.playerLayer.player = self.player;
    self.playerLayer.videoGravity = self.fill ? AVLayerVideoGravityResizeAspectFill
                                              : AVLayerVideoGravityResizeAspect;
}

- (void)play  { [self.player play]; }
- (void)pause { [self.player pause]; }

@end
