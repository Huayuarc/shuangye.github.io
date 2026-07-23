#import <Foundation/Foundation.h>
#import "Headers/Tweak.h"

@interface CPUthermalHelper : NSObject

@property (nonatomic, strong) NSDictionary *plistObj;
@property (nonatomic, weak) CommonProduct *commonProductObject;

+ (instancetype)shared;

- (void)getLocalPrefValue;
- (int)getCPUMaxPower;
- (void)executePuppetEvent;

- (CFDictionaryRef)patchThermalPlist:(CFDictionaryRef)cfDict;

@end
