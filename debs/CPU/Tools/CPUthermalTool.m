#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <CPUthermalPaths.h>

static int runExecutable(NSString *path, char *const argv[]) {
    if (path.length == 0) {
        return 127;
    }

    pid_t pid = 0;
    int status = 0;
    if (posix_spawn(&pid, [path fileSystemRepresentation], NULL, NULL, argv, NULL) != 0) {
        return 126;
    }
    if (waitpid(pid, &status, 0) < 0) {
        return 125;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return status;
}

static int restartThermalmonitord(void) {
    NSString *killallPath = CPUthermalKillallPath();
    char *args[] = {"killall", "-q", "thermalmonitord", NULL};
    return runExecutable(killallPath, args);
}

static int restartThermalmonitordDelayed(void) {
    [NSThread sleepForTimeInterval:2.0];
    return restartThermalmonitord();
}

static int reloadSpringBoard(void) {
    NSString *sbreloadPath = CPUthermalSBReloadPath();
    char *args[] = {"sbreload", NULL};
    return runExecutable(sbreloadPath, args);
}

static int rebootUserspace(void) {
    NSString *launchctlPath = CPUthermalLaunchctlPath();
    char *args[] = {"launchctl", "reboot", "userspace", NULL};
    return runExecutable(launchctlPath, args);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1) {
            NSString *command = [NSString stringWithUTF8String:argv[1]];
            if ([command isEqualToString:S("restart-thermalmonitord")]) {
                return restartThermalmonitord();
            }
            if ([command isEqualToString:S("restart-thermalmonitord-delayed")]) {
                return restartThermalmonitordDelayed();
            }
            if ([command isEqualToString:S("sbreload")]) {
                return reloadSpringBoard();
            }
            if ([command isEqualToString:S("userspace-reboot")]) {
                return rebootUserspace();
            }
            if ([command isEqualToString:S("restore-fullpower")]) {
                // Step 1: 写入偏好，切换到全功率模式
                NSString *prefPath = CPUthermalCurrentPrefPath();
                if (prefPath.length > 0) {
                    NSString *dir = [prefPath stringByDeletingLastPathComponent];
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                              withIntermediateDirectories:YES
                                                               attributes:nil
                                                                    error:nil];
                    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:prefPath];
                    if (!prefs) prefs = [NSMutableDictionary dictionary];
                    prefs[S("powerMode")] = S("fullPower");
                    [prefs writeToFile:prefPath atomically:YES];
                    NSLog(@"[CPUthermalTool] 已写入偏好: powerMode=fullPower");
                }

                // Step 2: 发送 Darwin 通知 — 正在运行的 thermalmonitord 插件会收到并恢复全功率
                notify_post(kCPUthermalPowerModeChangedNotifC);
                NSLog(@"[CPUthermalTool] 已发送通知: %s", kCPUthermalPowerModeChangedNotifC);

                // Step 3: 等待插件恢复硬件状态（keep-alive 每 1s 执行一次，等 3s 确保生效）
                [NSThread sleepForTimeInterval:3.0];
                NSLog(@"[CPUthermalTool] 等待完成，硬件应已恢复全功率状态");
                return 0;
            }
        }

        printf("CPUthermalTool commands:\n");
        printf("  restart-thermalmonitord\n");
        printf("  restart-thermalmonitord-delayed\n");
        printf("  sbreload\n");
        printf("  userspace-reboot\n");
        printf("  restore-fullpower\n");
    }
    return 0;
}
