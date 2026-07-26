#ifndef CPUTHERMAL_HELPER_H
#define CPUTHERMAL_HELPER_H

#import <Foundation/Foundation.h>

@interface CPUthermalHelper : NSObject

@property (nonatomic, assign) BOOL thermalPreventDimmingEnabled;

+ (instancetype)shared;
- (void)reloadPrefs;
- (CFDictionaryRef)patchThermalPlist:(CFDictionaryRef)cfDict;

@end

#endif
