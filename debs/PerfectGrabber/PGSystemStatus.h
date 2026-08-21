#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, PGMediaAction) {
    PGMediaActionToggle = 2,
    PGMediaActionNext = 4,
    PGMediaActionPrevious = 5,
};

typedef void (^PGNowPlayingCompletion)(BOOL playing, NSString *title,
                                       NSString *artist, UIImage *artwork);

FOUNDATION_EXPORT double PGCurrentDeviceTemperature(void);
FOUNDATION_EXPORT void PGSendMediaAction(PGMediaAction action);
FOUNDATION_EXPORT void PGFetchNowPlaying(PGNowPlayingCompletion completion);
