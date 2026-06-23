#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <ControlCenterUIKit/ControlCenterUIKit.h>

#ifndef CCUILayoutSize
typedef struct CCUILayoutSize {
    NSUInteger width;
    NSUInteger height;
} CCUILayoutSize;
#endif

@protocol CCSModuleProvider <NSObject>
- (NSUInteger)numberOfProvidedModules;
- (NSString *)identifierForModuleAtIndex:(NSUInteger)index;
- (id)moduleInstanceForModuleIdentifier:(NSString *)identifier;
- (NSString *)displayNameForModuleIdentifier:(NSString *)identifier;
@optional
- (BOOL)providesListControllerForModuleIdentifier:(NSString *)identifier;
- (id)listControllerForModuleIdentifier:(NSString *)identifier;
- (NSSet *)supportedDeviceFamiliesForModuleWithIdentifier:(NSString *)identifier;
- (NSUInteger)visibilityPreferenceForModuleWithIdentifier:(NSString *)identifier;
- (UIImage *)settingsIconForModuleIdentifier:(NSString *)identifier;
@end

@interface AkaraCCModuleViewController : UIViewController <CCUIContentModuleContentViewController>
@property (nonatomic, copy) NSString *moduleIdentifier;
@property (nonatomic, strong) id module;
@property (nonatomic, strong) UIViewController *hostedContentViewController;
@property (nonatomic, strong) UIViewController *hostedBackgroundViewController;
@property (nonatomic, assign) BOOL expanded;
- (instancetype)initWithModuleName:(NSString *)moduleName;
- (void)setContentModuleContext:(id)context;
@end
