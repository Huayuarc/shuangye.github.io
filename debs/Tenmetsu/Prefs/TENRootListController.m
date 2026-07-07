#import "TENRootListController.h"
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <rootless.h>

@implementation TENRootListController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // 注册默认偏好值
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.platykor.tenprefs"];
    [prefs registerDefaults:@{
        @"isenabled": @YES,
        @"frequency": @5.0f
    }];

    self.navigationController.navigationBar.translucent = NO;
    self.navigationController.navigationBar.tintColor = [UIColor systemYellowColor];

    [self.table setSeparatorColor:[UIColor clearColor]];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    cell.layer.cornerRadius = 13;
    cell.layer.masksToBounds = YES;
}

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)resp {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring"
                                                                   message:@"Apply changes with a respring"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"Respring"
                                                       style:UIAlertActionStyleDestructive
                                                     handler:^(UIAlertAction *action) {
        pid_t pid;
        char *argv[] = {NULL};
        posix_spawn(&pid, ROOT_PATH("/usr/bin/sbreload"), NULL, NULL, argv, NULL);
        waitpid(pid, NULL, 0);
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    [alert addAction:okAction];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
