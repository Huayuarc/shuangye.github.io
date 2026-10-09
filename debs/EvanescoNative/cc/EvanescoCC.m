#import <UIKit/UIKit.h>
#import <ControlCenterUIKit/CCUIToggleModule.h>
#import "../EvanescoPrefs.h"
@interface evanescocc:CCUIToggleModule@end
@implementation evanescocc
-(UIImage*)iconGlyph{return [UIImage imageNamed:@"icon" inBundle:[NSBundle bundleForClass:self.class] compatibleWithTraitCollection:nil];}
-(UIColor*)selectedColor{return [UIColor colorWithRed:0.3 green:0.65 blue:0.95 alpha:1];}
-(BOOL)isSelected{return [EVRead(@"enabled",@YES)boolValue];}
-(void)setSelected:(BOOL)v{EVWrite(@"enabled",@(v));[super refreshState];}
-(void)controlCenterWillPresent{[super refreshState];}
@end
