#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

//==============================================================================
#pragma mark - CCUIContentModuleContentViewController
//==============================================================================

@protocol CCUIContentModuleContentViewController <NSObject>
@required
- (CGFloat)preferredExpandedContentHeight;
@optional
- (CGFloat)preferredExpandedContentWidth;
- (BOOL)providesOwnPlatter;
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (void)willTransitionToExpandedContentMode:(BOOL)animated;
- (void)willReturnToExpandedContentModule;
@end

//==============================================================================
#pragma mark - CCUIMenuModuleItem
//==============================================================================

@interface CCUIMenuModuleItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, assign, getter=isSelected) BOOL selected;
- (instancetype)initWithTitle:(NSString *)title identifier:(NSString *)identifier handler:(void (^)(void))handler;
- (void)setSubtitle:(NSString *)subtitle;
- (void)setSelectedGlyphColor:(UIColor *)color;
@end

//==============================================================================
#pragma mark - CCUIMenuModuleViewController
//==============================================================================

@interface CCUIMenuModuleViewController : UIViewController <CCUIContentModuleContentViewController>
@property (nonatomic, copy) NSArray<CCUIMenuModuleItem *> *menuItems;
- (void)setGlyphImage:(UIImage *)image;
- (void)setSelectedGlyphColor:(UIColor *)color;
- (void)setSelected:(BOOL)selected;
- (void)setMenuItems:(NSArray<CCUIMenuModuleItem *> *)menuItems;
- (void)buttonTapped:(id)arg forEvent:(id)event;
@end

//==============================================================================
#pragma mark - CCUIContentModule
//==============================================================================

@protocol CCUIContentModule <NSObject>
@required
@property (nonatomic, strong, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@optional
@property (nonatomic, strong, readonly) UIViewController *backgroundViewController;
@end

NS_ASSUME_NONNULL_END
