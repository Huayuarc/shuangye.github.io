//
//  KayokoSystemTranslationPresenter.h
//  Kayoko
//

#import <Foundation/Foundation.h>

@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

@interface KayokoSystemTranslationPresenter : NSObject

@property(nonatomic, assign, readonly, getter=isAvailable) BOOL available;

- (BOOL)presentTranslationForText:(NSString *)text fromController:(UIViewController *)controller;
- (void)dismissTranslationAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
