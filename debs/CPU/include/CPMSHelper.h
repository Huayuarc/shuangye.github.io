#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface CPMSHelper: NSObject
+ (id)sharedInstance;
- (unsigned)getMaxPowerForComponent:(int)a3;
- (unsigned)getMinPowerForComponent:(int)a3;
@end