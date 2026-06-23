//
// AkaraPrefs.h
// Akara Preference Bundle Header (Reconstructed)
//
// Reconstructed from: AkaraPrefs.bundle/AkaraPrefs
// Architecture: arm64e (FAT: arm64 + arm64e)
// Deployment Target: iOS 16.1.2 (Dopamine rootless)
//
// Classes:
//   AKRRootListController       : PSListController
//   AKRLabeledSliderCell        : PSSliderTableCell
//   AKRTableCell                : PSTableCell
//   AKRLinkCell                 : AKRTableCell
//   AKRHeaderCell               : PSTableCell <PSHeaderFooterView>
//   AKRDuoTwitterCell           : AKRTableCell
//

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSliderTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSHeaderFooterView.h>

#pragma mark - AKRRootListController

@interface AKRRootListController : PSListController

// Method type: @16@0:8
- (NSArray *)specifiers;

// Method type: v16@0:8
- (void)viewDidLoad;

- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;

// Method type: v16@0:8
- (void)respring;

// Method type: v16@0:8
- (void)resetLayoutToDefault;

// Method type: v16@0:8
- (void)resetPreferencesToDefault;

@end


#pragma mark - AKRLabeledSliderCell

@interface AKRLabeledSliderCell : PSSliderTableCell

// Method type: @40@0:8q16@24@32
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;

// Method type: v16@0:8
- (void)layoutSubviews;

@end


#pragma mark - AKRTableCell

@interface AKRTableCell : PSTableCell

// Method type: v16@0:8
- (void)layoutSubviews;

// Method type: v24@0:8@16
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier;

@end


#pragma mark - AKRLinkCell

@interface AKRLinkCell : AKRTableCell

// Properties:
// @property (nonatomic, readonly) BOOL isBig;
// @property (nonatomic, readonly, retain) UIView *avatarView;
// @property (nonatomic, readonly, retain) UIImageView *avatarImageView;
// @property (nonatomic, retain) UIImage *avatarImage;

// Ivars:
// BOOL _isBig;
// UIView *_avatarView;
// UIImageView *_avatarImageView;

// Method type: @40@0:8q16@24@32
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;

// Property getter - type: @16@0:8
@property (nonatomic, readonly, retain) UIView *avatarView;

// Property setter - type: v24@0:8@16
@property (nonatomic, retain) UIImage *avatarImage;

// Method type: B16@0:8
- (BOOL)isBig;

// Method type: B16@0:8
- (BOOL)shouldShowAvatar;

// Property getter - type: @16@0:8
@property (nonatomic, readonly, retain) UIImageView *avatarImageView;

// Method type: v16@0:8
- (void)loadAvatarIfNeeded;

// Method type: v16@0:8 (auto-synthesized)

@end


#pragma mark - AKRHeaderCell

@interface AKRHeaderCell : PSTableCell <PSHeaderFooterView>

// Ivars:
// UILabel *titleLabel;
// UIView *backgroundView;
// UILabel *_subtitleLabel;
// UIImageView *_iconView;
// UIStackView *_containerStackView;

// Properties (nonatomic, retain):
@property (nonatomic, retain) UILabel *titleLabel;
@property (nonatomic, retain) UILabel *subtitleLabel;
@property (nonatomic, retain) UIImageView *iconView;
@property (nonatomic, retain) UIStackView *containerStackView;
@property (nonatomic, retain) UIView *backgroundView;

// Method type: @40@0:8q16@24@32
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;

// PSHeaderFooterView required - type: @24@0:8@16
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier;

// PSHeaderFooterView optional - type: d24@0:8d16
- (CGFloat)preferredHeightForWidth:(CGFloat)width;

// Method type: v16@0:8 (auto-synthesized)

@end


#pragma mark - AKRDuoTwitterCell

@interface AKRDuoTwitterCell : AKRTableCell

// Ivars:
// NSString *_user;
// NSString *_user2;

// Method type: @40@0:8q16@24@32
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;

// Method type: v24@0:8@16
- (void)handleLeftTap:(UITapGestureRecognizer *)gestureRecognizer;

// Method type: v24@0:8@16
- (void)handleRightTap:(UITapGestureRecognizer *)gestureRecognizer;

// Method type: v24@0:8B16B20
- (void)setSelected:(BOOL)selected animated:(BOOL)animated;

// Method type: B16@0:8
- (BOOL)canBecomeFirstResponder;

// Method type: v16@0:8 (auto-synthesized)

// Class method - type: @24@0:8@16
+ (instancetype)cellWithSpecifier:(PSSpecifier *)specifier;

@end
