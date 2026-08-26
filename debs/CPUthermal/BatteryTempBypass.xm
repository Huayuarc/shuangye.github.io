#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <CPUthermalPaths.h>

static BOOL gEnabled=NO;
static int gToken=0;
static BOOL BatteryEntry(io_registry_entry_t e){
 if(e==MACH_PORT_NULL)return NO; io_name_t n={0};
 if(IORegistryEntryGetName(e,n)!=KERN_SUCCESS)return NO;
 return !strcmp(n,"AppleSmartBattery")||!strcmp(n,"IOPMPowerSource")||!strcmp(n,"AppleARMPMUPowerSource");
}
static BOOL TempKey(CFStringRef k){
 if(!k)return NO; NSString*s=(__bridge NSString*)k;
 return [s isEqualToString:@"Temperature"]||[s isEqualToString:@"VirtualTemperature"]||[s isEqualToString:@"BatteryTemperature"];
}
static void LoadPrefs(void){gEnabled=[(CPUthermalReadPrefs()?:@{})[@"bypassBatteryChargeTemperature"] boolValue];}
static kern_return_t(*origProps)(io_registry_entry_t,CFMutableDictionaryRef*,CFAllocatorRef,IOOptionBits);
static kern_return_t hookProps(io_registry_entry_t e,CFMutableDictionaryRef*out,CFAllocatorRef a,IOOptionBits o){
 kern_return_t r=origProps(e,out,a,o); if(r||!gEnabled||!out||!*out||!BatteryEntry(e))return r;
 int n=3200; CFNumberRef normal=CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&n);
 for(NSString *key in @[ @"Temperature",@"VirtualTemperature",@"BatteryTemperature" ]) {
  CFStringRef k=(__bridge CFStringRef)key;
  if(CFDictionaryContainsKey(*out,k))CFDictionarySetValue(*out,k,normal);
 }
 CFRelease(normal); return r;
}
static CFTypeRef(*origProp)(io_registry_entry_t,CFStringRef,CFAllocatorRef,IOOptionBits);
static CFTypeRef hookProp(io_registry_entry_t e,CFStringRef k,CFAllocatorRef a,IOOptionBits o){
 CFTypeRef v=origProp(e,k,a,o); if(!gEnabled||!BatteryEntry(e)||!TempKey(k))return v;
 if(v)CFRelease(v); int n=3200; return CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&n);
}
%ctor { @autoreleasepool {
 LoadPrefs(); notify_register_dispatch(kCPUthermalSettingsChangedNotifC,&gToken,dispatch_get_main_queue(),^(int t){(void)t;LoadPrefs();});
 void*h=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_GLOBAL);
 if(h){void*p=dlsym(h,"IORegistryEntryCreateCFProperties");if(p)MSHookFunction(p,(void*)hookProps,(void**)&origProps);
 void*q=dlsym(h,"IORegistryEntryCreateCFProperty");if(q)MSHookFunction(q,(void*)hookProp,(void**)&origProp);}
} }
