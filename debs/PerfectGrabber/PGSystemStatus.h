#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PGMediaAction) {
    PGMediaActionToggle = 2,
    PGMediaActionNext = 4,
    PGMediaActionPrevious = 5,
};

FOUNDATION_EXPORT double PGCurrentDeviceTemperature(void);
FOUNDATION_EXPORT void PGSendMediaAction(PGMediaAction action);
