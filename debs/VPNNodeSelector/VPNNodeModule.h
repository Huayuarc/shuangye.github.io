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
@property(nonatomic, strong, readonly) VPNNodeViewController *contentViewController;
@property(nonatomic, strong, readonly) UIViewController *backgroundViewController;
@end

// UIViewController is stable across iOS 15-17. Do not hard-link CCUIToggleViewController.
@interface VPNNodeViewController : UIViewController <CCUIContentModuleContentViewController>
@property(nonatomic, weak) VPNNodeModule *module;
- (void)buttonTapped:(id)sender forEvent:(id)event;
@end
