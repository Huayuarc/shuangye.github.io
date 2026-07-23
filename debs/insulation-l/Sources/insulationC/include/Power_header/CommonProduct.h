#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface CommonProduct : NSObject
- (int)arcVirtualTemperature;
- (int)arcModuleTemperature;
- (int)gasGaugeBatteryTemperature;
- (void)writeAllCornerTemperatures:(int)arg1;
- (int)getFrontDisplayCenterTemperature;
- (id)initProduct:(id)arg1;
- (void)putDeviceInLowTempSimulationMode:(id)arg1;
- (void)putDeviceInThermalSimulationMode:(id)arg1;
- (void)thermalUpdatesToWatchdogEnabled:(id)arg1;
- (int)maxControlEffort;
- (void)setHiPFeatureEnabled:(_Bool)arg1;
- (int64_t)thermalPressureLevel;
- (void)setThermalState:(int)a3;
- (BOOL)getPotentialForcedThermalPressureLevel;
- (id)getPotentialForcedThermalLevel:(id)a3;
- (void)tryTakeAction;
- (void)handleMCSThermalPressure;
- (void)simulateLightThermalPressure;
- (void)updatePowerzoneTelemetry;
@end