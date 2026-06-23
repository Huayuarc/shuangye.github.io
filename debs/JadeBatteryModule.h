// JadeBatteryModule.h
// Battery module displaying battery levels of all connected devices

#import <UIKit/UIKit.h>
#import "JadeBatteryDevice.h"

NS_ASSUME_NONNULL_BEGIN

@class JadeBatteryDevice;

@interface JadeBatteryModule : UIView

@property (nonatomic, strong, nullable) UILabel *titleLabel;
@property (nonatomic, strong, nullable) UIStackView *devicesStackView;
@property (nonatomic, strong, nullable) NSMutableArray<JadeBatteryDevice *> *connectedDevices;
@property (nonatomic, strong, nullable) JadeBatteryDevice *internalDevice;
@property (nonatomic, strong, nullable) UIColor *moduleTintColor;
@property (nonatomic, assign) BOOL isExpanded;

- (void)setupViews;
- (void)setupConstraints;
- (void)refreshBatteryData;
- (void)updateDeviceList;
- (void)addDevice:(JadeBatteryDevice *)device;
- (void)removeDevice:(JadeBatteryDevice *)device;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
- (void)startAutoRefresh;
- (void)stopAutoRefresh;

@end

NS_ASSUME_NONNULL_END
