#import "CCVPNModule.h"

@implementation CCVPNModule {
    CCVPNModuleViewController *_contentViewController;
}

- (CCVPNModuleViewController *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [CCVPNModuleViewController new];
        _contentViewController.module = self;
    }
    return _contentViewController;
}
- (UIViewController *)backgroundViewController { return nil; }
- (BOOL)isSelected { return _selected; }
- (void)setSelected:(BOOL)selected {
    if (_selected == selected) return;
    _selected = selected;
    [super refreshState];
}
- (UIImage *)templateIcon {
    NSBundle *bundle = [NSBundle bundleForClass:self.class];
    NSString *path = [bundle pathForResource:@"Icon@3x" ofType:@"png"];
    return [[UIImage imageWithContentsOfFile:path] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
// 与 com.sini.ccvpn 模板一致：CCUIToggleModule 提供 glyph、selectedColor 与 selected 状态。
- (UIColor *)selectedColor { return UIColor.systemBlueColor; }
- (UIImage *)iconGlyph { return [self templateIcon]; }
- (UIImage *)selectedIconGlyph { return [self templateIcon]; }
@end
