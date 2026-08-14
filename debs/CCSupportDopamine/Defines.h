#import <roothide.h>

#define DefaultModuleConfigurationPath rootfs(@"/var/mobile/Library/ControlCenter/ModuleConfiguration.plist")
#define CCSupportModuleConfigurationPath jbroot(@"/var/mobile/Library/ControlCenter/ModuleConfiguration_CCSupport.plist")
#define DefaultModuleOrderPath rootfs(@"/System/Library/PrivateFrameworks/ControlCenterServices.framework/DefaultModuleOrder~%@.plist")

#define CCSupportBundlePath jbroot(@"/Library/Application Support/CCSupport")
#define CCSupportModulesPath jbroot(@"/Library/ControlCenter/Bundles")
#define CCSupportProvidersPath jbroot(@"/Library/ControlCenter/CCSupport_Providers")

#define iOS15_WhitelistedFixedModuleIdentifiers @[@"com.apple.replaykit.AudioConferenceControlCenterModule", @"com.apple.replaykit.VideoConferenceControlCenterModule"]

#ifndef kCFCoreFoundationVersionNumber_iOS_15_0
#define kCFCoreFoundationVersionNumber_iOS_15_0 1854
#endif

#ifndef kCFCoreFoundationVersionNumber_iOS_16_0
#define kCFCoreFoundationVersionNumber_iOS_16_0 1932.101
#endif
