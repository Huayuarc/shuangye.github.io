// JadePowerModuleButton.h
// Individual power action button (Shutdown, Restart, Respring, Safe Mode, Lock)

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, JadePowerActionType) {
    JadePowerActionTypeShutdown,
    JadePowerActionTypeRestart,
    JadePowerActionTypeRespring,
    JadePowerActionTypeSafeMode,
    JadePowerActionTypeLockDevice,
    JadePowerActionTypeExit
};

@interface JadePowerModuleButton : UIControl

@property (nonatomic, assign) JadePowerActionType actionType;
@property (nonatomic, strong, nullable) UIImageView *iconImageView;
@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UIColor *buttonColor;
@property (nonatomic, strong, nullable) UIColor *highlightedColor;
@property (nonatomic, strong, nullable) UIColor *iconTintColor;
@property (nonatomic, assign) CGFloat buttonSize;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign) BOOL isDestructive;

+ (instancetype)buttonWithActionType:(JadePowerActionType)actionType;
- (void)setupViews;
- (void)setupConstraints;
- (void)setButtonColor:(UIColor *)color animated:(BOOL)animated;
- (void)performAction;
- (NSString *)actionTitle;
- (UIImage *)actionIcon;
- (void)triggerConfirmation;

@end

NS_ASSUME_NONNULL_END
