#import <Preferences/PSListController.h>

@interface LLRootListController : PSListController
- (NSString *)specifiersPlistName;
@end

@interface LLNotificationListController : LLRootListController
@end

@interface LLDisableListController : LLRootListController
@end

@interface LLSystemListController : LLRootListController
@end

@interface LLUnseenListController : LLRootListController
@end

@interface LLHideListController : LLRootListController
@end

@interface LLDateTimeListController : LLRootListController
@end

@interface LLGeneralListController : LLRootListController
@end

@interface LLStatusBarListController : LLRootListController
@end

@interface LLGestureListController : LLRootListController
@end

@interface LLCyanideListController : LLRootListController
@end
