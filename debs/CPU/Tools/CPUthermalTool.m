#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <CPUthermalPaths.h>

static int runExecutable(NSString *path, char *const argv[]) {
    if (path.length == 0 || !argv || !argv[0]) return 127;
    pid_t pid = 0;
    int status = 0;
    if (posix_spawn(&pid, [path fileSystemRepresentation], NULL, NULL, argv, NULL) != 0) return 126;
    if (waitpid(pid, &status, 0) < 0) return 125;
    return WIFEXITED(status) ? WEXITSTATUS(status) : status;
}

static int rebootUserspace(void) {
    NSString *launchctlPath = CPUthermalLaunchctlPath();
    char *args[] = {(char *)"launchctl", (char *)"reboot", (char *)"userspace", NULL};
    return runExecutable(launchctlPath, args);
}

static int restoreFullPower(void) {
    NSString *prefPath = CPUthermalCurrentPrefPath();
    if (prefPath.length == 0) return 1;
    NSString *directory = [prefPath stringByDeletingLastPathComponent];
    if (directory.length == 0) return 1;
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:prefPath];
    if (!prefs) prefs = [NSMutableDictionary dictionary];
    prefs[S("powerMode")] = S("fullPower");
    if (![prefs writeToFile:prefPath atomically:YES]) return 1;
    return notify_post(kCPUthermalPowerModeChangedNotifC) == NOTIFY_STATUS_OK ? 0 : 1;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && argv[1]) {
            NSString *command = [NSString stringWithUTF8String:argv[1]];
            if ([command isEqualToString:S("userspace-reboot")]) return rebootUserspace();
            if ([command isEqualToString:S("restore-fullpower")]) return restoreFullPower();
            return 64;
        }
        printf("CPUthermalTool commands:\n");
        printf("  userspace-reboot\n");
        printf("  restore-fullpower\n");
        return 0;
    }
}
