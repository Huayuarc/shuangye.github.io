#ifndef VB_CC_COMPAT_H
#define VB_CC_COMPAT_H
#import <UIKit/UIKit.h>
// Minimal ABI declarations checked against Theos headers on 2026-10-22:
// https://github.com/theos/headers/blob/master/ControlCenterUIKit/CCUIContentModule-Protocol.h
// https://github.com/theos/headers/blob/master/ControlCenterUIKit/CCUIContentModuleContentViewController-Protocol.h
// Use NSObject + a real UIControl instead of depending on undocumented toggle
// buttonTapped: signatures. There is no CCUIToggleModule automatic write path.
@protocol CCUIContentModuleContentViewController <NSObject>
@property(nonatomic, readonly) CGFloat preferredExpandedContentHeight;
@property(nonatomic, readonly) CGFloat preferredExpandedContentWidth;
@property(nonatomic, readonly) BOOL providesOwnPlatter;
@optional
- (BOOL)shouldBeginTransitionToExpandedContentModule;
- (BOOL)shouldFinishTransitionToExpandedContentModule;
- (BOOL)canDismissPresentedContent;
- (void)willResignActive;
- (void)willBecomeActive;
- (void)willTransitionToExpandedContentMode:(BOOL)expanded;
- (void)didTransitionToExpandedContentMode:(BOOL)expanded;
- (void)dismissPresentedContentAnimated:(BOOL)animated completion:(id)completion;
- (void)controlCenterWillPresent;
- (void)controlCenterDidDismiss;
@end
@protocol CCUIContentModule <NSObject>
@property(nonatomic, readonly) UIViewController<CCUIContentModuleContentViewController> *contentViewController;
@property(nonatomic, readonly) UIViewController *backgroundViewController;
@optional
- (void)setContentModuleContext:(id)context;
@end
#endif
