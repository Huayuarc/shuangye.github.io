#import "VPNControlCenterModule.h"

@implementation VPNControlCenterModule {
    VPNControlCenterModuleViewController *_contentViewController;
}

- (VPNControlCenterModuleViewController *)contentViewController {
    if (!_contentViewController) {
        _contentViewController = [VPNControlCenterModuleViewController new];
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
- (UIColor *)selectedColor { return UIColor.whiteColor; }
- (UIImage *)iconGlyph { return nil; }
- (UIImage *)selectedIconGlyph { return nil; }
@end
