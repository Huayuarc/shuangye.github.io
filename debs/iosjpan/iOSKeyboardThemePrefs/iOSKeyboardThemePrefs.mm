#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <notify.h>
#import <spawn.h>

@interface iOSThemeKeyboardPrefsListController : PSListController
- (void)respring;
@end

@implementation iOSThemeKeyboardPrefsListController

- (id)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"iOSKeyboardTheme" target:self];
	}
	return _specifiers;
}

- (void)respring {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"注销"
																   message:@"确定要注销 SpringBoard 吗？"
															preferredStyle:UIAlertControllerStyleAlert];

	UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
	UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		notify_post("com.marsnakly.ios8darkkeyboard.prefschanged");
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
			pid_t pid;
			const char *args[] = {"sbreload", NULL};
			posix_spawn(&pid, "/var/jb/usr/bin/sbreload", NULL, NULL, (char *const *)args, NULL);
		});
	}];

	[alert addAction:cancel];
	[alert addAction:confirm];
	[self presentViewController:alert animated:YES completion:nil];
}

@end
