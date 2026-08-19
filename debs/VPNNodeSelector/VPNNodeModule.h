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

@interface CCUIButtonModuleViewController : UIViewController
@property(nonatomic, assign, getter=isSelected) BOOL selected;
@property(nonatomic, strong, readonly) UIControl *buttonView;
@property(nonatomic, strong) UIColor *glyphColor;
@property(nonatomic, strong) UIColor *selectedGlyphColor;
@end

@class CCUIToggleModule;
@interface CCUIToggleViewController : CCUIButtonModuleViewController <CCUIContentModuleContentViewController>
@property(nonatomic, weak) CCUIToggleModule *module;
- (void)buttonTapped:(id)sender forEvent:(id)event;
- (void)refreshState;
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

@interface VPNNodeViewController : CCUIToggleViewController
@end
