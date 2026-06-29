#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <BulletinBoard/BBBulletin.h>
#import <roothide.h>
#import <os/log.h>

// BBBulletin 私有方法(运行时自省确认存在于 iOS 16.3.1):
//   @prop sound BBSound + setSound:                    声音载体
//   @prop callNotification (getter isCallNotification) 通话(语音/视频)通知标记
// 参数用 id 避免引入 BBSound 头。
@interface BBBulletin (CNSSound)
- (void)setSound:(id)sound;
- (id)sound;
- (BOOL)isCallNotification;
@end

// ===== 全局状态(配置先行, 供日志门控读取) =====
static NSDictionary *gConfig = nil;
static NSMutableArray *gPlayers = nil;   // 持有 AVAudioPlayer 强引用, 防异步播放被回收

static NSString *kConfigPath = @"/var/mobile/Library/Preferences/net.xyzl.customnotisound.plist";

// 启动宽限期: SpringBoard 注销/重启后会把通知中心里的历史通知 republish 一遍,
// 这些旧通知同样流经 publishBulletin: 会被误播。记录加载时刻, 宽限期内一律放行不处理。
// 宽限秒数可在设置面板配置(startupGrace), 缺省 10 秒。
static CFAbsoluteTime gLoadTime = 0;

// ===== 日志: os_log + 文件兜底, 受 debugLog 门控 =====
static BOOL CNSDebugEnabled(void) {
    return [gConfig[@"debugLog"] boolValue];
}
static os_log_t CNSLogHandle(void) {
    static os_log_t h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = os_log_create("com.xyzl.customnotisound", "Tweak"); });
    return h;
}
static void CNSFileLog(NSString *msg) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"%@ [SpringBoard] %@\n",
                      [fmt stringFromDate:[NSDate date]], msg];
    NSString *path = jbroot(@"/var/mobile/customnotisound.log");
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (__unused NSException *e) {}
        [fh closeFile];
    }
}
static inline void CNSLogImpl(NSString *msg) {
    if (!CNSDebugEnabled()) return;
    os_log(CNSLogHandle(), "%{public}s", msg.UTF8String);
    CNSFileLog(msg);
}
#define CNSLog(fmt, ...) CNSLogImpl([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

// ===== AVAudioPlayer 播放完自动回收 =====
// 播放器全部回收后归还音频会话(setActive:NO + NotifyOthersOnDeactivation),
// 让出给后台音乐/播客, 避免长期占用会话压低或打断它们。
@interface CNSPlayerDelegate : NSObject <AVAudioPlayerDelegate>
@end
@implementation CNSPlayerDelegate
- (void)cnsReleasePlayer:(AVAudioPlayer *)player {
    [gPlayers removeObject:player];
    if (gPlayers.count == 0) {
        [[AVAudioSession sharedInstance] setActive:NO
            withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    [self cnsReleasePlayer:player];
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    [self cnsReleasePlayer:player];
}
@end
static CNSPlayerDelegate *gPlayerDelegate = nil;

// ===== 加载配置 =====
static void CNSLoadConfig(void) {
    gConfig = [NSDictionary dictionaryWithContentsOfFile:jbroot(kConfigPath)];
    CNSLog(@"加载配置: %@ 条规则", @([gConfig[@"rules"] count]));
}
static void CNSConfigChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *ob, CFDictionaryRef u) {
    CNSLoadConfig();
}

// ===== 单字段匹配 =====
// 留空=通配; 否则按 exact 决定"完全相等"或"包含"(均不区分大小写)。
static BOOL CNSFieldMatch(NSString *ruleValue, NSString *bulletinValue, BOOL exact) {
    if (ruleValue == nil || ruleValue.length == 0) return YES;
    if (bulletinValue == nil) return NO;
    if (exact) return [ruleValue caseInsensitiveCompare:bulletinValue] == NSOrderedSame;
    return [bulletinValue rangeOfString:ruleValue options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// ===== BundleID 匹配 =====
// 规则 bundleID 支持逗号分隔多个; 留空=通配。
// exclude=YES 时语义反转: 列表内的 App 不命中(排除), 列表外的命中。
static BOOL CNSBundleMatch(NSString *ruleBundle, NSString *bulletinBundle, BOOL exclude) {
    if (ruleBundle.length == 0) {
        // 未填 BundleID: 正常规则=通配命中; 排除规则=无意义, 视为不限制
        return exclude ? NO : YES;
    }
    BOOL listed = NO;
    for (NSString *raw in [ruleBundle componentsSeparatedByString:@","]) {
        NSString *bid = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (bid.length > 0 && [bid isEqualToString:bulletinBundle]) { listed = YES; break; }
    }
    return exclude ? !listed : listed;
}

// ===== 查找命中规则 =====
static NSDictionary *CNSFindMatchingRule(BBBulletin *bulletin) {
    NSArray *rules = gConfig[@"rules"];
    if (![rules isKindOfClass:[NSArray class]]) return nil;

    NSString *bundleID = bulletin.sectionID;
    NSString *title    = bulletin.title;
    NSString *subtitle = bulletin.subtitle;
    NSString *message  = bulletin.message;

    for (NSDictionary *rule in rules) {
        if (![rule isKindOfClass:[NSDictionary class]]) continue;
        if (![rule[@"enabled"] boolValue]) continue;

        BOOL exclude = [rule[@"exclude"] boolValue];
        if (!CNSBundleMatch(rule[@"bundleID"], bundleID, exclude)) continue;

        BOOL exact = (rule[@"exactMatch"] == nil) ? YES : [rule[@"exactMatch"] boolValue];
        if (!CNSFieldMatch(rule[@"title"],    title,    exact)) continue;
        if (!CNSFieldMatch(rule[@"subtitle"], subtitle, exact)) continue;
        if (!CNSFieldMatch(rule[@"message"],  message,  exact)) continue;

        return rule;   // 首条命中即返回(数组顺序即优先级)
    }
    return nil;
}

// ===== 音频路径归一化(解耦 roothide 随机化 .jbroot-XXXX) =====
// 每次重越狱 jbroot 入口名随机变化。把任意路径剥成 jbroot 相对路径, 再 jbroot() 拼当前前缀,
// 即便用户没打开过设置页, 通知触发时也能直接解析对。
static NSString *CNSNormalizeSoundPath(NSString *path) {
    if (path.length == 0) return path;
    NSRange mark = [path rangeOfString:@"/.jbroot-"];
    if (mark.location != NSNotFound) {
        NSUInteger from = mark.location + mark.length;
        NSRange slash = [path rangeOfString:@"/"
            options:0 range:NSMakeRange(from, path.length - from)];
        if (slash.location != NSNotFound)
            return [path substringFromIndex:slash.location];
    }
    return path;
}

// ===== 播放自定义音频 =====
// respectMute: YES=Ambient(跟随响铃/静音拨片); NO=Playback(无视静音强制出声)。
static void CNSPlaySound(NSString *soundFile, BOOL respectMute) {
    if (soundFile.length == 0) return;

    // 路径解析: 先归一化剥掉 .jbroot-XXXX 随机前缀, 再 jbroot() 拼当前前缀还原。
    // 绝不对已含 jbroot 前缀的完整路径再套 jbroot()(否则前缀翻倍 -> 无声)。
    NSString *norm = CNSNormalizeSoundPath(soundFile);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fullPath = nil;
    if ([fm fileExistsAtPath:norm]) fullPath = norm;
    else if ([norm hasPrefix:@"/"]) {
        NSString *jbPath = jbroot(norm);
        if ([fm fileExistsAtPath:jbPath]) fullPath = jbPath;
    }
    if (fullPath == nil) { CNSLog(@"音频文件不存在: %@", soundFile); return; }

    NSError *err = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:fullPath] error:&err];
    if (err || !player) { CNSLog(@"AVAudioPlayer 初始化失败: %@", err); return; }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSString *cat = respectMute ? AVAudioSessionCategoryAmbient : AVAudioSessionCategoryPlayback;
    [session setCategory:cat error:nil];
    [session setActive:YES error:nil];

    player.delegate = gPlayerDelegate;
    [gPlayers addObject:player];
    [player prepareToPlay];
    [player play];
    CNSLog(@"播放音频: %@ (respectMute=%d)", fullPath, respectMute);
}

// ===== Hook: 通知投递总入口 =====
%hook BBServer

- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations {
    NSDictionary *rule = nil;
    BOOL respectMute = YES;

    @try {
        if ([gConfig[@"enabled"] boolValue] && bulletin != nil) {
            CNSLog(@"通知 section=%@ title=%@ subtitle=%@ msg=%@",
                   bulletin.sectionID, bulletin.title, bulletin.subtitle, bulletin.message);

            // 启动宽限期内(注销/重启刚完成), 历史通知被 republish, 一律放行不处理:
            // 不匹配、不去原声、不播自定义声, 避免"注销完成必响一次"。
            CFTimeInterval grace = (gConfig[@"startupGrace"] != nil)
                ? [gConfig[@"startupGrace"] doubleValue] : 10.0;
            if (CFAbsoluteTimeGetCurrent() - gLoadTime < grace) {
                CNSLog(@"启动宽限期内(%.0fs), 跳过(疑似 republish 历史通知)", grace);
            } else {
            BOOL isCall = NO;
            if ([bulletin respondsToSelector:@selector(isCallNotification)]) {
                isCall = [bulletin isCallNotification];
            }
            if (isCall) {
                CNSLog(@"通话通知, 跳过(保留系统铃声)");
            } else {
                rule = CNSFindMatchingRule(bulletin);
                if (rule != nil) {
                    CNSLog(@"命中规则: %@", rule[@"bundleID"] ?: @"(任意)");
                    respectMute = (gConfig[@"respectMute"] == nil) ? YES : [gConfig[@"respectMute"] boolValue];
                    // 命中=替换: %orig 投递前去掉系统原声
                    if ([rule[@"sound"] length] > 0 &&
                        [bulletin respondsToSelector:@selector(setSound:)]) {
                        [bulletin setSound:nil];
                        CNSLog(@"已清除系统原声(setSound:nil)");
                    }
                }
            }
            }
        }
    } @catch (NSException *e) {
        CNSLog(@"publishBulletin 预处理异常: %@", e);
        rule = nil;
    }

    %orig;

    @try {
        if (rule != nil && [rule[@"sound"] length] > 0) {
            CNSPlaySound(rule[@"sound"], respectMute);
        }
    } @catch (NSException *e) {
        CNSLog(@"publishBulletin 播放异常: %@", e);
    }
}

%end

// ===== 初始化 =====
%ctor {
    @autoreleasepool {
        gLoadTime = CFAbsoluteTimeGetCurrent();
        gPlayers = [NSMutableArray array];
        gPlayerDelegate = [CNSPlayerDelegate new];

        NSString *soundsDir = jbroot(@"/var/mobile/Library/CustomNotiSound");
        [[NSFileManager defaultManager] createDirectoryAtPath:soundsDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        CNSLoadConfig();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, CNSConfigChanged,
            CFSTR("com.xyzl.customnotisound/preferences"),
            NULL, CFNotificationSuspensionBehaviorCoalesce);

        CNSLog(@"已加载到 SpringBoard");
    }
}

