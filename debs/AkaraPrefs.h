#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSliderTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSHeaderFooterView.h>

#pragma mark - AKRRootListController

@interface AKRRootListController : PSListController
- (NSArray *)specifiers;
- (void)viewDidLoad;
- (void)respring;
- (void)resetLayoutToDefault;
- (void)resetPreferencesToDefault;
@end

#pragma mark - AKRLabeledSliderCell

@interface AKRLabeledSliderCell : PSSliderTableCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;
- (void)layoutSubviews;
@end

#pragma mark - AKRTableCell

@interface AKRTableCell : PSTableCell
- (void)layoutSubviews;
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier;
@end

#pragma mark - AKRLinkCell

@interface AKRLinkCell : AKRTableCell
@property (nonatomic, readonly, getter=isBig) BOOL big;
@property (nonatomic, readonly, strong) UIView *avatarView;
@property (nonatomic, readonly, strong) UIImageView *avatarImageView;
@property (nonatomic, strong) UIImage *avatarImage;
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;
- (BOOL)shouldShowAvatar;
- (void)loadAvatarIfNeeded;
@end

#pragma mark - AKRHeaderCell

@interface AKRHeaderCell : PSTableCell <PSHeaderFooterView>
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIStackView *containerStackView;
@property (nonatomic, strong) UIView *backgroundView;
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;
- (instancetype)initWithSpecifier:(PSSpecifier *)specifier;
- (CGFloat)preferredHeightForWidth:(CGFloat)width;
@end

#pragma mark - AKRDuoTwitterCell

@interface AKRDuoTwitterCell : AKRTableCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;
- (void)handleLeftTap:(UITapGestureRecognizer *)gestureRecognizer;
- (void)handleRightTap:(UITapGestureRecognizer *)gestureRecognizer;
- (void)setSelected:(BOOL)selected animated:(BOOL)animated;
- (BOOL)canBecomeFirstResponder;
+ (instancetype)cellWithSpecifier:(PSSpecifier *)specifier;
@end
