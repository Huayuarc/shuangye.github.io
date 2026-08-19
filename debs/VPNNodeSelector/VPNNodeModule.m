#import "VPNNodeModule.h"

@implementation VPNNodeModule {
    VPNNodeViewController *_controller;
    BOOL _selected;
}
- (VPNNodeViewController *)contentViewController {
    if (!_controller) {
        _controller = [VPNNodeViewController new];
        _controller.module = self;
    }
    return _controller;
}
- (UIViewController *)backgroundViewController { return nil; }
- (BOOL)isSelected { return _selected; }
- (void)setSelected:(BOOL)value {
    if (_selected == value) return;
    _selected = value;
    [super refreshState];
}
- (UIImage *)moduleGlyph {
    UIImage *image = nil;
    if (@available(iOS 15.0, *)) image = [UIImage systemImageNamed:@"shield.lefthalf.filled"];
    if (!image) {
        NSString *path = [[NSBundle bundleForClass:self.class] pathForResource:@"VPNGlyph" ofType:@"png"];
        image = [UIImage imageWithContentsOfFile:path];
    }
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}
- (UIImage *)iconGlyph { return [self moduleGlyph]; }
- (UIImage *)selectedIconGlyph { return [self moduleGlyph]; }
- (UIColor *)selectedColor { return UIColor.systemBlueColor; }
@end
