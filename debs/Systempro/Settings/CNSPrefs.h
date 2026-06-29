#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <os/log.h>
#import <roothide.h>

// ===== 共享常量 =====
#define CNS_CONFIG_PATH   @"/var/mobile/Library/Preferences/net.xyzl.customnotisound.plist"
#define CNS_SOUNDS_DIR    @"/var/mobile/Library/CustomNotiSound"
#define CNS_LOG_PATH      @"/var/mobile/customnotisound.log"
#define CNS_NOTIFY_NAME   "com.xyzl.customnotisound/preferences"

// 顶层键
#define CNS_KEY_ENABLED     @"enabled"
#define CNS_KEY_RULES       @"rules"
#define CNS_KEY_DEBUGLOG    @"debugLog"
#define CNS_KEY_RESPECTMUTE @"respectMute"
#define CNS_KEY_GRACE       @"startupGrace"  // 启动宽限期秒数(默认 10), 修复注销误播

// 规则键
#define CNS_RULE_ID        @"ruleID"      // 稳定唯一标识(UUID), 增删改/持久化按此定位
#define CNS_RULE_ENABLED   @"enabled"
#define CNS_RULE_BUNDLEID  @"bundleID"    // 支持逗号分隔多个
#define CNS_RULE_EXCLUDE   @"exclude"     // YES=排除(列表内 App 不命中), 默认 NO
#define CNS_RULE_TITLE     @"title"
#define CNS_RULE_SUBTITLE  @"subtitle"
#define CNS_RULE_MESSAGE   @"message"
#define CNS_RULE_EXACT     @"exactMatch"
#define CNS_RULE_SOUND     @"sound"

// ===== 日志(与 Tweak 写同一文件, 受 debugLog 门控) =====
static inline BOOL CNSPrefsDebugEnabled(void) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:jbroot(CNS_CONFIG_PATH)];
    return [cfg[CNS_KEY_DEBUGLOG] boolValue];
}
static inline void CNSPrefsFileLog(NSString *msg) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
    });
    NSString *line = [NSString stringWithFormat:@"%@ [Settings] %@\n",
                      [fmt stringFromDate:[NSDate date]], msg];
    NSString *path = jbroot(CNS_LOG_PATH);
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh == nil) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
        @catch (__unused NSException *e) {}
        [fh closeFile];
    }
}
static inline void CNSPrefsLogImpl(NSString *msg) {
    if (!CNSPrefsDebugEnabled()) return;
    CNSPrefsFileLog(msg);
}
#define CNSPLog(fmt, ...) CNSPrefsLogImpl([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

// ===== 音频路径归一化(解耦 roothide 随机化 .jbroot-XXXX) =====
// 问题: 每次重新越狱, jbroot 入口名 .jbroot-XXXX 随机变化; 存完整绝对路径会在下次越狱后失效。
// 方案: 存储时归一化为 jbroot 相对路径(/var/mobile/...), 运行时用 jbroot() 拼当前前缀还原。
//
// 归一化: 把任意形态路径转为 jbroot 相对路径, 与随机串解耦。
//   - 含 .jbroot-XXXX 段(旧/当前完整路径): 用字符串剥掉随机前缀, 还原相对路径。
//     (不用 rootfs(), 它只认"当前"前缀, 对跨越狱遗留的旧 .jbroot- 路径无效)
//   - 不含(已是相对路径, 或 /System 等系统音效路径): 原样返回。
static inline NSString *CNSNormalizeSoundPath(NSString *path) {
    if (path.length == 0) return path;
    NSRange mark = [path rangeOfString:@"/.jbroot-"];
    if (mark.location != NSNotFound) {
        NSUInteger from = mark.location + mark.length;            // 随机串起点
        NSRange slash = [path rangeOfString:@"/"
            options:0 range:NSMakeRange(from, path.length - from)];
        if (slash.location != NSNotFound)
            return [path substringFromIndex:slash.location];      // 从随机串后的 "/" 起 = 相对路径
    }
    return path;
}
// 解析: 归一化后还原为当前可用的完整路径; 找不到文件返回 nil。
//   - 真实存在的绝对路径(系统音效等): 直接用。
//   - jbroot 相对路径: jbroot() 拼当前 .jbroot-XXXX 前缀。
static inline NSString *CNSResolveSoundPath(NSString *path) {
    NSString *norm = CNSNormalizeSoundPath(path);
    if (norm.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:norm]) return norm;
    if ([norm hasPrefix:@"/"]) {
        NSString *jb = jbroot(norm);
        if ([fm fileExistsAtPath:jb]) return jb;
    }
    return nil;
}

// ===== 配置读写工具 =====
@interface CNSConfig : NSObject
+ (NSString *)configFullPath;
+ (NSMutableDictionary *)load;
+ (void)save:(NSDictionary *)config;
+ (NSMutableArray *)loadRules;                 // 读取 rules 数组(可变), 顺带补齐缺失 ruleID
+ (void)saveRules:(NSArray *)rules;
+ (void)ensureSoundsDir;

// ruleID 主键操作(替代下标当主键, 避免删除/排序后错位)
+ (NSString *)newRuleID;                                  // 生成新 UUID
+ (NSMutableDictionary *)ruleWithID:(NSString *)ruleID;   // 按 ID 取规则(可变副本)
+ (void)upsertRule:(NSDictionary *)rule;                  // 按 ruleID 更新; 无则追加
+ (void)deleteRuleID:(NSString *)ruleID;                  // 按 ID 删除
@end
