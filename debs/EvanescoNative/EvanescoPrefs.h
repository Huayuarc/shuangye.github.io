#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
static NSString *const EVDomain=@"com.cpdigitaldarkroom.itsevanesco";
static CFStringRef const EVNotify=CFSTR("com.cpdigitaldarkroom.itsevanesco.settings");
static id EVRead(NSString *k,id d){CFPropertyListRef v=CFPreferencesCopyAppValue((__bridge CFStringRef)k,(__bridge CFStringRef)EVDomain);return v?CFBridgingRelease(v):d;}
static __attribute__((unused)) void EVWrite(NSString *k,id v){CFPreferencesSetAppValue((__bridge CFStringRef)k,(__bridge CFPropertyListRef)v,(__bridge CFStringRef)EVDomain);CFPreferencesAppSynchronize((__bridge CFStringRef)EVDomain);CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),EVNotify,NULL,NULL,true);}
