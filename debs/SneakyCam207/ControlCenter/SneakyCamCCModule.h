#import <UIKit/UIKit.h>

// ControlCenterUIKit 私有类最小 ABI 声明；实际实现由系统私有框架提供。
@interface CCUIToggleModule : NSObject
- (UIImage *)iconGlyph;
- (UIImage *)selectedIconGlyph;
- (UIColor *)selectedColor;
- (BOOL)isSelected;
- (void)setSelected:(BOOL)selected;
- (void)refreshState;
@end

@interface SneakyCamCCPhoto : CCUIToggleModule
@end
@interface SneakyCamCCVideo : CCUIToggleModule
@end
@interface SneakyCamCCToggle : CCUIToggleModule
@end
