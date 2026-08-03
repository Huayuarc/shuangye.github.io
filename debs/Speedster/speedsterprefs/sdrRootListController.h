#import <Preferences/PSListController.h>
#import <Preferences/PSSwitchTableCell.h>
#import <Preferences/PSSpecifier.h>

@interface PSListController (Private)
-(BOOL)containsSpecifier:(PSSpecifier *)arg1;
@end

@interface sdrRootListController : PSListController
@property (nonatomic, retain) NSMutableDictionary *savedSpecifiers;
@end

@interface SdrHeaderCell : UITableViewCell
@end

@interface SpeedsterSwitchCell : PSSwitchTableCell
-(id)initWithStyle:(int)arg1 reuseIdentifier:(id)arg2 specifier:(id)arg3 ;
@end

// PSTableCell 偏好读写方法扩展（Preferences 私有框架运行时方法）
@interface PSTableCell (SdrStepperExt)
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

// Dock 图标数量 +/- 调节 cell（FiveIconDockXI 移植）
@interface SdrStepperCell : PSTableCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier;
@end