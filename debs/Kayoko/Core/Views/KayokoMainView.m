//
//  KayokoMainView.m
//  Kayoko
//
//  Created by Alexandra Aurora Göttlicher
//

#import "KayokoMainView.h"

#import <QuartzCore/QuartzCore.h>

#import "KayokoHeaderButtonStyle.h"
#import "KayokoHeaderView.h"
#import "KayokoPasteboardManager.h"

@interface KayokoMainView ()

@property(nonatomic, strong, readwrite) UIView *chromeClipView;
@property(nonatomic, strong) UIView *materialTintView;
@property(nonatomic, assign) CGFloat cachedPanelCornerRadius;
@property(nonatomic, assign) CGSize cachedChromeBoundsSize;
@property(nonatomic, assign) BOOL hasCachedChromeAppearance;

#pragma mark - Header Constraints

@property(nonatomic, strong) NSLayoutConstraint *headerTopConstraint;
@property(nonatomic, strong) NSLayoutConstraint *headerSafeAreaTopConstraint;
@property(nonatomic, strong) NSLayoutConstraint *headerLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *headerSafeAreaLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *headerTrailingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *headerSafeAreaTrailingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *headerHeightConstraint;

#pragma mark - Content Constraints

@property(nonatomic, strong) NSLayoutConstraint *contentTopConstraint;
@property(nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *contentLeadingConstraints;
@property(nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *contentSafeAreaLeadingConstraints;
@property(nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *contentTrailingConstraints;
@property(nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *contentSafeAreaTrailingConstraints;
@property(nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *contentBottomConstraints;
@property(nonatomic, strong) NSMutableArray<NSLayoutConstraint *> *contentSafeAreaBottomConstraints;

@end

@implementation KayokoMainView

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];

    if (self) {
        [self setHidden:YES];
        [self setContentLeadingConstraints:[[NSMutableArray alloc] init]];
        [self setContentSafeAreaLeadingConstraints:[[NSMutableArray alloc] init]];
        [self setContentTrailingConstraints:[[NSMutableArray alloc] init]];
        [self setContentSafeAreaTrailingConstraints:[[NSMutableArray alloc] init]];
        [self setContentBottomConstraints:[[NSMutableArray alloc] init]];
        [self setContentSafeAreaBottomConstraints:[[NSMutableArray alloc] init]];

        // Tight floating-card shadow: small edge gaps make large soft shadows look washed out.
        // Keep it compact and a bit denser so the card still reads against the background.
        [[self layer] setShadowColor:[[UIColor blackColor] CGColor]];
        [[self layer] setShadowOffset:CGSizeMake(0, 1)];
        [[self layer] setShadowRadius:8];
        [[self layer] setShadowOpacity:0.28];
        if (@available(iOS 13.0, *)) {
            [[self layer] setCornerCurve:kCACornerCurveContinuous];
        }
        [[self layer] setCornerRadius:kKayokoPanelCornerRadiusFallback];
        [self setClipsToBounds:NO];

        // Real frosted glass: blur must stay transparent so underlying UI shows through.
        [self setBackgroundColor:[UIColor clearColor]];
        [self setOpaque:NO];

        // Clip all panel content to continuous rounded corners while keeping outer shadow.
        [self setChromeClipView:[[UIView alloc] initWithFrame:self.bounds]];
        [[self chromeClipView] setBackgroundColor:[UIColor clearColor]];
        [[self chromeClipView] setOpaque:NO];
        [[self chromeClipView] setClipsToBounds:YES];
        if (@available(iOS 13.0, *)) {
            [[[self chromeClipView] layer] setCornerCurve:kCACornerCurveContinuous];
        }
        [[[self chromeClipView] layer] setCornerRadius:kKayokoPanelCornerRadiusFallback];
        [self addSubview:[self chromeClipView]];
        [[self chromeClipView] setTranslatesAutoresizingMaskIntoConstraints:NO];
        [NSLayoutConstraint activateConstraints:@[
            [[[self chromeClipView] topAnchor] constraintEqualToAnchor:[self topAnchor]],
            [[[self chromeClipView] leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
            [[[self chromeClipView] trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
            [[[self chromeClipView] bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]]
        ]];
        [self setBlurEffect:[UIBlurEffect effectWithStyle:[self preferredPanelBlurStyle]]];
        [self setBlurEffectView:[[UIVisualEffectView alloc] initWithEffect:[self blurEffect]]];
        [[self blurEffectView] setBackgroundColor:[UIColor clearColor]];
        [[self blurEffectView] setOpaque:NO];
        [[[self blurEffectView] contentView] setBackgroundColor:[UIColor clearColor]];
        [[[self blurEffectView] contentView] setOpaque:NO];
        [[[self blurEffectView] layer] setMasksToBounds:YES];
        if (@available(iOS 13.0, *)) {
            [[[self blurEffectView] layer] setCornerCurve:kCACornerCurveContinuous];
        }
        [[[self blurEffectView] layer] setCornerRadius:kKayokoPanelCornerRadiusFallback];
        [[self chromeClipView] addSubview:[self blurEffectView]];

        // Soft luminance lift so light-mode glass reads bright/transparent instead of muddy gray.
        [self setMaterialTintView:[[UIView alloc] initWithFrame:CGRectZero]];
        [[self materialTintView] setUserInteractionEnabled:NO];
        [[[self blurEffectView] contentView] addSubview:[self materialTintView]];
        [[self materialTintView] setTranslatesAutoresizingMaskIntoConstraints:NO];
        [NSLayoutConstraint activateConstraints:@[
            [[[self materialTintView] topAnchor] constraintEqualToAnchor:[[[self blurEffectView] contentView] topAnchor]],
            [[[self materialTintView] leadingAnchor]
                constraintEqualToAnchor:[[[self blurEffectView] contentView] leadingAnchor]],
            [[[self materialTintView] trailingAnchor]
                constraintEqualToAnchor:[[[self blurEffectView] contentView] trailingAnchor]],
            [[[self materialTintView] bottomAnchor]
                constraintEqualToAnchor:[[[self blurEffectView] contentView] bottomAnchor]]
        ]];
        [self applyMaterialAppearance];

        [[self blurEffectView] setTranslatesAutoresizingMaskIntoConstraints:NO];
        [NSLayoutConstraint activateConstraints:@[
            [[[self blurEffectView] topAnchor] constraintEqualToAnchor:[self topAnchor]],
            [[[self blurEffectView] leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
            [[[self blurEffectView] trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
            [[[self blurEffectView] bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]]
        ]];

        NSString *historyTitle = [[KayokoPasteboardManager localizationBundle] localizedStringForKey:@"History"
                                                                                               value:nil
                                                                                               table:@"Tweak"];
        [self setHeaderView:[[KayokoHeaderView alloc] initWithTitle:historyTitle]];
        [[self chromeClipView] addSubview:[self headerView]];

        [[self headerView] setTranslatesAutoresizingMaskIntoConstraints:NO];
        [self setHeaderTopConstraint:[[[self headerView] topAnchor] constraintEqualToAnchor:[self topAnchor]]];
        [self setHeaderSafeAreaTopConstraint:[[[self headerView] topAnchor]
                                                 constraintEqualToAnchor:[[self safeAreaLayoutGuide] topAnchor]]];
        [self setHeaderLeadingConstraint:[[[self headerView] leadingAnchor]
                                             constraintEqualToAnchor:[self leadingAnchor]]];
        [self
            setHeaderSafeAreaLeadingConstraint:[[[self headerView] leadingAnchor]
                                                   constraintEqualToAnchor:[[self safeAreaLayoutGuide] leadingAnchor]]];
        [self setHeaderTrailingConstraint:[[[self headerView] trailingAnchor]
                                              constraintEqualToAnchor:[self trailingAnchor]]];
        [self setHeaderSafeAreaTrailingConstraint:[[[self headerView] trailingAnchor]
                                                      constraintEqualToAnchor:[[self safeAreaLayoutGuide]
                                                                                  trailingAnchor]]];
        [self setHeaderHeightConstraint:[[[self headerView] heightAnchor]
                                            constraintEqualToConstant:[KayokoHeaderView preferredHeight]]];
        [NSLayoutConstraint activateConstraints:@[
            [self headerHeightConstraint], [self headerTopConstraint], [self headerLeadingConstraint],
            [self headerTrailingConstraint]
        ]];

        [[self headerView] updateStyleForButton:[[self headerView] leadingButton]
                                  withImageName:@"list.bullet"
                                      imageSize:kKayokoFavoritesButtonImageSize
                                      tintColor:[UIColor labelColor]];
        [[self headerView] updateStyleForButton:[[self headerView] trailingButton]
                                  withImageName:@"trash"
                                      imageSize:kKayokoClearButtonImageSize
                                      tintColor:[UIColor labelColor]];
        [[self headerView] updateStyleForButton:[[self headerView] alternateTrailingButton]
                                  withImageName:@"arrowshape.turn.up.backward"
                                      imageSize:kKayokoBackButtonImageSize
                                      tintColor:[UIColor labelColor]];

        [self setContentContainerView:[[UIView alloc] init]];
        [[self contentContainerView] setBackgroundColor:[UIColor clearColor]];
        [[self contentContainerView] setOpaque:NO];
        [[self contentContainerView] setClipsToBounds:YES];
        [[self chromeClipView] addSubview:[self contentContainerView]];

        [[self contentContainerView] setTranslatesAutoresizingMaskIntoConstraints:NO];
        NSLayoutConstraint *leadingConstraint =
            [[[self contentContainerView] leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]];
        NSLayoutConstraint *safeAreaLeadingConstraint = [[[self contentContainerView] leadingAnchor]
            constraintEqualToAnchor:[[self safeAreaLayoutGuide] leadingAnchor]];
        NSLayoutConstraint *trailingConstraint =
            [[[self contentContainerView] trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]];
        NSLayoutConstraint *safeAreaTrailingConstraint = [[[self contentContainerView] trailingAnchor]
            constraintEqualToAnchor:[[self safeAreaLayoutGuide] trailingAnchor]];
        NSLayoutConstraint *bottomConstraint =
            [[[self contentContainerView] bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]];
        NSLayoutConstraint *safeAreaBottomConstraint = [[[self contentContainerView] bottomAnchor]
            constraintEqualToAnchor:[[self safeAreaLayoutGuide] bottomAnchor]];
        [[self contentLeadingConstraints] addObject:leadingConstraint];
        [[self contentSafeAreaLeadingConstraints] addObject:safeAreaLeadingConstraint];
        [[self contentTrailingConstraints] addObject:trailingConstraint];
        [[self contentSafeAreaTrailingConstraints] addObject:safeAreaTrailingConstraint];
        [[self contentBottomConstraints] addObject:bottomConstraint];
        [[self contentSafeAreaBottomConstraints] addObject:safeAreaBottomConstraint];
        [self setContentTopConstraint:[[[self contentContainerView] topAnchor]
                                          constraintEqualToAnchor:[[self headerView] bottomAnchor]
                                                         constant:kKayokoHeaderContentSpacing]];
        [NSLayoutConstraint activateConstraints:@[
            [self contentTopConstraint], [self contentRespectsSafeArea] ? safeAreaLeadingConstraint : leadingConstraint,
            [self contentRespectsSafeArea] ? safeAreaTrailingConstraint : trailingConstraint, bottomConstraint
        ]];
    }

    return self;
}

#pragma mark - Layout

- (void)setSearchTitleRowCollapsed:(BOOL)searchTitleRowCollapsed {
    if (_searchTitleRowCollapsed == searchTitleRowCollapsed) {
        return;
    }

    _searchTitleRowCollapsed = searchTitleRowCollapsed;
    [[self headerHeightConstraint] setConstant:searchTitleRowCollapsed ? 0 : [KayokoHeaderView preferredHeight]];
    [[self contentTopConstraint] setConstant:searchTitleRowCollapsed ? 0 : kKayokoHeaderContentSpacing];
    [[self headerView] setUserInteractionEnabled:!searchTitleRowCollapsed];
    [self setNeedsLayout];
}

#pragma mark - Content Installation

- (void)constrainContentView:(UIView *)contentView {
    [contentView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [[contentView topAnchor] constraintEqualToAnchor:[[self contentContainerView] topAnchor]],
        [[contentView leadingAnchor] constraintEqualToAnchor:[[self contentContainerView] leadingAnchor]],
        [[contentView trailingAnchor] constraintEqualToAnchor:[[self contentContainerView] trailingAnchor]],
        [[contentView bottomAnchor] constraintEqualToAnchor:[[self contentContainerView] bottomAnchor]]
    ]];
}

- (void)installContentView:(UIView *)contentView hidden:(BOOL)hidden {
    [contentView setHidden:hidden];
    [[self contentContainerView] addSubview:contentView];
    [self constrainContentView:contentView];
}

- (void)installFullContentView:(UIView *)contentView headerView:(KayokoHeaderView *)headerView hidden:(BOOL)hidden {
    [contentView setHidden:hidden];
    [[self chromeClipView] addSubview:contentView];
    [contentView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [[contentView topAnchor] constraintEqualToAnchor:[self topAnchor]],
        [[contentView leadingAnchor] constraintEqualToAnchor:[self leadingAnchor]],
        [[contentView trailingAnchor] constraintEqualToAnchor:[self trailingAnchor]],
        [[contentView bottomAnchor] constraintEqualToAnchor:[self bottomAnchor]],
        [[headerView topAnchor] constraintEqualToAnchor:[[self headerView] topAnchor]],
        [[headerView leadingAnchor] constraintEqualToAnchor:[[self headerView] leadingAnchor]],
        [[headerView trailingAnchor] constraintEqualToAnchor:[[self headerView] trailingAnchor]]
    ]];
}

#pragma mark - Content Safe Area

- (UIEdgeInsets)effectiveContentSafeAreaInsets {
    UIEdgeInsets safeAreaInsets = [self safeAreaInsets];
    UIEdgeInsets additionalInsets = [self contentSafeAreaAdditionalInsets];
    safeAreaInsets.top += additionalInsets.top;
    safeAreaInsets.left += additionalInsets.left;
    safeAreaInsets.bottom += additionalInsets.bottom;
    safeAreaInsets.right += additionalInsets.right;
    return safeAreaInsets;
}

- (CGFloat)sceneSafeAreaBottomInsetForWindow:(UIWindow *)window {
    UIWindowScene *windowScene = [window windowScene];
    CGSize targetBoundsSize = [window bounds].size;
    CGFloat firstVisibleBottomInset = 0;
    CGFloat matchingVisibleBottomInset = 0;
    for (UIWindow *sceneWindow in [windowScene windows]) {
        if ([sceneWindow isHidden]) {
            continue;
        }

        CGFloat bottomInset = MAX([sceneWindow safeAreaInsets].bottom, 0);
        if (bottomInset > 0) {
            if (firstVisibleBottomInset <= 0) {
                firstVisibleBottomInset = bottomInset;
            }

            CGSize sceneWindowBoundsSize = [sceneWindow bounds].size;
            if (fabs(sceneWindowBoundsSize.width - targetBoundsSize.width) <= 0.5 &&
                fabs(sceneWindowBoundsSize.height - targetBoundsSize.height) <= 0.5) {
                matchingVisibleBottomInset = MAX(matchingVisibleBottomInset, bottomInset);
            }
        }
    }

    return matchingVisibleBottomInset > 0 ? matchingVisibleBottomInset : firstVisibleBottomInset;
}

- (CGFloat)safeAreaBottomInsetForContentView:(nullable UIView *)contentView {
    UIView *referenceView = contentView ?: self;
    if (contentView && [contentView isDescendantOfView:[self contentContainerView]]) {
        // Content transitions temporarily offset installed content views; the safe-area overlap belongs to the
        // stable content container.
        referenceView = [self contentContainerView];
    }

    UIWindow *window = [referenceView window] ?: [self window];
    CGFloat viewBottomSafeAreaInset = MAX([referenceView safeAreaInsets].bottom, 0);
    CGFloat windowBottomSafeAreaInset =
        MAX(MAX([window safeAreaInsets].bottom, [self sceneSafeAreaBottomInsetForWindow:window]), 0);
    if (!referenceView || !window) {
        return viewBottomSafeAreaInset;
    }
    if (windowBottomSafeAreaInset <= 0) {
        return viewBottomSafeAreaInset;
    }

    CGRect referenceBoundsInWindow = [referenceView convertRect:[referenceView bounds] toView:window];
    CGFloat safeAreaBottomY = CGRectGetMaxY([window bounds]) - windowBottomSafeAreaInset;
    CGFloat unsafeBottomOverlap = CGRectGetMaxY(referenceBoundsInWindow) - safeAreaBottomY;
    return ceil(MIN(MAX(unsafeBottomOverlap, 0), windowBottomSafeAreaInset));
}

- (UIEdgeInsets)contentSafeAreaAdditionalInsetsRemovingRedundantSystemInsets:(UIEdgeInsets)additionalInsets {
    UIEdgeInsets safeAreaInsets = [self safeAreaInsets];
    if (safeAreaInsets.top > 0) {
        additionalInsets.top = 0;
    }
    if (safeAreaInsets.left > 0) {
        additionalInsets.left = 0;
    }
    if (safeAreaInsets.bottom > 0) {
        additionalInsets.bottom = 0;
    }
    if (safeAreaInsets.right > 0) {
        additionalInsets.right = 0;
    }
    return additionalInsets;
}

- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    UIEdgeInsets normalizedInsets =
        [self contentSafeAreaAdditionalInsetsRemovingRedundantSystemInsets:[self contentSafeAreaAdditionalInsets]];
    if (!UIEdgeInsetsEqualToEdgeInsets(normalizedInsets, [self contentSafeAreaAdditionalInsets])) {
        [self setContentSafeAreaAdditionalInsets:normalizedInsets];
    }
}

- (void)applyContentSafeAreaAdditionalInsets {
    UIEdgeInsets insets = [self contentSafeAreaAdditionalInsets];
    [[self headerSafeAreaTopConstraint] setConstant:insets.top];
    [[self headerSafeAreaLeadingConstraint] setConstant:insets.left];
    [[self headerSafeAreaTrailingConstraint] setConstant:-insets.right];
    for (NSLayoutConstraint *constraint in [self contentSafeAreaLeadingConstraints]) {
        [constraint setConstant:insets.left];
    }
    for (NSLayoutConstraint *constraint in [self contentSafeAreaTrailingConstraints]) {
        [constraint setConstant:-insets.right];
    }
    for (NSLayoutConstraint *constraint in [self contentSafeAreaBottomConstraints]) {
        [constraint setConstant:-insets.bottom];
    }
}

- (void)setContentSafeAreaAdditionalInsets:(UIEdgeInsets)contentSafeAreaAdditionalInsets {
    contentSafeAreaAdditionalInsets =
        [self contentSafeAreaAdditionalInsetsRemovingRedundantSystemInsets:contentSafeAreaAdditionalInsets];
    if (UIEdgeInsetsEqualToEdgeInsets(_contentSafeAreaAdditionalInsets, contentSafeAreaAdditionalInsets)) {
        return;
    }

    _contentSafeAreaAdditionalInsets = contentSafeAreaAdditionalInsets;
    [self applyContentSafeAreaAdditionalInsets];
    [self setNeedsLayout];
}

- (void)setContentRespectsSafeArea:(BOOL)contentRespectsSafeArea {
    if (_contentRespectsSafeArea == contentRespectsSafeArea) {
        return;
    }

    _contentRespectsSafeArea = contentRespectsSafeArea;
    [self applyContentSafeAreaAdditionalInsets];
    [[self headerTopConstraint] setActive:!contentRespectsSafeArea];
    [[self headerSafeAreaTopConstraint] setActive:contentRespectsSafeArea];
    [[self headerLeadingConstraint] setActive:!contentRespectsSafeArea];
    [[self headerSafeAreaLeadingConstraint] setActive:contentRespectsSafeArea];
    [[self headerTrailingConstraint] setActive:!contentRespectsSafeArea];
    [[self headerSafeAreaTrailingConstraint] setActive:contentRespectsSafeArea];
    for (NSLayoutConstraint *constraint in [self contentLeadingConstraints]) {
        [constraint setActive:!contentRespectsSafeArea];
    }
    for (NSLayoutConstraint *constraint in [self contentSafeAreaLeadingConstraints]) {
        [constraint setActive:contentRespectsSafeArea];
    }
    for (NSLayoutConstraint *constraint in [self contentTrailingConstraints]) {
        [constraint setActive:!contentRespectsSafeArea];
    }
    for (NSLayoutConstraint *constraint in [self contentSafeAreaTrailingConstraints]) {
        [constraint setActive:contentRespectsSafeArea];
    }
    for (NSLayoutConstraint *constraint in [self contentBottomConstraints]) {
        [constraint setActive:YES];
    }
    for (NSLayoutConstraint *constraint in [self contentSafeAreaBottomConstraints]) {
        [constraint setActive:NO];
    }
    [self setNeedsLayout];
}

- (void)setTitleText:(NSString *)title {
    [[self headerView] setTitleText:title];
}

- (void)setClearButtonEnabledForItemCount:(NSUInteger)itemCount {
    BOOL enabled = itemCount > 0;
    [[[self headerView] trailingButton] setEnabled:enabled];
    [[[self headerView] trailingButton] setAlpha:enabled ? 1.0 : 0.35];
}

#pragma mark - Content Transitions

- (void)showContentView:(UIView *)viewToShow
        hideContentView:(UIView *)viewToHide
                  title:(NSString *)title
              direction:(KayokoContentTransitionDirection)direction {
    [self showContentView:viewToShow hideContentView:viewToHide title:title direction:direction completion:nil];
}

- (void)showContentView:(UIView *)viewToShow
        hideContentView:(UIView *)viewToHide
                  title:(NSString *)title
              direction:(KayokoContentTransitionDirection)direction
             completion:(void (^)(void))completion {
    [self showContentView:viewToShow
            hideContentView:viewToHide
                      title:title
                  direction:direction
        alongsideAnimations:nil
                 completion:completion];
}

- (void)showContentView:(UIView *)viewToShow
        hideContentView:(UIView *)viewToHide
                  title:(NSString *)title
              direction:(KayokoContentTransitionDirection)direction
    alongsideAnimations:(void (^)(void))alongsideAnimations
             completion:(void (^)(void))completion {
    [self showContentView:viewToShow
            hideContentView:viewToHide
                      title:title
               updatesTitle:YES
                  direction:direction
        alongsideAnimations:alongsideAnimations
                 completion:completion];
}

- (void)showContentView:(UIView *)viewToShow
        hideContentView:(UIView *)viewToHide
                  title:(NSString *)title
           updatesTitle:(BOOL)updatesTitle
              direction:(KayokoContentTransitionDirection)direction
    alongsideAnimations:(void (^)(void))alongsideAnimations
             completion:(void (^)(void))completion {
    if (updatesTitle) {
        [UIView transitionWithView:[[self headerView] titleLabel]
                          duration:0.1
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                          [self setTitleText:title];
                        }
                        completion:nil];
    }

    [self showContentView:viewToShow
          transitioningView:viewToShow
            hideContentView:viewToHide
          transitioningView:viewToHide
                  direction:direction
        alongsideAnimations:alongsideAnimations
                 completion:completion];
}

- (void)showContentView:(UIView *)viewToShow
      transitioningView:(UIView *)viewToShowTransition
        hideContentView:(UIView *)viewToHide
      transitioningView:(UIView *)viewToHideTransition
              direction:(KayokoContentTransitionDirection)direction
    alongsideAnimations:(void (^)(void))alongsideAnimations
             completion:(void (^)(void))completion {
    CGAffineTransform viewToShowTransform = CGAffineTransformIdentity;
    CGAffineTransform viewToHideTransform = CGAffineTransformIdentity;
    [self preparedTransformsForDirection:direction
                     viewToShowTransform:&viewToShowTransform
                     viewToHideTransform:&viewToHideTransform];

    [viewToShowTransition setTransform:viewToShowTransform];
    [viewToShowTransition setAlpha:0];
    if (viewToShow != viewToShowTransition) {
        [viewToShow setTransform:CGAffineTransformIdentity];
        [viewToShow setAlpha:1];
    }
    [viewToShow setHidden:NO];
    [self setAnimating:YES];

    [UIView animateWithDuration:0.3
        delay:0
        usingSpringWithDamping:1
        initialSpringVelocity:0
        options:UIViewAnimationOptionCurveEaseOut
        animations:^{
          if (alongsideAnimations) {
              alongsideAnimations();
          }
          [viewToShowTransition setTransform:CGAffineTransformIdentity];
          [viewToShowTransition setAlpha:1];
          [viewToHideTransition setTransform:viewToHideTransform];
          [viewToHideTransition setAlpha:0];
        }
        completion:^(__unused BOOL finished) {
          [self completePreparedContentTransitionHidingView:viewToHide completion:completion];
        }];
}

- (void)preparedTransformsForDirection:(KayokoContentTransitionDirection)direction
                   viewToShowTransform:(CGAffineTransform *)viewToShowTransform
                   viewToHideTransform:(CGAffineTransform *)viewToHideTransform {
    *viewToShowTransform = CGAffineTransformIdentity;
    *viewToHideTransform = CGAffineTransformIdentity;
    switch (direction) {
    case KayokoContentTransitionDirectionForward:
    case KayokoContentTransitionDirectionModalPresenting:
        *viewToShowTransform = CGAffineTransformMakeTranslation(0, -10);
        *viewToHideTransform = CGAffineTransformMakeTranslation(0, 10);
        break;
    case KayokoContentTransitionDirectionBackward:
    case KayokoContentTransitionDirectionModalDismissing:
        *viewToShowTransform = CGAffineTransformMakeTranslation(0, 10);
        *viewToHideTransform = CGAffineTransformMakeTranslation(0, -10);
        break;
    case KayokoContentTransitionDirectionSiblingForward:
        *viewToShowTransform = CGAffineTransformMakeTranslation(10, 0);
        *viewToHideTransform = CGAffineTransformMakeTranslation(-10, 0);
        break;
    case KayokoContentTransitionDirectionSiblingBackward:
        *viewToShowTransform = CGAffineTransformMakeTranslation(-10, 0);
        *viewToHideTransform = CGAffineTransformMakeTranslation(10, 0);
        break;
    }
}

- (void)prepareContentTransitionToView:(UIView *)viewToShow
                       hideContentView:(UIView *)viewToHide
                                 title:(NSString *)title
                             direction:(KayokoContentTransitionDirection)direction {
    [self prepareContentTransitionToView:viewToShow
                         hideContentView:viewToHide
                                   title:title
                            updatesTitle:YES
                               direction:direction];
}

- (void)prepareContentTransitionToView:(UIView *)viewToShow
                       hideContentView:(UIView *)viewToHide
                                 title:(NSString *)title
                          updatesTitle:(BOOL)updatesTitle
                             direction:(KayokoContentTransitionDirection)direction {
    if (updatesTitle) {
        [UIView transitionWithView:[[self headerView] titleLabel]
                          duration:0.1
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                          [self setTitleText:title];
                        }
                        completion:nil];
    }

    CGAffineTransform viewToShowTransform = CGAffineTransformIdentity;
    CGAffineTransform viewToHideTransform = CGAffineTransformIdentity;
    [self preparedTransformsForDirection:direction
                     viewToShowTransform:&viewToShowTransform
                     viewToHideTransform:&viewToHideTransform];

    [viewToShow setTransform:viewToShowTransform];
    [viewToShow setAlpha:0];
    [viewToShow setHidden:NO];

    [self setAnimating:YES];
}

- (void)applyPreparedContentTransitionToView:(UIView *)viewToShow
                             hideContentView:(UIView *)viewToHide
                                   direction:(KayokoContentTransitionDirection)direction {
    CGAffineTransform viewToShowTransform = CGAffineTransformIdentity;
    CGAffineTransform viewToHideTransform = CGAffineTransformIdentity;
    [self preparedTransformsForDirection:direction
                     viewToShowTransform:&viewToShowTransform
                     viewToHideTransform:&viewToHideTransform];

    [viewToShow setTransform:CGAffineTransformIdentity];
    [viewToShow setAlpha:1];

    [viewToHide setTransform:viewToHideTransform];
    [viewToHide setAlpha:0];
}

- (void)completePreparedContentTransitionHidingView:(UIView *)viewToHide completion:(void (^)(void))completion {
    [viewToHide setHidden:YES];
    [self setAnimating:NO];
    if (completion) {
        completion();
    }
}

- (CGFloat)clampedInteractiveContentTransitionProgress:(CGFloat)progress {
    return MIN(MAX(progress, 0), 1);
}

#pragma mark - Interactive Back Transition

- (void)applyInteractiveBackwardContentTransitionToView:(UIView *)viewToShow
                                    alongsideViewToShow:(UIView *)viewToShowAlongside
                                        hideContentView:(UIView *)viewToHide
                                               progress:(CGFloat)progress {
    CGFloat clampedProgress = [self clampedInteractiveContentTransitionProgress:progress];
    CGFloat width = CGRectGetWidth([[self contentContainerView] bounds]);
    CGAffineTransform viewToShowTransform = CGAffineTransformMakeTranslation(width * (clampedProgress - 1), 0);

    [viewToShow setTransform:viewToShowTransform];
    [viewToShow setAlpha:1];
    [viewToShowAlongside setTransform:viewToShowTransform];
    [viewToShowAlongside setAlpha:1];

    [viewToHide setTransform:CGAffineTransformMakeTranslation(width * clampedProgress, 0)];
    [viewToHide setAlpha:1];
}

- (void)beginInteractiveBackwardContentTransitionToView:(UIView *)viewToShow
                                    alongsideViewToShow:(UIView *)viewToShowAlongside
                                        hideContentView:(UIView *)viewToHide {
    [viewToShow setHidden:NO];
    [viewToShowAlongside setHidden:NO];
    [self setAnimating:YES];
    [self applyInteractiveBackwardContentTransitionToView:viewToShow
                                      alongsideViewToShow:viewToShowAlongside
                                          hideContentView:viewToHide
                                                 progress:0];
}

- (void)updateInteractiveBackwardContentTransitionToView:(UIView *)viewToShow
                                     alongsideViewToShow:(UIView *)viewToShowAlongside
                                         hideContentView:(UIView *)viewToHide
                                                progress:(CGFloat)progress {
    [self applyInteractiveBackwardContentTransitionToView:viewToShow
                                      alongsideViewToShow:viewToShowAlongside
                                          hideContentView:viewToHide
                                                 progress:progress];
}

- (void)finishInteractiveBackwardContentTransitionToView:(UIView *)viewToShow
                                     alongsideViewToShow:(UIView *)viewToShowAlongside
                                         hideContentView:(UIView *)viewToHide
                                                duration:(NSTimeInterval)duration
                                     alongsideAnimations:(void (^)(void))alongsideAnimations
                                              completion:(void (^)(void))completion {
    [UIView animateWithDuration:duration
        delay:0
        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
        animations:^{
          if (alongsideAnimations) {
              alongsideAnimations();
          }
          [self applyInteractiveBackwardContentTransitionToView:viewToShow
                                            alongsideViewToShow:viewToShowAlongside
                                                hideContentView:viewToHide
                                                       progress:1];
        }
        completion:^(__unused BOOL finished) {
          [viewToShow setTransform:CGAffineTransformIdentity];
          [viewToShow setAlpha:1];
          [viewToShowAlongside setTransform:CGAffineTransformIdentity];
          [viewToShowAlongside setAlpha:1];
          [viewToHide setHidden:YES];
          [viewToHide setTransform:CGAffineTransformIdentity];
          [viewToHide setAlpha:1];
          [self setAnimating:NO];
          if (completion) {
              completion();
          }
        }];
}

- (void)cancelInteractiveBackwardContentTransitionToView:(UIView *)viewToShow
                                     alongsideViewToShow:(UIView *)viewToShowAlongside
                                         hideContentView:(UIView *)viewToHide
                                                duration:(NSTimeInterval)duration
                                              completion:(void (^)(void))completion {
    [UIView animateWithDuration:duration
        delay:0
        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
        animations:^{
          [self applyInteractiveBackwardContentTransitionToView:viewToShow
                                            alongsideViewToShow:viewToShowAlongside
                                                hideContentView:viewToHide
                                                       progress:0];
        }
        completion:^(__unused BOOL finished) {
          [viewToShow setHidden:YES];
          [viewToShow setTransform:CGAffineTransformIdentity];
          [viewToShow setAlpha:1];
          [viewToShowAlongside setHidden:YES];
          [viewToShowAlongside setTransform:CGAffineTransformIdentity];
          [viewToShowAlongside setAlpha:1];
          [viewToHide setTransform:CGAffineTransformIdentity];
          [viewToHide setAlpha:1];
          [self setAnimating:NO];
          if (completion) {
              completion();
          }
        }];
}


#pragma mark - Floating Chrome

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle previousStyle =
            previousTraitCollection ? previousTraitCollection.userInterfaceStyle : UIUserInterfaceStyleUnspecified;
        UIUserInterfaceStyle currentStyle = self.traitCollection.userInterfaceStyle;
        if (previousStyle != currentStyle) {
            [self applyMaterialAppearance];
        }
    }
    [self updateFloatingChromeAppearanceForcingRadiusResolution:YES];
}



- (BOOL)prefersDarkPanelMaterial {
    if (@available(iOS 13.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

- (UIBlurEffectStyle)preferredPanelBlurStyle {
    if (@available(iOS 13.0, *)) {
        // Thin material keeps glass translucent while remaining brighter than ultra-thin gray fills.
        return [self prefersDarkPanelMaterial] ? UIBlurEffectStyleSystemThinMaterialDark
                                               : UIBlurEffectStyleSystemThinMaterialLight;
    }
    return UIBlurEffectStyleRegular;
}

- (UIColor *)preferredMaterialTintColor {
    if ([self prefersDarkPanelMaterial]) {
        // Slight cool lift in dark mode so the sheet does not become a flat charcoal slab.
        return [UIColor colorWithWhite:1.0 alpha:0.06];
    }
    // Light mode: brighten the frosted glass toward the reference translucent white card.
    return [UIColor colorWithWhite:1.0 alpha:0.34];
}

- (void)applyMaterialAppearance {
    UIBlurEffect *blurEffect = [UIBlurEffect effectWithStyle:[self preferredPanelBlurStyle]];
    [self setBlurEffect:blurEffect];
    [[self blurEffectView] setEffect:blurEffect];
    [[self materialTintView] setBackgroundColor:[self preferredMaterialTintColor]];
}

- (CGFloat)resolvedPanelCornerRadius {
    // Prefer Apple's private display corner radius (continuous/squircle corners).
    CGFloat radius = 0;
    UIScreen *screen = self.window.windowScene.screen ?: [UIScreen mainScreen];
    @try {
        NSNumber *value = [screen valueForKey:@"_displayCornerRadius"];
        if (!value) {
            value = [screen valueForKey:@"displayCornerRadius"];
        }
        if ([value respondsToSelector:@selector(doubleValue)]) {
            radius = [value doubleValue];
        }
    } @catch (__unused NSException *exception) {
        radius = 0;
    }

    // Fallback for older devices / failed KVC: approximate continuous device radius.
    if (radius < 20.0) {
        UIWindow *window = self.window;
        UIEdgeInsets insets = window ? window.safeAreaInsets : UIEdgeInsetsZero;
        if (insets.bottom > 0) {
            radius = 55.0; // modern iPhone continuous corner ballpark
        } else if (insets.top > 20.0) {
            radius = 47.0;
        } else {
            radius = kKayokoPanelCornerRadiusFallback;
        }
    }

    // Floating sheet is inset from the screen edge, so slightly reduce the device radius
    // to keep the visual curvature harmonious with the device bezel.
    radius = MAX(radius - 3.0, 28.0);
    return radius;
}

- (void)updateFloatingChromeAppearance {
    [self updateFloatingChromeAppearanceForcingRadiusResolution:NO];
}

- (void)updateFloatingChromeAppearanceForcingRadiusResolution:(BOOL)forceRadiusResolution {
    CGSize boundsSize = [self bounds].size;
    BOOL boundsChanged = !CGSizeEqualToSize(boundsSize, [self cachedChromeBoundsSize]);
    if (!forceRadiusResolution && [self hasCachedChromeAppearance] && !boundsChanged) {
        return;
    }

    CGFloat radius = [self cachedPanelCornerRadius];
    if (forceRadiusResolution || ![self hasCachedChromeAppearance] || radius <= 0) {
        radius = [self resolvedPanelCornerRadius];
        [self setCachedPanelCornerRadius:radius];
    }

    BOOL radiusChanged = fabs(radius - [[self layer] cornerRadius]) > 0.05;
    if (!forceRadiusResolution && [self hasCachedChromeAppearance] && !boundsChanged && !radiusChanged) {
        return;
    }

    if (@available(iOS 13.0, *)) {
        [[self layer] setCornerCurve:kCACornerCurveContinuous];
        [[[self chromeClipView] layer] setCornerCurve:kCACornerCurveContinuous];
        [[[self blurEffectView] layer] setCornerCurve:kCACornerCurveContinuous];
    }

    // Outer view keeps radius for shadow path; clip view actually clips children.
    CACornerMask cornerMask =
        kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    [[self layer] setCornerRadius:radius];
    [[[self chromeClipView] layer] setCornerRadius:radius];
    [[[self blurEffectView] layer] setCornerRadius:radius];
    if (@available(iOS 11.0, *)) {
        [[self layer] setMaskedCorners:cornerMask];
        [[[self chromeClipView] layer] setMaskedCorners:cornerMask];
        [[[self blurEffectView] layer] setMaskedCorners:cornerMask];
    }
    [[self layer] setMasksToBounds:NO];
    [[[self chromeClipView] layer] setMasksToBounds:YES];
    [[[self blurEffectView] layer] setMasksToBounds:YES];
    [[self contentContainerView] setClipsToBounds:YES];

    // Continuous corners are not exact circular arcs, but a rounded shadow path is still
    // dramatically cheaper than forcing Core Animation to recompute soft shadows every frame.
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius];
    [[self layer] setShadowPath:path.CGPath];
    [self setCachedChromeBoundsSize:boundsSize];
    [self setHasCachedChromeAppearance:YES];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    // Window/screen changes can change the preferred device corner radius.
    [self setHasCachedChromeAppearance:NO];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self updateFloatingChromeAppearance];
}

@end
