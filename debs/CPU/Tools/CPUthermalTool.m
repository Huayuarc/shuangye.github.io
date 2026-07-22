#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <CPUthermalPaths.h>
#import <CPUthermalMonitor.h>

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

static int applyThermalOverrides(void) {
    // 热状态覆盖功能已移除（原为阳光暴晒锁定）
    return 0;
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
            if ([command isEqualToString:S("apply-thermal-overrides")]) {
                return applyThermalOverrides();
            }
            if ([command isEqualToString:S("reset-thermal-notifications")]) {
                int ret = CPUthermalResetNotifLevel();
                printf("reset-thermal-notifications: %d\n", ret);
                return ret;
            }
            if ([command isEqualToString:S("read-thermal-state")]) {
                CPUthermalPressureLevel pressure = CPUthermalPressure();
                CPUthermalNotifLevel notif = CPUthermalCurrentNotifLevel();
                float maxTemp = CPUthermalMaxTriggerTemperature();

                printf("Thermal State:\n");
                printf("  Pressure: %s (%d)\n", CPUthermalPressureString(pressure), (int)pressure);
                printf("  Notification: %s\n", CPUthermalNotifLevelString(notif, true));
                printf("  Max Trigger Temp: %.1f°C\n", maxTemp);
                return 0;
            }
            if ([command isEqualToString:S("set-thermal-pressure")] && argc > 2) {
                int value = atoi(argv[2]);
                CPUthermalPressureLevel pressure = (CPUthermalPressureLevel)value;
                int ret = CPUthermalSetPressure(pressure);
                printf("set-thermal-pressure %d: %d\n", value, ret);
                return ret;
            }
        }

        printf("CPUthermalTool commands:\n");
        printf("  restart-thermalmonitord\n");
        printf("  restart-thermalmonitord-delayed\n");
        printf("  sbreload\n");
        printf("  userspace-reboot\n");
        printf("  apply-thermal-overrides\n");
        printf("  read-thermal-state\n");
        printf("  reset-thermal-notifications\n");
        printf("  set-thermal-pressure <value>\n");
    }
    return 0;
}
