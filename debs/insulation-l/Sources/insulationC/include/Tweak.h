#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <roothide.h>
#import <spawn.h>
#include <stdbool.h>

#import "./Power_header/CommonProduct.h"
#import "./Power_header/MitigationController.h"
#import "./Power_header/HidSensors.h"
#import "./Power_header/ThermalManager.h"
#import "./Power_header/PackagePowerCC.h"
#import "./Power_header/ComponentControl.h"
#import "./Power_header/CPMSHelper.h"
#import "./NSDictionary_header/NSDictionary.h"

static NSString *_Nonnull rootlessPath(NSString* _Nonnull path) {
  return jbroot(path);
}