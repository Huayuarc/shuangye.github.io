// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// From Apelin's app template. A manual entry point rather than an annotated
// delegate: work that must finish before UIKit reads saved sessions runs
// here. UIKit reads Library/Saved Application State/<bundle id>.savedState
// before any scene delegate runs, and a leftover archive from an earlier
// Info.plist restores the old delegate. Background resumes do not enter
// main, so a live scene is left alone.
#import <UIKit/UIKit.h>
#import "AppDelegate.h"

static void RemoveSavedSceneState(void) {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSURL *library = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    if (bundleIdentifier == nil || library == nil) {
        return;
    }
    NSURL *savedState = [[library URLByAppendingPathComponent:@"Saved Application State" isDirectory:YES]
        URLByAppendingPathComponent:[bundleIdentifier stringByAppendingString:@".savedState"]
                        isDirectory:YES];
    if (![NSFileManager.defaultManager fileExistsAtPath:savedState.path]) {
        return;
    }
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:savedState error:&error]) {
        NSLog(@"Could not clear saved scene state: %@", error);
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        RemoveSavedSceneState();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
