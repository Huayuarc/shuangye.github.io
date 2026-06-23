// JadeConnectivityModule.h
// Connectivity controls module (WiFi, Bluetooth, Cellular, Airplane Mode, VPN, etc.)

#import <UIKit/UIKit.h>
#import "JadeConnectivityButton.h"

NS_ASSUME_NONNULL_BEGIN

@interface JadeConnectivityModule : UIView

@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UIStackView *buttonsStackView;
@property (nonatomic, strong, nullable) NSMutableArray<JadeConnectivityButton *> *connectivityButtons;
@property (nonatomic, strong, nullable) UIColor *moduleTintColor;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, assign) NSInteger buttonsPerRow;
@property (nonatomic, assign) BOOL showsLabels;

- (void)setupViews;
- (void)setupConstraints;
- (void)reloadButtons;
- (void)addButtonWithConnectivityType:(JadeConnectivityType)type;
- (void)removeButtonWithConnectivityType:(JadeConnectivityType)type;
- (void)updateButtonStates;
- (void)updateCellularStateIfNeeded;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)refreshConnectivityStates;

@end

NS_ASSUME_NONNULL_END
