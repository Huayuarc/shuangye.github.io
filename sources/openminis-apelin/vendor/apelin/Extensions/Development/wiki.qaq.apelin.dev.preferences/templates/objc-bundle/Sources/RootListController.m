// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// From Apelin's preference bundle template: the bundle's principal class.
// Root.plist describes the rows. Each row names the preferences domain and
// key it stores; Preferences reads and writes them through cfprefsd and posts
// the row's PostNotification after a change, so whatever reads the setting
// (a tweak, a tool) re-reads it on that notification.
#import <Preferences/PSListController.h>

@interface {{productName}}RootListController : PSListController
@end

@implementation {{productName}}RootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

@end
