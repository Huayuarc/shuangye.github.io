#import <Foundation/Foundation.h>
#import "Headers/Tweak.h"

@interface CPUthermalHelper : NSObject

@property (nonatomic, strong) NSDictionary *plistObj;
@property (nonatomic, weak) CommonProduct *commonProductObject;
@property (nonatomic, assign) BOOL thermalPreventDimmingEnabled;
@property (nonatomic, assign) BOOL thermalFullPowerEnabled;
@property (nonatomic, assign) BOOL thermalLowPowerEnabled;

+ (instancetype)shared;

- (void)getLocalPrefValue;
- (void)reloadPrefs;
- (int)getCPUMaxPower;
- (void)executePuppetEvent;

- (CFDictionaryRef)patchThermalPlist:(CFDictionaryRef)cfDict;

// 工具方法
+ (BOOL)userspaceReboot;

@end
