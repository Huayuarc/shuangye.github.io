#import <UIKit/UIKit.h>
@interface CCUIToggleModule : NSObject
- (UIImage *)iconGlyph;
- (UIImage *)selectedIconGlyph;
- (UIColor *)selectedColor;
- (BOOL)isSelected;
- (void)setSelected:(BOOL)selected;
- (void)refreshState;
@end
@interface SneakyCamCCToggle : CCUIToggleModule @end
@interface SneakyCamCCPhoto : CCUIToggleModule @end
@interface SneakyCamCCVideo : CCUIToggleModule @end
