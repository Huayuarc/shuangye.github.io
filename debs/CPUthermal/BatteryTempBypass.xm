#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <substrate.h>
#import <notify.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <CPUthermalPaths.h>

// 仅 powerd 使用。Hook 热路径只检查已返回字典，不再二次查询 IORegistry，
// 避免 iOS 15 thermalmonitord 主线程发生 IOKit 重入并错过 watchdog check-in。
static _Atomic(bool) gEnabled=false;
static int gToken=0;

static void ReloadPrefs(void) {
 NSDictionary *prefs=CPUthermalReadPrefs()?:@{};
 atomic_store_explicit(&gEnabled,[prefs[@"bypassBatteryChargeTemperature"] boolValue],memory_order_release);
}
static BOOL IsBatteryProperties(CFDictionaryRef d) {
 if(!d)return NO;
 // 电池服务稳定包含容量字段，并至少包含连接、安装或循环信息之一。
 BOOL capacity=CFDictionaryContainsKey(d,CFSTR("CurrentCapacity"));
 BOOL identity=CFDictionaryContainsKey(d,CFSTR("ExternalConnected"))||
               CFDictionaryContainsKey(d,CFSTR("BatteryInstalled"))||
               CFDictionaryContainsKey(d,CFSTR("CycleCount"));
 return capacity&&identity;
}
static kern_return_t (*origCreateProperties)(io_registry_entry_t,CFMutableDictionaryRef*,CFAllocatorRef,IOOptionBits)=NULL;
static kern_return_t HookCreateProperties(io_registry_entry_t entry,CFMutableDictionaryRef *out,CFAllocatorRef allocator,IOOptionBits options) {
 kern_return_t result=origCreateProperties(entry,out,allocator,options);
 if(result!=KERN_SUCCESS||!out||!*out||!atomic_load_explicit(&gEnabled,memory_order_acquire)||!IsBatteryProperties(*out))return result;
 int normalTemperature=3200;
 CFNumberRef normal=CFNumberCreate(kCFAllocatorDefault,kCFNumberIntType,&normalTemperature);
 if(!normal)return result;
 const CFStringRef keys[]={CFSTR("Temperature"),CFSTR("VirtualTemperature"),CFSTR("BatteryTemperature")};
 for(size_t i=0;i<sizeof(keys)/sizeof(keys[0]);i++)if(CFDictionaryContainsKey(*out,keys[i]))CFDictionarySetValue(*out,keys[i],normal);
 CFRelease(normal);
 return result;
}

%ctor { @autoreleasepool {
 ReloadPrefs();
 // 偏好路径解析移出 powerd 主线程，通知回调只在后台队列读取。
 dispatch_queue_t queue=dispatch_queue_create("com.huayuarc.cputhermal.batterytemp.preferences",DISPATCH_QUEUE_SERIAL);
 notify_register_dispatch(kCPUthermalSettingsChangedNotifC,&gToken,queue,^(int token){(void)token;ReloadPrefs();});
 void *iokit=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_GLOBAL);
 if(iokit){
  void *symbol=dlsym(iokit,"IORegistryEntryCreateCFProperties");
  if(symbol)MSHookFunction(symbol,(void *)HookCreateProperties,(void **)&origCreateProperties);
 }
} }
