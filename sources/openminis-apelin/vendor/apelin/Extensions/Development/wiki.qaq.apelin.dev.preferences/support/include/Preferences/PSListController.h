// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The Preferences.framework declarations a preference bundle subclasses and
// builds its rows with. The SDK ships no Preferences headers, so these are
// Apelin's own, written from the framework's exported interface; nothing is
// copied from Apple. The symbols resolve from the private framework at run
// time; the link stub beside this folder (support/stubs/Preferences.framework)
// declares exactly the classes and ivars used here, and a new one goes into
// both together. A method is a message, not a symbol: it needs this header
// only. One the framework has and this header lacks is declared in a
// category in the project's own source, never by editing this folder.
#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class PSSpecifier;

/// A row's kind, numbered as the framework numbers it; Root.plist names the
/// same kinds as strings (`cell`: `PSSwitchCell`).
typedef NS_ENUM(NSInteger, PSCellType) {
    PSGroupCell = 0,
    PSLinkCell = 1,
    PSLinkListCell = 2,
    PSListItemCell = 3,
    PSTitleValueCell = 4,
    PSSliderCell = 5,
    PSSwitchCell = 6,
    PSStaticTextCell = 7,
    PSEditTextCell = 8,
    PSSegmentCell = 9,
    PSGiantIconCell = 10,
    PSGiantCell = 11,
    PSSecureEditTextCell = 12,
    PSButtonCell = 13,
    PSEditTextViewCell = 14,
};

@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController {
@protected
    NSMutableArray *_specifiers;
}

/// Loads the specifiers from <name>.plist inside the bundle that defines
/// `target`'s class.
- (NSMutableArray *)loadSpecifiersFromPlistName:(NSString *)plistName target:(id)target;
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;

/// The shown specifier whose `id` is `specifierID`, or nil.
- (PSSpecifier *)specifierForID:(NSString *)specifierID;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (void)addSpecifier:(PSSpecifier *)specifier;
- (void)insertSpecifier:(PSSpecifier *)specifier atIndex:(NSInteger)index animated:(BOOL)animated;
- (void)removeSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

@interface PSSpecifier : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) id target;
@property (nonatomic) PSCellType cellType;

/// A row built in code, as Root.plist's loader builds one: `set` and `get`
/// are `target`'s `setPreferenceValue:specifier:` and
/// `readPreferenceValue:` for a value row, `detail` the controller a link
/// row pushes, `edit` nil.
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(PSCellType)cell
                                    edit:(Class)edit;
/// A section header row (`PSGroupCell`).
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)emptyGroupSpecifier;

/// A Root.plist key of the row (`key`, `default`, `defaults`,
/// `PostNotification`, `footerText` …).
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (void)removePropertyForKey:(NSString *)key;
@end
