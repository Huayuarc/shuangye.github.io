#import <UIKit/UIKit.h>
#import <ControlCenterUIKit/CCUIToggleModule.h>
#import "../EvanescoPrefs.h"
@interface EvanescoCC : CCUIToggleModule @end
@implementation EvanescoCC
- (UIImage *)iconGlyph { if (@available(iOS 13.0,*)) return [UIImage systemImageNamed:@"eye.slash.fill"]; return nil; }
- (UIColor *)selectedColor { return [UIColor colorWithRed:.35 green:.65 blue:.95 alpha:1]; }
- (BOOL)isSelected { return [EVValue(@"enabled",@YES) boolValue]; }
- (void)setSelected:(BOOL)v { EVSetValue(@"enabled",@(v)); [super refreshState]; }
- (void)controlCenterWillPresent { [super refreshState]; }
@end
