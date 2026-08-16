#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>

@implementation SneakyCamCCToggle
- (UIImage *)iconGlyph { return [UIImage systemImageNamed:@"camera"]; }
- (UIImage *)selectedIconGlyph { return [UIImage systemImageNamed:@"camera.fill"]; }
- (UIColor *)selectedColor { return [UIColor systemGrayColor]; }
- (BOOL)isSelected { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
- (void)setSelected:(BOOL)selected {
    SCWritePreference(@"Enabled", @(selected));
    notify_post("com.spark.SneakyCam.enabledchanged");
    notify_post("com.spark.SneakyCam");
    [self refreshState];
}
@end
