#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import "SJGSettings.h"
#include <notify.h>

static const uint64_t kSJGAutoThreshold = 1536ULL * 1024ULL * 1024ULL;
static const NSTimeInterval kSJGAutoCooldown = 600.0;
static dispatch_source_t gSJGAutoTimer;
static int gSJGSettingsToken = -1;
static BOOL gSJGAutoEnabled = YES;
static unsigned gSJGHighSamples;
static NSTimeInterval gSJGLastTrigger;

static uint64_t SJGCurrentPhysicalFootprint(void) {
#if defined(TASK_VM_INFO) && defined(TASK_VM_INFO_COUNT)
    task_vm_info_data_t info = {0};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        return (uint64_t)info.phys_footprint;
#endif
    return 0;
}

static BOOL SJGReadAutoEnabled(void) {
    NSDictionary *settings = SJGReadSettings();
    return settings[@"autoSpringBoardTrim"] ? [settings[@"autoSpringBoardTrim"] boolValue] : YES;
}

__attribute__((constructor)) static void SJGAutoTrimInitialize(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) return;
        dispatch_queue_t queue = dispatch_queue_create("com.huayuarc.sbjetsamguard.autotrim", DISPATCH_QUEUE_SERIAL);
        gSJGAutoEnabled = SJGReadAutoEnabled();
        notify_register_dispatch("com.huayuarc.sbjetsamguard.settingschanged", &gSJGSettingsToken, queue, ^(int token){
            (void)token; gSJGAutoEnabled = SJGReadAutoEnabled(); if (!gSJGAutoEnabled) gSJGHighSamples = 0;
        });
        gSJGAutoTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_t timer = gSJGAutoTimer;
        if (!timer) return;
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, 2 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            @autoreleasepool {
                if (!gSJGAutoEnabled) { gSJGHighSamples = 0; return; }
                uint64_t footprint = SJGCurrentPhysicalFootprint();
                if (footprint == 0 || footprint < kSJGAutoThreshold) { gSJGHighSamples = 0; return; }
                if (gSJGHighSamples < 2) gSJGHighSamples++;
                NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
                if (gSJGHighSamples >= 2 && (gSJGLastTrigger == 0 || now - gSJGLastTrigger >= kSJGAutoCooldown)) {
                    if (notify_post("com.huayuarc.sbjetsamguard.trim.auto") == NOTIFY_STATUS_OK) gSJGLastTrigger = now;
                    gSJGHighSamples = 0;
                }
            }
        });
        dispatch_resume(timer);
        (void)timer; // retained by libdispatch after resume
    }
}
