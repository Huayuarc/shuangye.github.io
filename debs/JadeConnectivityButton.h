// JadeConnectivityButton.h
// Individual connectivity toggle button (WiFi, Bluetooth, Cellular, Airplane Mode, etc.)

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, JadeConnectivityType) {
    JadeConnectivityTypeWiFi,
    JadeConnectivityTypeCellular,
    JadeConnectivityTypeBluetooth,
    JadeConnectivityTypeAirplaneMode,
    JadeConnectivityTypeVPN,
    JadeConnectivityTypePersonalHotspot,
    JadeConnectivityTypeAirdrop
};

@interface JadeConnectivityButton : UIControl

@property (nonatomic, assign) JadeConnectivityType connectivityType;
@property (nonatomic, strong, nullable) UIImageView *iconImageView;
@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UIView *indicatorView;
@property (nonatomic, strong, nullable) UIColor *activeColor;
@property (nonatomic, strong, nullable) UIColor *inactiveColor;
@property (nonatomic, strong, nullable) UIColor *highlightedColor;
@property (nonatomic, assign) CGFloat buttonSize;
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, assign, getter=isActive) BOOL active;
@property (nonatomic, assign) BOOL showIndicatorDot;
@property (nonatomic, assign) SEL action;

+ (instancetype)buttonWithConnectivityType:(JadeConnectivityType)type;
- (void)setupViews;
- (void)setupConstraints;
- (void)setActive:(BOOL)active animated:(BOOL)animated;
- (void)setEnabled:(BOOL)enabled animated:(BOOL)animated;
- (void)toggleState;
- (NSString *)buttonTitle;
- (UIImage *)buttonIcon;
- (UIColor *)colorForState;

@end

NS_ASSUME_NONNULL_END
