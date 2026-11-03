#pragma once
#import <UIKit/UIKit.h>
@class PSSpecifier;
@interface PSListController : UIViewController {
@protected
    NSMutableArray *_specifiers;
}
@property(nonatomic,retain) NSMutableArray *specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (id)specifierForID:(NSString *)identifier;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
@end
