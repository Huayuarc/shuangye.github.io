#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>

@implementation SneakyCamCCPhoto
- (UIImage *)iconGlyph { return [UIImage systemImageNamed:@"camera"]; }
- (UIImage *)selectedIconGlyph { return [UIImage systemImageNamed:@"camera.fill"]; }
- (UIColor *)selectedColor { return [UIColor systemBlueColor]; }
- (BOOL)isSelected { return NO; }
- (void)setSelected:(BOOL)selected {
    id enabled=SCReadPreferences()[@"Enabled"];
    id photo=SCReadPreferences()[@"PhotoEnabled"];
    if((enabled?[enabled boolValue]:NO) && (photo?[photo boolValue]:YES))
        notify_post("com.spark.SneakyCam.takephoto");
    [super setSelected:NO];
}
@end
