#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CPUthermalPaths.h>

static NSString *BundleIDFromObject(id object) {
    const char *selectors[]={"bundleIdentifier","displayIdentifier","applicationIdentifier",NULL};
    for(int i=0;object&&selectors[i];i++){
        SEL selector=sel_registerName(selectors[i]);
        if(![object respondsToSelector:selector])continue;
        id value=((id(*)(id,SEL))objc_msgSend)(object,selector);
        if([value isKindOfClass:[NSString class]]&&[value length])return value;
    }
    return nil;
}

static NSString *FrontmostBundleID(void) {
    Class cls=objc_getClass("SBApplicationController");
    SEL shared=sel_registerName("sharedInstance");
    id controller=[cls respondsToSelector:shared]?((id(*)(id,SEL))objc_msgSend)(cls,shared):nil;
    id application=nil;
    SEL runningSelector=sel_registerName("runningApplications");
    id running=[controller respondsToSelector:runningSelector]?((id(*)(id,SEL))objc_msgSend)(controller,runningSelector):nil;
    if([running isKindOfClass:[NSArray class]])for(id item in running){SEL active=sel_registerName("isProcessForeground");if([item respondsToSelector:active]&&((BOOL(*)(id,SEL))objc_msgSend)(item,active)){application=item;break;}}
    if(!application){SEL front=sel_registerName("frontmostApplication");if([controller respondsToSelector:front])application=((id(*)(id,SEL))objc_msgSend)(controller,front);}
    NSString *bundleID=BundleIDFromObject(application);if(bundleID.length)return bundleID;
    Class workspaceClass=objc_getClass("SBMainWorkspace");
    id workspace=[workspaceClass respondsToSelector:shared]?((id(*)(id,SEL))objc_msgSend)(workspaceClass,shared):nil;
    SEL front=sel_registerName("frontmostApplication");
    if([workspace respondsToSelector:front])bundleID=BundleIDFromObject(((id(*)(id,SEL))objc_msgSend)(workspace,front));
    return bundleID;
}

static void PublishRepeatedly(NSString *bundleID) {
    if(!bundleID.length)return;
    CPUthermalPostForegroundBundleID(bundleID);
    for(NSNumber *delay in @[@0.10,@0.35,@0.80])dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{CPUthermalPostForegroundBundleID(bundleID);});
}

%hook SBApplication
- (void)activate {
    NSString *bundleID=BundleIDFromObject(self);
    if(bundleID.length)CPUthermalPostForegroundBundleID(bundleID);
    %orig;
    if(bundleID.length)PublishRepeatedly(bundleID);
}
%end

%ctor {
    @autoreleasepool { dispatch_async(dispatch_get_main_queue(), ^{
        __block uint64_t lastHash=UINT64_MAX; __block NSUInteger misses=0;
        void(^poll)(void)=^{
            NSString *bundleID=FrontmostBundleID();
            if(!bundleID.length){if(++misses<3)return;bundleID=S("com.apple.springboard");}else misses=0;
            uint64_t hash=CPUthermalBundleIDHash(bundleID);if(hash==lastHash)return;lastHash=hash;CPUthermalPostForegroundBundleID(bundleID);
        };
        poll();
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(__unused NSTimer *timer){poll();}];
    }); }
}
