// JadePowerModule.h
// Power control module with shutdown, restart, respring, safe mode, and lock buttons

#import <UIKit/UIKit.h>
#import "JadePowerModuleButton.h"

NS_ASSUME_NONNULL_BEGIN

@interface JadePowerModule : UIView

@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UIStackView *buttonsStackView;
@property (nonatomic, strong, nullable) NSMutableArray<JadePowerModuleButton *> *actionButtons;
@property (nonatomic, strong, nullable) UIColor *moduleTintColor;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, assign) BOOL showsConfirmationDialogs;
@property (nonatomic, assign) NSInteger buttonsPerRow;

- (void)setupViews;
- (void)setupConstraints;
- (void)reloadButtons;
- (void)addButtonWithActionType:(JadePowerActionType)actionType;
- (void)removeButtonWithActionType:(JadePowerActionType)actionType;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)performAction:(JadePowerActionType)actionType;

@end

NS_ASSUME_NONNULL_END
