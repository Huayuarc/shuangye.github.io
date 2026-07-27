#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
// Rootless/Dopamine: 文件系統直接可訪問，無需路徑轉換
static NSString *_Nonnull rootlessPath(NSString* _Nonnull path) {
    return path;
}
#pragma clang diagnostic pop