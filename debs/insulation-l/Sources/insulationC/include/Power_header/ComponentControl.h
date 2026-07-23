#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface ComponentControl : NSObject
@property(readonly, nonatomic) int mitigationType;
- (id)initWithCC:(int)a3 :(/*__CFDictionary **/)a4;
- (void)updatePowerParameters:(id /*__CFDictionary **/)a3;
- (unsigned)currentPower;
- (unsigned)computePowerTarget;
- (unsigned)powerTarget;
@end