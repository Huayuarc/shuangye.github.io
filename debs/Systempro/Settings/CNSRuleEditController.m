#import "CNSRuleEditController.h"
#import "CNSPrefs.h"
#import <roothide.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>

typedef NS_ENUM(NSInteger, CNSApplicationSectionType) {
    CNS_SECTION_TYPE_SYSTEM = 1,
    CNS_SECTION_TYPE_USER = 2,
};

static void CNSLoadAltListIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *jbPath = jbroot(@"/Library/Frameworks/AltList.framework/AltList");
        if (jbPath.length > 0) dlopen(jbPath.UTF8String, RTLD_LAZY | RTLD_LOCAL);
        dlopen("/var/jb/Library/Frameworks/AltList.framework/AltList", RTLD_LAZY | RTLD_LOCAL);
        dlopen("/Library/Frameworks/AltList.framework/AltList", RTLD_LAZY | RTLD_LOCAL);
    });
}

@interface CNSRuleEditController () <AVAudioPlayerDelegate>
@property (nonatomic, copy)   NSString *ruleID;
@property (nonatomic, strong) NSMutableDictionary *rule;
@property (nonatomic, strong) AVAudioPlayer *previewPlayer;
@end

@implementation CNSRuleEditController

- (void)loadRuleFromStore {
    self.ruleID = [self.specifier propertyForKey:@"cnsRuleID"];
    NSMutableDictionary *r = [CNSConfig ruleWithID:self.ruleID];
    self.rule = r ?: [NSMutableDictionary dictionary];
}

- (void)persist {
    if (self.ruleID.length == 0) return;
    self.rule[CNS_RULE_ID] = self.ruleID;     // 确保主键随写回
    [CNSConfig upsertRule:self.rule];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadRuleFromStore];
    self.navigationItem.title = @"编辑规则";
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.previewPlayer stop];
    self.previewPlayer = nil;
}

- (PSSpecifier *)textFieldNamed:(NSString *)label key:(NSString *)key placeholder:(NSString *)ph {
    PSSpecifier *s = [PSSpecifier preferenceSpecifierNamed:label
        target:self set:@selector(setText:specifier:) get:@selector(getText:)
        detail:nil cell:PSEditTextCell edit:nil];
    [s setProperty:key forKey:@"cnsKey"];
    if (ph) [s setProperty:ph forKey:@"placeholder"];
    [s setProperty:@NO forKey:@"autoCaps"];
    [s setProperty:@NO forKey:@"autoCorrection"];
    return s;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        if (self.rule == nil) [self loadRuleFromStore];
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *grp0 = [PSSpecifier groupSpecifierWithName:@""];
        [specs addObject:grp0];
        PSSpecifier *sw = [PSSpecifier preferenceSpecifierNamed:@"启用此规则"
            target:self set:@selector(setEnabled:specifier:) get:@selector(getEnabled:)
            detail:nil cell:PSSwitchCell edit:nil];
        [specs addObject:sw];

        PSSpecifier *grp1 = [PSSpecifier groupSpecifierWithName:@"匹配条件"];
        [grp1 setProperty:@"BundleID 可填多个(逗号分隔)。留空=不限制该字段。下方“精确匹配”决定文字是“完全相等”还是“包含”。" forKey:@"footerText"];
        [specs addObject:grp1];
        [specs addObject:[self textFieldNamed:@"App BundleID" key:CNS_RULE_BUNDLEID placeholder:@"com.tencent.xin, com.apple.MobileSMS"]];

        // "选择 App" 按钮: 点击时代码 push AltList 选择器(见 cnsPickApp)。
        // 不内联 PSLinkListCell, 避免编辑页渲染期触发 AltList 而闪退。
        PSSpecifier *pick = [PSSpecifier preferenceSpecifierNamed:@"从已装 App 选择"
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        pick->action = @selector(cnsPickApp);
        [pick setProperty:@YES forKey:@"enabled"];
        [specs addObject:pick];

        PSSpecifier *swExclude = [PSSpecifier preferenceSpecifierNamed:@"排除模式"
            target:self set:@selector(setExclude:specifier:) get:@selector(getExclude:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swExclude setProperty:@"开启: 上面列出的 App 不替换(排除), 其余 App 命中。关闭(默认): 仅列出的 App 命中。" forKey:@"footerText"];
        [specs addObject:swExclude];

        [specs addObject:[self textFieldNamed:@"标题"   key:CNS_RULE_TITLE    placeholder:@"留空=不限"]];
        [specs addObject:[self textFieldNamed:@"副标题" key:CNS_RULE_SUBTITLE placeholder:@"留空=不限"]];
        [specs addObject:[self textFieldNamed:@"内容"   key:CNS_RULE_MESSAGE  placeholder:@"留空=不限"]];

        PSSpecifier *swExact = [PSSpecifier preferenceSpecifierNamed:@"精确匹配"
            target:self set:@selector(setExact:specifier:) get:@selector(getExact:)
            detail:nil cell:PSSwitchCell edit:nil];
        [swExact setProperty:@"开启: 文字需完全相等(如“工作”不匹配“工作号”)。关闭: 含即匹配。BundleID 始终精确。" forKey:@"footerText"];
        [specs addObject:swExact];

        PSSpecifier *grp2 = [PSSpecifier groupSpecifierWithName:@"提示音"];
        [grp2 setProperty:[NSString stringWithFormat:@"手填音频文件的绝对路径。推荐放入 %@ 目录。", CNS_SOUNDS_DIR] forKey:@"footerText"];
        [specs addObject:grp2];

        [specs addObject:[self textFieldNamed:@"音频路径" key:CNS_RULE_SOUND placeholder:@"/var/mobile/Library/CustomNotiSound/x.caf"]];

        PSSpecifier *grp3 = [PSSpecifier groupSpecifierWithName:@""];
        [specs addObject:grp3];
        PSSpecifier *test = [PSSpecifier preferenceSpecifierNamed:@"试听"
            target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        test->action = @selector(cnsPreview);
        [test setProperty:@YES forKey:@"enabled"];
        [specs addObject:test];

        _specifiers = specs;
    }
    return _specifiers;
}

- (id)getText:(PSSpecifier *)s { return self.rule[[s propertyForKey:@"cnsKey"]] ?: @""; }
- (void)setText:(id)v specifier:(PSSpecifier *)s {
    NSString *key = [s propertyForKey:@"cnsKey"];
    NSString *val = v ?: @"";
    // 音频路径归一化: 剥掉 .jbroot-XXXX 随机前缀只存相对路径, 避免重越狱后失效
    if ([key isEqualToString:CNS_RULE_SOUND]) val = CNSNormalizeSoundPath(val);
    self.rule[key] = val;
    [self persist];
}

// App 选择器: 代码构造 AltList 选择器并 push, 选中后经 set selector 回写 bundleID
- (id)getBundleID:(PSSpecifier *)s { return self.rule[CNS_RULE_BUNDLEID] ?: @""; }
- (void)setBundleID:(id)v specifier:(PSSpecifier *)s {
    self.rule[CNS_RULE_BUNDLEID] = v ?: @"";
    [self persist];
    [self reloadSpecifiers];   // 刷新上方"App BundleID"文本框显示
}

- (void)cnsPickApp {
    CNSLoadAltListIfNeeded();
    Class selCls = NSClassFromString(@"ATLApplicationListSelectionController");
    Class secCls = NSClassFromString(@"ATLApplicationSection");
    if (selCls == Nil || secCls == Nil) {
        [self cnsAlert:@"AltList 未安装" msg:@"图形选择需要 AltList, 可直接在“App BundleID”手填。"];
        return;
    }
    @try {
        // 构造 User + System 两个分区
        id (*sendInteger)(id, SEL, NSInteger) = (id (*)(id, SEL, NSInteger))objc_msgSend;
        id (*sendObject)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id userSec = sendInteger([secCls alloc], @selector(initNonCustomSectionWithType:), CNS_SECTION_TYPE_USER);
        id sysSec  = sendInteger([secCls alloc], @selector(initNonCustomSectionWithType:), CNS_SECTION_TYPE_SYSTEM);
        id picker  = sendObject([selCls alloc], @selector(initWithSections:), @[userSec, sysSec]);
        [picker setValue:@YES forKey:@"useSearchBar"];

        // 给选择器一个 specifier, 它会用其 get/set 读当前值并回写选中的 bundleID
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:@"选择 App"
            target:self set:@selector(setBundleID:specifier:) get:@selector(getBundleID:)
            detail:nil cell:PSLinkListCell edit:nil];
        [picker setValue:spec forKey:@"specifier"];

        [self pushController:picker];
    } @catch (NSException *e) {
        [self cnsAlert:@"无法打开选择器" msg:[NSString stringWithFormat:@"%@", e.reason ?: @"未知错误"]];
    }
}
- (id)getEnabled:(PSSpecifier *)s { return self.rule[CNS_RULE_ENABLED] ?: @YES; }
- (void)setEnabled:(id)v specifier:(PSSpecifier *)s { self.rule[CNS_RULE_ENABLED] = v ?: @NO; [self persist]; }
- (id)getExact:(PSSpecifier *)s { id v = self.rule[CNS_RULE_EXACT]; return v ?: @YES; }
- (void)setExact:(id)v specifier:(PSSpecifier *)s { self.rule[CNS_RULE_EXACT] = v ?: @NO; [self persist]; }
- (id)getExclude:(PSSpecifier *)s { return self.rule[CNS_RULE_EXCLUDE] ?: @NO; }
- (void)setExclude:(id)v specifier:(PSSpecifier *)s { self.rule[CNS_RULE_EXCLUDE] = v ?: @NO; [self persist]; }

- (void)cnsPreview {
    NSString *sound = self.rule[CNS_RULE_SOUND];
    if (sound.length == 0) { [self cnsAlert:@"未设置音频" msg:@"请先选择或填写音频路径。"]; return; }
    // 归一化解析: 剥随机前缀后用 jbroot() 还原当前可用路径
    NSString *full = CNSResolveSoundPath(sound);
    if (full == nil) { [self cnsAlert:@"文件不存在" msg:[NSString stringWithFormat:@"找不到音频:\n%@", sound]]; return; }

    // 多次试听: 先停掉上一个再播新的, 避免叠音
    [self.previewPlayer stop];
    self.previewPlayer = nil;

    NSError *err = nil;
    self.previewPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:full] error:&err];
    if (err || !self.previewPlayer) { [self cnsAlert:@"无法播放" msg:(err.localizedDescription ?: @"未知错误")]; return; }
    self.previewPlayer.delegate = self;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    [self.previewPlayer prepareToPlay];
    [self.previewPlayer play];
}

// 试听播放结束: 释放播放器
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player == self.previewPlayer) self.previewPlayer = nil;
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if (player == self.previewPlayer) self.previewPlayer = nil;
}

- (void)cnsAlert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end
