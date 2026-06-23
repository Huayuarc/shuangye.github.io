// JadeRootListController.m
// Main preference bundle controller for Jade Control Center tweak

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

@interface JadeRootListController : PSListController
- (void)respring;
- (void)killAll;
- (void)openTwitter;
- (void)openGithub;
@end

@implementation JadeRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Respring"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(respring)];
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring"
                                                                   message:@"Are you sure you want to respring?"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        pid_t pid = 0;
        const char *killallPath = "/var/jb/usr/bin/killall";
        char *killallArgs[] = {"killall", "SpringBoard", NULL};
        int status = posix_spawn(&pid, killallPath, NULL, NULL, killallArgs, environ);
        if (status != 0) {
            const char *sbreloadPath = "/var/jb/usr/bin/sbreload";
            char *sbreloadArgs[] = {"sbreload", NULL};
            status = posix_spawn(&pid, sbreloadPath, NULL, NULL, sbreloadArgs, environ);
        }
        if (status != 0) {
            NSLog(@"[JadePrefs] Failed to respring: %d", status);
        }
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)killAll {
    // Reload SpringBoard
    [self respring];
}

- (void)openTwitter {
    NSURL *url = [NSURL URLWithString:@"https://twitter.com/nightwind_dev"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void)openGithub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/nightwind-dev"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

@end
