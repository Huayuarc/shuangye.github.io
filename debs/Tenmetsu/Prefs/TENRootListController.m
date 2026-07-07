#import "TENRootListController.h"
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <rootless.h>

@implementation TENRootListController

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Register default preference values
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:@"com.platykor.tenprefs"];
    [prefs registerDefaults:@{
        @"isenabled": @YES,
        @"seconds": @10,
        @"tim": @0
    }];

    // Custom navigation bar styling
    self.navigationController.navigationBar.translucent = NO;
    self.navigationController.navigationBar.tintColor = [UIColor systemGrayColor];

    // Remove separator inset
    [self.table setSeparatorColor:[UIColor clearColor]];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.row) {
        case 0: // Switch cell
        case 2: // Stroboscopic group
        case 3: // Timer group
        case 8: // Fast-Ls
        case 9: // About
        case 10: // Respring
            cell.layer.cornerRadius = 13;
            cell.layer.masksToBounds = YES;
            break;
        case 7: // Escape button — blue background
            cell.backgroundColor = [UIColor colorWithRed:0.0 green:122.0/255.0 blue:1.0 alpha:1.0];
            cell.layer.cornerRadius = 13;
            cell.layer.masksToBounds = YES;
            break;
    }
}

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)twitter {
    NSURL *url = [NSURL URLWithString:@"https://mobile.twitter.com/platykor"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)yobun {
    NSURL *url = [NSURL URLWithString:@"https://repo.packix.com/package/com.platykor.yobunpro/"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)onlyyou {
    NSURL *url = [NSURL URLWithString:@"https://repo.packix.com/package/com.platykor.onlyyou/"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)escape {
    NSURL *url = [NSURL URLWithString:@"https://repo.packix.com/package/com.platykor.escape/"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)fast {
    NSURL *url = [NSURL URLWithString:@"https://repo.packix.com/package/com.platykor.fastls/"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)about {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thank You"
                                                                   message:@"(It's really fast!)"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"Not now"
                                                       style:UIAlertActionStyleDefault
                                                     handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resp {
    // Respring confirmation
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring"
                                                                   message:@"Let's go to apply the change with a respring"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"Respring"
                                                       style:UIAlertActionStyleDestructive
                                                     handler:^(UIAlertAction *action) {
        // Perform respring using sbreload
        pid_t pid;
        char *argv[] = {NULL};
        posix_spawn(&pid, ROOT_PATH("/usr/bin/sbreload"), NULL, NULL, argv, NULL);
        waitpid(pid, NULL, 0);
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Not now"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    [alert addAction:okAction];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resprin {
    // Quick respring without confirmation
    pid_t pid;
    char *argv[] = {NULL};
    posix_spawn(&pid, ROOT_PATH("/usr/bin/sbreload"), NULL, NULL, argv, NULL);
    waitpid(pid, NULL, 0);
}

@end
