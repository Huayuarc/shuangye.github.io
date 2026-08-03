// cpuctl — CPUthermal 命令行工具
// 移植自 insulationctl (be-huge/insulation 逆向还原)，适配 CPUthermal 的偏好设置与通知机制
// Usage: cpuctl [off|low|max|status] [--raw] [--quiet]

#import <Foundation/Foundation.h>
#import <notify.h>
#import <CPUthermalPaths.h>

static const char *canonicalModeForAction(NSString *action) {
    if ([action isEqualToString:S("off")]) return kCPUthermalOffModeC;
    if ([action isEqualToString:S("low")] || [action isEqualToString:S("lowPower")]) return kCPUthermalLowPowerModeC;
    if ([action isEqualToString:S("max")] || [action isEqualToString:S("fullPower")]) return kCPUthermalFullPowerModeC;
    return NULL;
}

static void printUsage(void) {
    printf("Usage: cpuctl [off|low|max|status] [--raw] [--quiet]\n");
    printf("\n");
    printf("Modes:\n");
    printf("  off    Apple native thermal control (原生温控)\n");
    printf("  low    Simulated low-power frequency (低功耗)\n");
    printf("  max    Prevent thermal downclocking (解除温控)\n");
    printf("\n");
    printf("Aliases:\n");
    printf("  lowPower   same as low\n");
    printf("  fullPower  same as max\n");
    printf("\n");
    printf("Options:\n");
    printf("  --raw      print only off, lowPower, or fullPower\n");
    printf("  --quiet    suppress success output\n");
    printf("  -h, --help show this help\n");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL raw = NO;
        BOOL quiet = NO;
        BOOL isStatus = NO;
        const char *modeValue = NULL;
        BOOL valid = YES;

        for (int i = 1; i < argc; i++) {
            NSString *arg = S(argv[i]);
            if ([arg isEqualToString:S("--raw")]) {
                raw = YES;
            } else if ([arg isEqualToString:S("--quiet")]) {
                quiet = YES;
            } else if ([arg isEqualToString:S("-h")] || [arg isEqualToString:S("--help")]) {
                printUsage();
                return 0;
            } else if ([arg hasPrefix:S("--")]) {
                fprintf(stderr, "cpuctl: unknown option: %s\n", argv[i]);
                valid = NO;
            } else if ([arg isEqualToString:S("status")]) {
                isStatus = YES;
            } else {
                const char *m = canonicalModeForAction(arg);
                if (m) {
                    if (modeValue) {
                        fprintf(stderr, "cpuctl: multiple actions specified\n");
                        valid = NO;
                    } else {
                        modeValue = m;
                    }
                } else {
                    fprintf(stderr, "cpuctl: unknown action or mode: %s\n", argv[i]);
                    valid = NO;
                }
            }
        }

        if (!valid) {
            printUsage();
            return 1;
        }

        if (!modeValue && !isStatus) {
            printUsage();
            return 1;
        }

        // 确保 prefs 目录存在
        CPUthermalEnsurePrefDirectory();

        // status 模式
        if (isStatus) {
            NSDictionary *prefs = CPUthermalReadPrefs();
            NSString *current = prefs ? prefs[S("powerMode")] : nil;
            if (!current || ![current isKindOfClass:[NSString class]]) {
                current = S(kCPUthermalFullPowerModeC);
            }
            if (raw) {
                printf("%s\n", current.UTF8String);
            } else {
                printf("CPUthermal: %s\n", current.UTF8String);
            }
            return 0;
        }

        // 写入模式
        NSMutableDictionary *prefs = CPUthermalReadMutablePrefs();
        if (!prefs) prefs = [NSMutableDictionary dictionary];
        prefs[S("powerMode")] = S(modeValue);
        if (!CPUthermalWritePrefs(prefs)) {
            fprintf(stderr, "cpuctl: failed to write prefs\n");
            return 1;
        }

        // 发通知让 tweak 重载
        notify_post(kCPUthermalSettingsChangedNotifC);
        notify_post(kCPUthermalPowerModeChangedNotifC);

        // 重启 thermalmonitord 使新模式生效（launchd 自动拉起）
        CPUthermalRestartThermalmonitordNow();

        if (!quiet) {
            printf("cpuctl: %s\n", modeValue);
        }

        return 0;
    }
}
