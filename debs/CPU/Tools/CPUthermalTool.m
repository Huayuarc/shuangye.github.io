#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
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

static int setThermalPressure(NSString *value) {
    if (value.length == 0) {
        return 64;
    }

    NSInteger pressure = [value integerValue];
    if (pressure < kCPUthermalThermalPressureLevelNominal || pressure >= kCPUthermalThermalPressureLevelUnknown) {
        return 65;
    }

    return CPUthermalSetThermalPressureLevel((CPUthermalThermalPressureLevel)pressure);
}

static int resetThermalNotification(void) {
    return CPUthermalSetThermalNotificationRawLevel(0);
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
            if ([command isEqualToString:S("set-thermal-pressure")]) {
                NSString *value = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : nil;
                return setThermalPressure(value);
            }
            if ([command isEqualToString:S("reset-thermal-notification")]) {
                return resetThermalNotification();
            }
        }

        printf("CPUthermalTool commands:\n");
        printf("  restart-thermalmonitord\n");
        printf("  restart-thermalmonitord-delayed\n");
        printf("  sbreload\n");
        printf("  userspace-reboot\n");
        printf("  set-thermal-pressure <0-5>\n");
        printf("  reset-thermal-notification\n");
    }
    return 0;
}
