#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@protocol CCUIContentModule <NSObject>
@property(nonatomic, readonly) UIViewController *contentViewController;
@property(nonatomic, readonly) UIViewController *backgroundViewController;
@end

@protocol CCUIContentModuleContentViewController <NSObject>
@optional
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (BOOL)shouldFinishTransitionToExpandedContentModule;
- (void)willTransitionToExpandedContentMode:(BOOL)animated;
- (void)willReturnToExpandedContentModule;
- (CGFloat)preferredExpandedContentHeight;
- (CGFloat)preferredExpandedContentWidth;
- (BOOL)providesOwnPlatter;
@end

@interface CCUIToggleModule : NSObject <CCUIContentModule>
- (BOOL)isSelected;
- (void)setSelected:(BOOL)selected;
- (UIColor *)selectedColor;
- (UIImage *)iconGlyph;
- (UIImage *)selectedIconGlyph;
- (void)refreshState;
@end

@class VPNNodeViewController;
@interface VPNNodeModule : CCUIToggleModule
@property(nonatomic, assign, getter=isSelected) BOOL selected;
@property(nonatomic, strong, readonly) UIViewController *contentViewController;
@property(nonatomic, strong, readonly) UIViewController *backgroundViewController;
- (void)vpnStatusDidChange;
- (void)refreshVisualState;
@end

@interface VPNNodeViewController : UIViewController <CCUIContentModuleContentViewController>
@property(nonatomic, weak) VPNNodeModule *module;
- (void)refreshForExternalVPNChange;
- (void)hostWillAppear;
- (void)hostDidDisappear;
- (void)hostDidLayoutWithBounds:(CGRect)bounds;
- (BOOL)isExpanded;
@end
