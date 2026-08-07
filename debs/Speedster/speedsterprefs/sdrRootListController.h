#import <Preferences/PSListController.h>
#import <Preferences/PSSwitchTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSSliderTableCell.h>
#import <Preferences/PSTableCell.h>

@class AVAudioEngine, AVAudioPlayerNode, AVAudioUnitEQ;

@interface PSListController (Private)
-(BOOL)containsSpecifier:(PSSpecifier *)arg1;
@end

@interface sdrRootListController : PSListController
@property (nonatomic, retain) NSMutableDictionary *savedSpecifiers;
@property (nonatomic, assign) int lastAppliedPreset;   // 已应用的 EQ 预设,用于子页返回时检测变化
// 实时试听（测试音）
@property (nonatomic, retain) AVAudioEngine *testEngine;
@property (nonatomic, retain) AVAudioPlayerNode *testPlayer;
@property (nonatomic, retain) AVAudioUnitEQ *testEQ;
@property (nonatomic, assign) BOOL testTonePlaying;
- (void)resetEQBands:(id)sender;
- (void)resetAudioSettings:(id)sender;
- (void)toggleTestTone:(id)sender;
- (void)showToast:(NSString *)message;
- (void)respring:(id)sender;
@end

@interface SdrHeaderCell : UITableViewCell
@end

@interface SpeedsterSwitchCell : PSSwitchTableCell
-(id)initWithStyle:(int)arg1 reuseIdentifier:(id)arg2 specifier:(id)arg3 ;
@end

@interface SdrEQSliderCell : PSSliderTableCell
@end