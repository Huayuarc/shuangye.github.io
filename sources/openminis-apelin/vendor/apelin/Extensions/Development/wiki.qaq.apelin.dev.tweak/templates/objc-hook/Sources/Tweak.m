// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// From Apelin's tweak template. The shape follows platformize-tweak-ios: one
// constructor, a cheap identity check first, then the hooks. Replace the hook
// below with the method you are changing, and keep the filter in
// apelin-project.json scoped to the processes that actually need it.
//
// The build defines APELIN_PACKAGE_ID, APELIN_VERSION and APELIN_BUILD_ID as
// string literals on every compile.
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <substrate.h>

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

static void (*OriginalDidFinishLaunching)(id self, SEL _cmd, id application);

// -[SpringBoard applicationDidFinishLaunching:] runs once per SpringBoard
// launch, after the constructor below has installed the hook.
static void HookedDidFinishLaunching(id self, SEL _cmd, id application) {
    if (OriginalDidFinishLaunching != NULL) {
        OriginalDidFinishLaunching(self, _cmd, application);
    }
    os_log(TweakLog(), "ApelinHooked %{public}s -[SpringBoard applicationDidFinishLaunching:]", APELIN_BUILD_ID);
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded looks for this exact marker and build id under
    // the package id's subsystem. Keep the line, and keep it public.
    os_log(TweakLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());

    Class springBoard = objc_getClass("SpringBoard");
    if (springBoard == Nil) {
        return;  // Loaded into some other process the filter names.
    }
    MSHookMessageEx(springBoard,
                    @selector(applicationDidFinishLaunching:),
                    (IMP)HookedDidFinishLaunching,
                    (IMP *)&OriginalDidFinishLaunching);
}
