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
@property (nonatomic, assign) NSInteger visibleMenuItems;
@property (nonatomic, assign) NSInteger minimumMenuItems;
@property (nonatomic, assign) BOOL useTallLayout;
@property (nonatomic, assign) BOOL useTrailingCheckmarkLayout;
@property (nonatomic, assign) BOOL hideGlyphInHeader;
- (void)setGlyphImage:(UIImage *)image;
- (void)setSelectedGlyphColor:(UIColor *)color;
- (void)setSelected:(BOOL)selected;
- (void)setMenuItems:(NSArray<CCUIMenuModuleItem *> *)menuItems;
- (void)setVisibleMenuItems:(NSInteger)visibleMenuItems;
- (void)setMinimumMenuItems:(NSInteger)minimumMenuItems;
- (void)setUseTallLayout:(BOOL)useTallLayout;
- (void)setUseTrailingCheckmarkLayout:(BOOL)useTrailingCheckmarkLayout;
- (void)setHideGlyphInHeader:(BOOL)hideGlyphInHeader;
- (void)setShouldProvideOwnPlatter:(BOOL)shouldProvideOwnPlatter;
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

//==============================================================================
#pragma mark - CCUIToggleModule
// 开关式 CC 模块基类（iOS 16/17）：点击切换选中态并刷新外观
//==============================================================================

@interface CCUIToggleModule : NSObject <CCUIContentModule>
@property (nonatomic, strong, readonly) UIImage *iconGlyph;
@property (nonatomic, strong, readonly) UIImage *selectedIconGlyph;
@property (nonatomic, strong, readonly) UIColor *selectedColor;
@property (nonatomic, assign, getter=isSelected) BOOL selected;
- (void)refreshState;
@end

NS_ASSUME_NONNULL_END
