#include "sdrRootListController.h"
#import "spawn.h"
#include <rootless.h>
#import <AVFAudio/AVFAudio.h>

@implementation sdrRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
		NSMutableDictionary *preferences = [[defaults persistentDomainForName:@"com.hoangdus.speedsterprefs"] mutableCopy];
		NSNumber *dockVisibility = preferences[@"dockVisibility"];
		if (dockVisibility && (dockVisibility.integerValue < 0 || dockVisibility.integerValue > 1)) {
			preferences[@"dockVisibility"] = @0;
			[defaults setPersistentDomain:preferences forName:@"com.hoangdus.speedsterprefs"];
			CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.hoangdus.speedsterprefs-updated"), NULL, NULL, YES);
		}
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    NSArray *chosenIDs = @[@"2", @"3", @"4", @"5"];
    self.savedSpecifiers = (_savedSpecifiers) ?: [[NSMutableDictionary alloc] init];
    for(PSSpecifier *specifier in [self specifiersForIDs:chosenIDs]) {
     [self.savedSpecifiers setObject:specifier forKey:[specifier propertyForKey:@"id"]];
    }
    // 保存 EQ / 音频相关 specifier(以 key 索引),供预设联动写入与重置按钮使用
    NSArray *audioKeys = @[@"globalGain", @"masterGain", @"stereoPan"];
    for(PSSpecifier *specifier in _specifiers) {
        NSString *key = [specifier propertyForKey:@"key"];
        if ([key hasPrefix:@"eq"] || [audioKeys containsObject:key]) {
            [self.savedSpecifiers setObject:specifier forKey:key];
        }
        // 按 id 保存(如重置/测试音按钮),便于按钮标题热更新
        NSString *sid = [specifier propertyForKey:@"id"];
        if (sid) {
            [self.savedSpecifiers setObject:specifier forKey:[@"id_" stringByAppendingString:sid]];
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
    [self insertSpecifier:self.savedSpecifiers[@"3"] atIndex:16 animated:animated];
  }

  //Check if our switch is set to YES, then remove preset
  if([preferences[@"isFineTuneSpeedEnable"] boolValue]) {
    [self removeSpecifier:self.savedSpecifiers[@"2"] animated:animated];
  // If the switch is set to NO, add back the preset
  } else if(![self containsSpecifier:self.savedSpecifiers[@"2"]]) {
    [self insertSpecifier:self.savedSpecifiers[@"2"] atIndex:16 animated:animated];
  }

  //Check if our switch is set to NO, then remove fine tune slider
  if(![preferences[@"isFineTuneBounceEnable"] boolValue]) {
    [self removeSpecifier:self.savedSpecifiers[@"5"] animated:animated];
  // If the switch is set to YES, then add back fine tune slider
  } else if(![self containsSpecifier:self.savedSpecifiers[@"5"]]) {
    [self insertSpecifier:self.savedSpecifiers[@"5"] atIndex:19 animated:animated];
  }

  //Check if our switch is set to YES, then remove preset
  if([preferences[@"isFineTuneBounceEnable"] boolValue]) {
    [self removeSpecifier:self.savedSpecifiers[@"4"] animated:animated];
  // If the switch is set to NO, add back the preset
  } else if(![self containsSpecifier:self.savedSpecifiers[@"4"]]) {
    [self insertSpecifier:self.savedSpecifiers[@"4"] atIndex:19 animated:animated];
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

// ===== 音频面板工具：重置 + 实时试听 =====

- (void)resetEQBands:(id)sender {
    for (int i = 0; i < 10; i++) {
        PSSpecifier *sp = self.savedSpecifiers[[NSString stringWithFormat:@"eqBand%d", i]];
        if (sp) [self setPreferenceValue:@(0.0) specifier:sp];
    }
    [self reloadSpecifiers];
    [self showToast:@"10 段 EQ 已重置为 0 dB"];
}

- (void)resetAudioSettings:(id)sender {
    NSDictionary *defaults = @{
        @"globalGain": @3.0,
        @"eqGlobalQ":  @2.0,
        @"masterGain": @6.0,
        @"stereoPan":  @0.0,
    };
    for (NSString *key in defaults) {
        PSSpecifier *sp = self.savedSpecifiers[key];
        if (sp) [self setPreferenceValue:defaults[key] specifier:sp];
    }
    [self reloadSpecifiers];
    [self showToast:@"音频设置已恢复默认"];
}

- (void)toggleTestTone:(id)sender {
    if (self.testTonePlaying) {
        [self stopTestTone];
    } else {
        [self startTestTone];
    }
    [self updateTestToneButton];
}

- (void)startTestTone {
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:&err];
    [session setActive:YES error:&err];

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioPlayerNode *player = [[AVAudioPlayerNode alloc] init];

    // 系统级全局 EQ 开启时，曲线已由 Core Audio 输出层 DSP 统一处理，测试音不再插入
    // AVAudioUnitEQ 节点，避免双重 EQ；关闭时保留 10 段 EQ 节点用于实时验证。
    NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] persistentDomainForName:@"com.hoangdus.speedsterprefs"];
    BOOL systemWide = [prefs[@"globalEQSystemWide"] boolValue];

    AVAudioFormat *outFmt = [engine.mainMixerNode outputFormatForBus:0];
    [engine attachNode:player];
    if (systemWide) {
        [engine connect:player to:engine.mainMixerNode format:outFmt];
    } else {
        // 10 段 EQ 实例会被 tweak 端 hook 注册并热更新，用于实时验证
        AVAudioUnitEQ *eq = [[AVAudioUnitEQ alloc] initWithNumberOfBands:10];
        [engine attachNode:eq];
        [engine connect:player to:eq format:outFmt];
        [engine connect:eq to:engine.mainMixerNode format:outFmt];
        self.testEQ = eq;
    }

    if (![engine startAndReturnError:&err]) {
        [self showToast:[NSString stringWithFormat:@"音频启动失败：%@", err.localizedDescription]];
        return;
    }

    // 白噪声 2 秒循环缓冲（幅度压低，避免 EQ 增益后削波）
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:44100 * 2];
    buf.frameLength = 44100 * 2;
    float *ch0 = buf.floatChannelData[0];
    float *ch1 = buf.floatChannelData[1];
    for (UInt32 i = 0; i < buf.frameLength; i++) {
        float v = ((float)arc4random_uniform(UINT32_MAX) / (float)UINT32_MAX) * 2.0f - 1.0f;
        ch0[i] = v * 0.3f;
        ch1[i] = v * 0.3f;
    }
    [player scheduleBuffer:buf atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [player play];

    // 立即应用当前 EQ 曲线（触发 tweak 端 bands hook 写入增益；系统级模式无 EQ 节点则跳过）
    if (self.testEQ) [self.testEQ bands];

    self.testEngine = engine;
    self.testPlayer = player;
    self.testTonePlaying = YES;
    [self showToast:@"测试音播放中：拖动 EQ 滑块实时试听"];
}

- (void)stopTestTone {
    if (self.testPlayer) [self.testPlayer stop];
    if (self.testEngine) [self.testEngine stop];
    if (self.testEngine && self.testEQ) [self.testEngine disconnectNodeOutput:self.testEQ];
    if (self.testEngine && self.testEQ) [self.testEngine detachNode:self.testEQ];
    if (self.testEngine && self.testPlayer) [self.testEngine detachNode:self.testPlayer];
    self.testPlayer = nil;
    self.testEQ = nil;
    self.testEngine = nil;
    self.testTonePlaying = NO;
}

- (void)updateTestToneButton {
    PSSpecifier *sp = self.savedSpecifiers[@"id_testTone"];
    NSString *title = self.testTonePlaying ? @"停止测试音" : @"播放测试音（实时验证 EQ）";
    [sp setName:title];
    // 直接刷新可见按钮 cell 的标题（无需整表重载，避免滚动位置丢失）
    for (UITableViewCell *cell in self.table.visibleCells) {
        if ([cell isKindOfClass:[PSTableCell class]]) {
            PSTableCell *pc = (PSTableCell *)cell;
            if ([pc.specifier propertyForKey:@"id"] && [[pc.specifier propertyForKey:@"id"] isEqual:@"testTone"]) {
                pc.titleLabel.text = title;
            }
        }
    }
}

- (void)showToast:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // 离开设置页时停止测试音，避免后台继续播放
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [self stopTestTone];
    }
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
