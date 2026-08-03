#include "sdrRootListController.h"
#import "spawn.h"
#include <rootless.h>

@implementation sdrRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    NSArray *chosenIDs = @[@"2", @"3", @"4", @"5", @"8", @"6"];
    self.savedSpecifiers = (_savedSpecifiers) ?: [[NSMutableDictionary alloc] init];
    for(PSSpecifier *specifier in [self specifiersForIDs:chosenIDs]) {
     [self.savedSpecifiers setObject:specifier forKey:[specifier propertyForKey:@"id"]];
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

  //Dock 图标数量：开关关闭时隐藏 stepper，开启时在"自定义 Dock 图标数量"开关后显示
  if(![preferences[@"dockIconCountEnabled"] boolValue]) {
    [self removeSpecifier:self.savedSpecifiers[@"6"] animated:animated];
  // If the switch is set to YES, then add back the stepper
  } else if(![self containsSpecifier:self.savedSpecifiers[@"6"]]) {
    [self insertSpecifier:self.savedSpecifiers[@"6"] afterSpecifierID:@"7" animated:animated];
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
