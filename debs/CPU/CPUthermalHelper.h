#import <Foundation/Foundation.h>
#import "Headers/Tweak.h"

@interface CPUthermalHelper : NSObject

@property (nonatomic, strong) NSDictionary *plistObj;
@property (nonatomic, strong) CommonProduct *commonProductObject;
@property (nonatomic, assign) BOOL thermalPreventDimmingEnabled;
+ (instancetype)shared;

- (void)getLocalPrefValue;
- (void)reloadPrefs;
- (int)getCPUMaxPower;

- (NSDictionary *)patchThermalPlist:(NSDictionary *)dict;

// 工具方法
+ (BOOL)userspaceReboot;

@end
