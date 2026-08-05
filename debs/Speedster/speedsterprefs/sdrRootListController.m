#include "sdrRootListController.h"
#import "spawn.h"
#include <rootless.h>

@implementation sdrRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    NSArray *chosenIDs = @[@"2", @"3", @"4", @"5"];
    self.savedSpecifiers = (_savedSpecifiers) ?: [[NSMutableDictionary alloc] init];
    for(PSSpecifier *specifier in [self specifiersForIDs:chosenIDs]) {
     [self.savedSpecifiers setObject:specifier forKey:[specifier propertyForKey:@"id"]];
    }
    // 保存 EQ 相关 specifier(以 key 索引),供预设联动写入 10 段滑块
    for(PSSpecifier *specifier in _specifiers) {
        NSString *key = [specifier propertyForKey:@"key"];
        if ([key hasPrefix:@"eq"]) {
            [self.savedSpecifiers setObject:specifier forKey:key];
        }
    }
	}
	return _specifiers;
}

//BIG BRAIN LINK: https://www.reddit.com/r/jailbreakdevelopers/comments/e965nj/comment/fbf2xcv/
-(void)updateSpecifierVisibility:(BOOL)animated {
  NSDictionary *preferences = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hoangdus.speedsterprefs"];

  //Check if our switch is set to NO, then remove fine tune slider
  if(![preferences[@"isFineTuneSpeedEnable"] boolValue]) {
    [self removeSpecifier:self.savedSpecifiers[@"3"] animated:animated];
  // If the switch is set to YES, then add back fine tune slider
  } else if(![self containsSpecifier:self.savedSpecifiers[@"3"]]) {
    [self insertSpecifier:self.savedSpecifiers[@"3"] atIndex:8 animated:animated];
  }

  //Check if our switch is set to YES, then remove preset
  if([preferences[@"isFineTuneSpeedEnable"] boolValue]) {
    [self removeSpecifier:self.savedSpecifiers[@"2"] animated:animated];
  // If the switch is set to NO, add back the preset
  } else if(![self containsSpecifier:self.savedSpecifiers[@"2"]]) {
    [self insertSpecifier:self.savedSpecifiers[@"2"] atIndex:8 animated:animated];
  }

  //Check if our switch is set to NO, then remove fine tune slider
  if(![preferences[@"isFineTuneBounceEnable"] boolValue]) {
    [self removeSpecifier:self.savedSpecifiers[@"5"] animated:animated];
  // If the switch is set to YES, then add back fine tune slider
  } else if(![self containsSpecifier:self.savedSpecifiers[@"5"]]) {
    [self insertSpecifier:self.savedSpecifiers[@"5"] atIndex:11 animated:animated];
  }

  //Check if our switch is set to YES, then remove preset
  if([preferences[@"isFineTuneBounceEnable"] boolValue]) {
    [self removeSpecifier:self.savedSpecifiers[@"4"] animated:animated];
  // If the switch is set to NO, add back the preset
  } else if(![self containsSpecifier:self.savedSpecifiers[@"4"]]) {
    [self insertSpecifier:self.savedSpecifiers[@"4"] atIndex:11 animated:animated];
  }
}

-(void)reloadSpecifiers {
  [super reloadSpecifiers];
  [self updateSpecifierVisibility:NO];
}

-(void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
  [super setPreferenceValue:value specifier:specifier];
  [self updateSpecifierVisibility:YES];
}

-(void)viewDidLoad {
  [super viewDidLoad];
  [self updateSpecifierVisibility:NO];
  // 初始化预设跟踪值,避免首次进入触发 applyEQPreset
  NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hoangdus.speedsterprefs"];
  self.lastAppliedPreset = [prefs[@"eqPreset"] intValue];
}

-(void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  // PSLinkListCell 预设选择在子页触发,返回本页时检测变化并应用到 10 段滑块
  NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hoangdus.speedsterprefs"];
  int preset = [prefs[@"eqPreset"] intValue];
  if (preset != self.lastAppliedPreset) {
    self.lastAppliedPreset = preset;
    [self applyEQPreset:preset];
  }
}

// 将预设的 10 段增益写入 eqBand0~9 滑块并刷新界面;每个滑块带 PostNotification,
// 框架自动广播 Darwin 通知使 tweak 端热更新
-(void)applyEQPreset:(int)preset {
  if (preset < 0 || preset > 5) return;
  static const float presets[6][10] = {
    {0,0,0,0,0,0,0,0,0,0},      // 平坦
    {9,7,5,3,1,0,-2,-2,-1,0},   // 重低音
    {0,-1,-1,0,0,1,3,5,7,9},    // 高音清晰
    {5,4,3,1,0,0,1,2,4,5},      // 流行
    {4,5,3,-1,0,2,4,3,2,3},     // 摇滚
    {0,-1,-1,0,2,3,4,3,1,0},    // 人声
  };
  for (int i = 0; i < 10; i++) {
    PSSpecifier *sp = self.savedSpecifiers[[NSString stringWithFormat:@"eqBand%d", i]];
    if (sp) {
      [self setPreferenceValue:@(presets[preset][i]) specifier:sp];
    }
  }
  [self reloadSpecifiers];
}

- (void)respring:(id)sender{ //handle the "respring" button
    pid_t pid;
    posix_spawn(&pid, ROOT_PATH_VAR("/usr/bin/sbreload"), NULL, NULL, NULL, NULL);
}

@end

@implementation SdrHeaderCell
- (id)initWithSpecifier:(PSSpecifier *)specifier {
  self = [super initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"Cell"];

  if (self) {
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 30, self.frame.size.width, 60)];
    title.numberOfLines = 1;
    title.font = [UIFont systemFontOfSize:50];
    title.text = @"Speedster";
    title.textColor = [UIColor orangeColor];
    title.textAlignment = NSTextAlignmentCenter;
    [self addSubview:title];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 85, self.frame.size.width, 30)];
    subtitle.numberOfLines = 1;
    subtitle.font = [UIFont systemFontOfSize:20];
    subtitle.text = @"By HoangDus";
    subtitle.textColor = [UIColor grayColor];
    subtitle.textAlignment = NSTextAlignmentCenter;
    [self addSubview:subtitle];
  }
  return self;
}

- (CGFloat)preferredHeightForWidth:(CGFloat)arg1 {
  return 150.0;
}
@end
