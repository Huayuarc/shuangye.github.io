#import <Foundation/Foundation.h>
#import "Headers/Tweak.h"

// ============================================================
// 温控运行模式
// ThermalControlModeLowPower  = 1  低功耗模式
// ThermalControlModeFullPower = 2  解除温控模式
// ============================================================
typedef NS_ENUM(NSInteger, ThermalControlMode) {
    ThermalControlModeLowPower  = 1,
    ThermalControlModeFullPower = 2
};

@interface CPUthermalHelper : NSObject

@property (nonatomic, strong) NSDictionary *plistObj;
@property (nonatomic, strong) CommonProduct *commonProductObject;
@property (nonatomic, assign) BOOL thermalPreventDimmingEnabled;
+ (instancetype)shared;

- (void)getLocalPrefValue;
- (void)reloadPrefs;
- (int)getCPUMaxPower;

- (NSDictionary *)patchThermalPlist:(NSDictionary *)dict;

// 模式读写
- (NSInteger)loadThermalMode;
- (void)saveThermalMode:(NSInteger)mode;

// 工具方法
+ (BOOL)userspaceReboot;

@end
