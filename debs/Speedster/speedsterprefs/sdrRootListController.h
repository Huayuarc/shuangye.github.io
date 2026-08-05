#import <Preferences/PSListController.h>
#import <Preferences/PSSwitchTableCell.h>
#import <Preferences/PSSpecifier.h>

@interface PSListController (Private)
-(BOOL)containsSpecifier:(PSSpecifier *)arg1;
@end

@interface sdrRootListController : PSListController
@property (nonatomic, retain) NSMutableDictionary *savedSpecifiers;
@property (nonatomic, assign) int lastAppliedPreset;   // 已应用的 EQ 预设,用于子页返回时检测变化
@end

@interface SdrHeaderCell : UITableViewCell
@end

@interface SpeedsterSwitchCell : PSSwitchTableCell
-(id)initWithStyle:(int)arg1 reuseIdentifier:(id)arg2 specifier:(id)arg3 ;
@end