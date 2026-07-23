#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface HidSensors
+ (id)sharedInstance;
- (void)handleTemperatureEvent:(int)a3 service:(id)a4;
@end