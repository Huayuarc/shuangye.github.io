#import <UIKit/UIKit.h>
@protocol CCUIContentModuleContentViewController <NSObject>
@optional
- (CGFloat)preferredExpandedContentHeight; - (CGFloat)preferredExpandedContentWidth;
- (CGFloat)preferredExpandedContinuousCornerRadius; - (BOOL)providesOwnPlatter;
- (BOOL)shouldBeginTransitionToExpandedContentModule; - (void)willTransitionToExpandedContentMode:(BOOL)animated;
@end
@protocol CCUIContentModule <NSObject>
@property(nonatomic,strong,readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@optional @property(nonatomic,strong,readonly) UIViewController *backgroundViewController;
@end
typedef struct { NSUInteger width; NSUInteger height; } CCUILayoutSize;
@interface PMOriginalModule:NSObject<CCUIContentModule>
- (instancetype)initWithIdentifier:(NSString *)identifier;
@end
@interface PSSpecifier:NSObject
- (id)propertyForKey:(NSString *)key;
@end
@interface PSListController:UIViewController { NSMutableArray *_specifiers; }
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end
@interface PMOriginalListController:PSListController
- (instancetype)initWithIdentifier:(NSString *)identifier;
@end
