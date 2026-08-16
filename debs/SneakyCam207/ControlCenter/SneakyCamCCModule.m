#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import "../SCCaptureManager.h"
#import <notify.h>

// 拍照模块：点击触发 takephoto，图标相机填充，选中色为系统蓝
@implementation SneakyCamCCPhoto
- (UIImage *)iconGlyph { return [UIImage systemImageNamed:@"camera"]; }
- (UIImage *)selectedIconGlyph { return [UIImage systemImageNamed:@"camera.fill"]; }
- (UIColor *)selectedColor { return [UIColor systemBlueColor]; }
- (BOOL)isActiveAllowed { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
- (void)setSelected:(BOOL)sel {
    if(sel && [self isActiveAllowed]) notify_post("com.spark.SneakyCam.takephoto");
}
@end

// 录像模块：点击切换录制，高亮表示正在录制
@implementation SneakyCamCCVideo
- (UIImage *)iconGlyph { return [UIImage systemImageNamed:@"video"]; }
- (UIImage *)selectedIconGlyph { return [UIImage systemImageNamed:@"video.fill"]; }
- (UIColor *)selectedColor { return [UIColor systemRedColor]; }
- (BOOL)isActiveAllowed { id v=SCReadPreferences()[@"Enabled"]; return v?[v boolValue]:NO; }
- (BOOL)isSelected { return [[SCCaptureManager shared] isRecording]; }
- (void)setSelected:(BOOL)sel {
    if(sel && [self isActiveAllowed]) notify_post("com.spark.SneakyCam.startstopvideo");
}
- (void)refreshState {
    [super refreshState];
}
@end
