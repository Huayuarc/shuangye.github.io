#import "SneakyCamCCModule.h"
#import "../SCPaths.h"
#import <notify.h>
@implementation SneakyCamCCPhoto
- (UIImage *)iconGlyph{UIImageSymbolConfiguration *c=[UIImageSymbolConfiguration configurationWithPointSize:29 weight:UIImageSymbolWeightMedium];return [UIImage systemImageNamed:@"camera" withConfiguration:c];}
- (UIImage *)selectedIconGlyph{UIImageSymbolConfiguration *c=[UIImageSymbolConfiguration configurationWithPointSize:29 weight:UIImageSymbolWeightMedium];return [UIImage systemImageNamed:@"camera.fill" withConfiguration:c];}
- (UIColor *)selectedColor{return [UIColor systemBlueColor];}
- (BOOL)isSelected{id e=SCReadPreferences()[@"Enabled"];id p=SCReadPreferences()[@"PhotoEnabled"];return(e?[e boolValue]:NO)&&(p?[p boolValue]:YES);}
- (void)setSelected:(BOOL)selected{if([self isSelected])notify_post("com.spark.SneakyCam.takephoto");[self refreshState];}
@end
