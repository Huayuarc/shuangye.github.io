#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@protocol CCUIContentModule <NSObject>
@property(nonatomic, readonly) UIViewController *contentViewController;
@property(nonatomic, readonly) UIViewController *backgroundViewController;
@end

@protocol CCUIContentModuleContentViewController <NSObject>
@optional
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (void)willTransitionToExpandedContentMode:(BOOL)animated;
- (void)willReturnToExpandedContentModule;
- (CGFloat)preferredExpandedContentHeight;
- (CGFloat)preferredExpandedContentWidth;
- (BOOL)providesOwnPlatter;
@end

@interface CCUIButtonModuleViewController : UIViewController
@end

@class CCUIToggleModule;
@interface CCUIToggleViewController : CCUIButtonModuleViewController <CCUIContentModuleContentViewController>
@property(nonatomic,weak) CCUIToggleModule *module;
- (void)refreshState;
- (void)reconfigureView;
@end

@interface CCUIToggleModule : NSObject <CCUIContentModule>
- (BOOL)isSelected;
- (void)setSelected:(BOOL)selected;
- (UIColor *)selectedColor;
- (UIImage *)iconGlyph;
- (UIImage *)selectedIconGlyph;
- (void)refreshState;
@end

@class VPNControlCenterModuleViewController;
@interface VPNControlCenterModule : CCUIToggleModule
@property(nonatomic,assign,getter=isSelected) BOOL selected;
@property(nonatomic,strong,readonly) VPNControlCenterModuleViewController *contentViewController;
@property(nonatomic,strong,readonly) UIViewController *backgroundViewController;
@end

@interface VPNControlCenterModuleViewController : CCUIToggleViewController
@end
