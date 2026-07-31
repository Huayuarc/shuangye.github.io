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