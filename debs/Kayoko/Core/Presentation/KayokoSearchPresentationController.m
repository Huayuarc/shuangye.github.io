//
//  KayokoSearchPresentationController.m
//  Kayoko
//

#import "KayokoSearchPresentationController.h"

#import "KayokoHeaderView.h"
#import "KayokoHistoryListView.h"
#import "KayokoHeaderButtonStyle.h"
#import "KayokoMainView.h"
#import "KayokoSearchBar.h"

static CGFloat const kKayokoSearchHeaderHeight = 56;
static CGFloat const kKayokoSearchBarHorizontalInset = 16;
static NSTimeInterval const kKayokoSearchFullscreenAnimationDuration = 0.42;
static CGFloat const kKayokoSearchFullscreenAnimationDamping = 0.86;
static CGFloat const kKayokoSearchFullscreenCollapseVelocity = 900;
static CGFloat const kKayokoSearchFullscreenReboundVelocity = -450;
static CGFloat const kKayokoSearchFullscreenCollapseProgress = 0.32;
static NSTimeInterval const kKayokoSearchCompactLandscapeTitleRowAnimationDuration = 0.24;

@interface UIPeripheralHost : NSObject
+ (instancetype)sharedInstance;
+ (NSArray<NSValue *> *)allVisiblePeripheralFrames;
- (BOOL)isOnScreen;
@end

static CGRect kayokoStatusBarFrameForWindow(UIWindow *window) {
    CGRect statusBarFrame = CGRectZero;
    UIWindowScene *windowScene = [window windowScene];
    if (windowScene) {
        statusBarFrame = [[windowScene statusBarManager] statusBarFrame];
    }

    if (CGRectIsEmpty(statusBarFrame)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        statusBarFrame = [[UIApplication sharedApplication] statusBarFrame];
#pragma clang diagnostic pop
    }

    return statusBarFrame;
}

NS_ASSUME_NONNULL_BEGIN

@interface KayokoSearchPresentationController ()

#pragma mark - Views

@property(nonatomic, weak) UIView *containerView;
@property(nonatomic, weak) KayokoHeaderView *headerView;

#pragma mark - Search Bars

@property(nonatomic, weak) UISearchBar *historySearchBar;
@property(nonatomic, weak) UISearchBar *favoritesSearchBar;
@property(nonatomic, weak) UIView *historySearchTokenView;
@property(nonatomic, weak) UIView *favoritesSearchTokenView;
@property(nonatomic, strong) UIView *historySearchHeaderView;
@property(nonatomic, strong) UIView *favoritesSearchHeaderView;

#pragma mark - Lists

@property(nonatomic, weak) KayokoHistoryListView *historyTableView;
@property(nonatomic, weak) KayokoHistoryListView *favoritesTableView;

#pragma mark - Gestures

@property(nonatomic, weak) UIPanGestureRecognizer *panGestureRecognizer;

#pragma mark - State

@property(nonatomic, assign, getter=isSearchActive) BOOL searchActive;
@property(nonatomic, assign) CGRect normalFrameBeforeSearch;
@property(nonatomic, assign) BOOL hasNormalFrameBeforeSearch;
// Host-relative keyboard occlusion used to keep the portrait card above the keyboard.
@property(nonatomic, assign) CGFloat hostKeyboardBottomInset;

#pragma mark - Keyboard

@property(nonatomic, assign, readwrite) CGFloat keyboardBottomInset;
@end

NS_ASSUME_NONNULL_END

@implementation KayokoSearchPresentationController

#pragma mark - Lifecycle

- (instancetype)initWithContainerView:(UIView *)containerView
                           headerView:(KayokoHeaderView *)headerView
                     historySearchBar:(UISearchBar *)historySearchBar
                   favoritesSearchBar:(UISearchBar *)favoritesSearchBar
               historySearchTokenView:(UIView *)historySearchTokenView
             favoritesSearchTokenView:(UIView *)favoritesSearchTokenView
                     historyTableView:(KayokoHistoryListView *)historyTableView
                   favoritesTableView:(KayokoHistoryListView *)favoritesTableView
                 panGestureRecognizer:(UIPanGestureRecognizer *)panGestureRecognizer {
    self = [super init];
    if (self) {
        _presentationMode = KayokoPanelPresentationModePortraitDrawer;
        _containerView = containerView;
        _headerView = headerView;
        _historySearchBar = historySearchBar;
        _favoritesSearchBar = favoritesSearchBar;
        _historySearchTokenView = historySearchTokenView;
        _favoritesSearchTokenView = favoritesSearchTokenView;
        _historyTableView = historyTableView;
        _favoritesTableView = favoritesTableView;
        _panGestureRecognizer = panGestureRecognizer;
        [self installSearchBarForTableView:historyTableView];
        [self installSearchBarForTableView:favoritesTableView];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleKeyboardWillChangeFrameNotification:)
                                                     name:UIKeyboardWillChangeFrameNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleKeyboardWillHideNotification:)
                                                     name:UIKeyboardWillHideNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Layout

- (CGFloat)searchHeaderHeight {
    return kKayokoSearchHeaderHeight;
}

- (void)layout {
    [self layoutSearchBarForTableView:[self historyTableView]];
    [self layoutSearchBarForTableView:[self favoritesTableView]];
    [self applyBottomInsetsToTableViews];
}

- (void)updateSearchTokenViews {
    [self layout];
}

- (void)layoutSearchBarForTableView:(KayokoHistoryListView *)tableView {
    [tableView updateNoSearchResultsPlaceholderLayout];
    [tableView setSearchBarSnapHeight:kKayokoSearchHeaderHeight];

    UISearchBar *searchBar = [self searchBarForTableView:tableView];
    UIView *headerView = [self searchHeaderViewForTableView:tableView];
    if ([tableView tableHeaderView] != headerView) {
        return;
    }

    CGFloat width = CGRectGetWidth([tableView bounds]);
    UIView *tokenView = [self searchTokenViewForTableView:tableView];
    CGFloat tokenHeight = (tokenView && ![tokenView isHidden]) ? CGRectGetHeight([tokenView frame]) : 0;
    CGFloat headerHeight = kKayokoSearchHeaderHeight + tokenHeight;
    CGRect headerFrame = CGRectMake(0, 0, width, headerHeight);
    CGRect searchBarFrame = CGRectMake(0, 0, width, kKayokoSearchHeaderHeight);
    CGRect tokenFrame = CGRectMake(0, kKayokoSearchHeaderHeight, width, tokenHeight);

    BOOL needsTableHeaderUpdate = !CGRectEqualToRect([headerView frame], headerFrame);
    [headerView setFrame:headerFrame];
    [searchBar setFrame:searchBarFrame];
    [tokenView setFrame:tokenFrame];
    if (needsTableHeaderUpdate) {
        [tableView setTableHeaderView:headerView];
    }
}

#pragma mark - Search Header Views

- (UISearchBar *)searchBarForTableView:(KayokoHistoryListView *)tableView {
    return tableView == [self favoritesTableView] ? [self favoritesSearchBar] : [self historySearchBar];
}

- (UIView *)searchTokenViewForTableView:(KayokoHistoryListView *)tableView {
    return tableView == [self favoritesTableView] ? [self favoritesSearchTokenView] : [self historySearchTokenView];
}

- (UIView *)searchHeaderViewForTableView:(KayokoHistoryListView *)tableView {
    return tableView == [self favoritesTableView] ? [self favoritesSearchHeaderView] : [self historySearchHeaderView];
}

- (void)setSearchHeaderView:(UIView *)headerView forTableView:(KayokoHistoryListView *)tableView {
    if (tableView == [self favoritesTableView]) {
        [self setFavoritesSearchHeaderView:headerView];
    } else {
        [self setHistorySearchHeaderView:headerView];
    }
}

- (void)installSearchBarForTableView:(KayokoHistoryListView *)tableView {
    if (!tableView) {
        return;
    }

    UISearchBar *searchBar = [self searchBarForTableView:tableView];
    UIView *headerView = [self searchHeaderViewForTableView:tableView];
    UIView *tokenView = [self searchTokenViewForTableView:tableView];

    if ([searchBar respondsToSelector:@selector(setKayokoHorizontalFrameInset:)]) {
        [(KayokoSearchBar *)searchBar setKayokoHorizontalFrameInset:kKayokoSearchBarHorizontalInset];
    }

    if (!headerView) {
        headerView = [[UIView alloc] initWithFrame:CGRectZero];
        [headerView setBackgroundColor:[UIColor clearColor]];
        [headerView setClipsToBounds:YES];
        [self setSearchHeaderView:headerView forTableView:tableView];
    }
    if ([searchBar superview] != headerView) {
        [searchBar removeFromSuperview];
        [headerView addSubview:searchBar];
    }
    if (tokenView && [tokenView superview] != headerView) {
        [tokenView removeFromSuperview];
        [headerView addSubview:tokenView];
    }
    if ([tableView tableHeaderView] != headerView) {
        [tableView setTableHeaderView:headerView];
    }
    [self layoutSearchBarForTableView:tableView];
}

#pragma mark - Search Bar Visibility

- (void)setContentOffset:(CGPoint)contentOffset
            forTableView:(KayokoHistoryListView *)tableView
                animated:(BOOL)animated {
    if (!animated) {
        [tableView setContentOffset:contentOffset animated:NO];
        return;
    }

    if ([UIView inheritedAnimationDuration] > 0) {
        [tableView setContentOffset:contentOffset];
    } else {
        [tableView setContentOffset:contentOffset animated:YES];
    }
}

- (CGFloat)hiddenSearchHeaderOffsetForTableView:(KayokoHistoryListView *)tableView {
    // Only the search bar is scrolled out of view while browsing; a visible favorites
    // filter panel stays pinned below by keeping the hidden offset at the search bar height.
    return [self searchHeaderHeight];
}

- (void)attachToTableView:(KayokoHistoryListView *)tableView hidesSearchBar:(BOOL)hidesSearchBar {
    [self installSearchBarForTableView:[self historyTableView]];
    [self installSearchBarForTableView:[self favoritesTableView]];
    [self layout];

    if (!tableView) {
        return;
    }

    if (hidesSearchBar && ![self isSearchActive]) {
        [self hideSearchBarInTableView:tableView animated:NO];
    } else if ([self isSearchActive]) {
        [self revealSearchBarInTableView:tableView animated:NO];
    }
}

- (void)hideSearchBarInTableView:(KayokoHistoryListView *)tableView animated:(BOOL)animated {
    UIView *headerView = [self searchHeaderViewForTableView:tableView];
    if (!tableView || [tableView tableHeaderView] != headerView || [self isSearchActive]) {
        return;
    }

    [self applyBottomInsetToTableView:tableView];

    CGPoint contentOffset = [tableView contentOffset];
    contentOffset.y = MAX(contentOffset.y, [self hiddenSearchHeaderOffsetForTableView:tableView]);
    [self setContentOffset:contentOffset forTableView:tableView animated:animated];
}

- (void)revealSearchBarInTableView:(KayokoHistoryListView *)tableView animated:(BOOL)animated {
    UIView *headerView = [self searchHeaderViewForTableView:tableView];
    if (!tableView || [tableView tableHeaderView] != headerView) {
        return;
    }

    [self applyBottomInsetToTableView:tableView];

    CGPoint contentOffset = [tableView contentOffset];
    contentOffset.y = 0;
    [self setContentOffset:contentOffset forTableView:tableView animated:animated];
}

#pragma mark - Fullscreen Geometry

- (BOOL)usesPortraitCardSearchPresentation {
    return [self presentationMode] != KayokoPanelPresentationModeCompactLandscapeFullscreen;
}

- (CGRect)portraitSearchFrameForHostKeyboardBottomInset:(CGFloat)hostKeyboardBottomInset {
    UIView *containerView = [self containerView];
    UIView *superview = [containerView superview];
    if (!superview) {
        return [containerView frame];
    }

    CGRect bounds = [superview bounds];
    CGFloat inset = kKayokoPanelFloatingInset;
    CGRect referenceFrame = [self hasNormalFrameBeforeSearch] ? [self normalFrameBeforeSearch] : [containerView frame];

    // Preserve floating-card width/x. Never expand portrait search to full host bounds.
    CGFloat width = CGRectGetWidth(referenceFrame);
    CGFloat x = CGRectGetMinX(referenceFrame);
    if (width <= 0.0 || width >= CGRectGetWidth(bounds) - 1.0) {
        width = MIN(kKayokoPanelFloatingMaxWidth, CGRectGetWidth(bounds) - inset * 2.0);
        width = MAX(width, 280.0);
        x = CGRectGetMidX(bounds) - width * 0.5;
    }

    CGFloat preferredHeight = CGRectGetHeight(referenceFrame);
    if (preferredHeight <= 0.0) {
        preferredHeight = MIN(420.0, CGRectGetHeight(bounds) - inset * 2.0);
        preferredHeight = MAX(preferredHeight, 220.0);
    }

    // Sit the card above the keyboard with the same edge gap as the floating chrome.
    CGFloat availableBottom = CGRectGetMaxY(bounds) - MAX(hostKeyboardBottomInset, 0.0) - inset;
    CGFloat maxHeight = MAX(availableBottom - inset, 220.0);
    CGFloat height = MIN(preferredHeight, maxHeight);
    CGFloat y = availableBottom - height;
    if (y < inset) {
        y = inset;
        height = MIN(height, MAX(availableBottom - y, 220.0));
    }
    return CGRectMake(x, y, width, height);
}

- (CGRect)activeSearchFrame {
    if (![self usesPortraitCardSearchPresentation]) {
        return [self hasNormalFrameBeforeSearch] ? [self normalFrameBeforeSearch] : [[self containerView] frame];
    }

    return [self portraitSearchFrameForHostKeyboardBottomInset:[self hostKeyboardBottomInset]];
}

- (CGFloat)currentHostKeyboardBottomInset {
    UIView *containerView = [self containerView];
    UIView *referenceView = [containerView superview] ?: containerView;
    UIWindow *window = [referenceView window] ?: [containerView window];
    if (!referenceView || !window) {
        return 0;
    }

    Class hostClass = NSClassFromString(@"UIPeripheralHost");
    if ([hostClass respondsToSelector:@selector(sharedInstance)] &&
        [hostClass respondsToSelector:@selector(allVisiblePeripheralFrames)]) {
        UIPeripheralHost *host = [(id)hostClass sharedInstance];
        if ([host respondsToSelector:@selector(isOnScreen)] && ![host isOnScreen]) {
            return 0;
        }

        CGRect keyboardFrame = CGRectNull;
        NSArray<NSValue *> *visibleFrames = [(id)hostClass allVisiblePeripheralFrames];
        for (NSValue *frameValue in visibleFrames) {
            if (![frameValue respondsToSelector:@selector(CGRectValue)]) {
                continue;
            }
            CGRect frame = [frameValue CGRectValue];
            if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) {
                continue;
            }
            keyboardFrame = CGRectIsNull(keyboardFrame) ? frame : CGRectUnion(keyboardFrame, frame);
        }

        if (!CGRectIsNull(keyboardFrame) && !CGRectIsEmpty(keyboardFrame)) {
            CGRect keyboardFrameInView = [referenceView convertRect:keyboardFrame fromView:nil];
            CGFloat referenceBottom = CGRectGetMaxY([referenceView bounds]);
            CGFloat keyboardTop = CGRectGetMinY(keyboardFrameInView);
            if (keyboardTop < referenceBottom - 0.5) {
                return MAX(referenceBottom - keyboardTop, 0);
            }
        }
    }

    return 0;
}

- (void)seedHostKeyboardBottomInsetFromVisibleKeyboardIfNeeded {
    if (![self usesPortraitCardSearchPresentation]) {
        return;
    }
    if ([self hostKeyboardBottomInset] > 0.5) {
        return;
    }

    CGFloat sampledInset = [self currentHostKeyboardBottomInset];
    if (sampledInset > 0.5) {
        [self setHostKeyboardBottomInset:sampledInset];
        // Portrait card sits above the keyboard; list content does not need keyboard padding.
        [self setKeyboardBottomInset:0];
        [self applyBottomInsetsToTableViews];
    }
}

- (UIEdgeInsets)contentSafeAreaAdditionalInsetsForFullscreenSuperview:(UIView *)superview {
    UIView *containerView = [self containerView];
    UIEdgeInsets safeAreaInsets = [superview safeAreaInsets];
    UIEdgeInsets additionalInsets = UIEdgeInsetsZero;
    if (safeAreaInsets.top > 0) {
        return additionalInsets;
    }

    CGRect statusBarFrame = kayokoStatusBarFrameForWindow([containerView window]);
    if (CGRectIsEmpty(statusBarFrame)) {
        return additionalInsets;
    }

    CGRect statusBarFrameInSuperview = [superview convertRect:statusBarFrame fromView:nil];
    CGFloat statusBarBottom = CGRectGetMaxY(statusBarFrameInSuperview) - CGRectGetMinY([superview bounds]);
    additionalInsets.top = ceil(MAX(statusBarBottom, 0));
    return additionalInsets;
}

- (CGRect)fullscreenFrame {
    // Historical name: "expanded" search frame. Portrait keeps the floating card and only
    // repositions it above the keyboard; it no longer expands to the host bounds.
    return [self activeSearchFrame];
}

- (CGRect)collapsedFrame {
    return [self hasNormalFrameBeforeSearch] ? [self normalFrameBeforeSearch] : [[self containerView] frame];
}

- (CGRect)frameFromFullscreenFrame:(CGRect)fullscreenFrame
                    collapsedFrame:(CGRect)collapsedFrame
                          progress:(CGFloat)progress {
    progress = MIN(MAX(progress, 0), 1);
    return CGRectMake(fullscreenFrame.origin.x + (collapsedFrame.origin.x - fullscreenFrame.origin.x) * progress,
                      fullscreenFrame.origin.y + (collapsedFrame.origin.y - fullscreenFrame.origin.y) * progress,
                      fullscreenFrame.size.width + (collapsedFrame.size.width - fullscreenFrame.size.width) * progress,
                      fullscreenFrame.size.height +
                          (collapsedFrame.size.height - fullscreenFrame.size.height) * progress);
}

- (CGFloat)fullscreenCollapseProgressForTranslation:(CGFloat)translationY {
    CGRect fullscreenFrame = [self fullscreenFrame];
    CGRect collapsedFrame = [self collapsedFrame];
    CGFloat collapseDistance = CGRectGetMinY(collapsedFrame) - CGRectGetMinY(fullscreenFrame);
    if (collapseDistance <= 0) {
        return 0;
    }

    return MIN(MAX(translationY / collapseDistance, 0), 1);
}

- (NSTimeInterval)fullscreenPanAnimationDurationToFrame:(CGRect)targetFrame velocityY:(CGFloat)velocityY {
    CGFloat distance = fabs(CGRectGetMinY(targetFrame) - CGRectGetMinY([[self containerView] frame]));
    if (distance <= 1) {
        return 0.12;
    }

    CGFloat effectiveVelocity = MAX(fabs(velocityY), kKayokoSearchFullscreenCollapseVelocity);
    return MIN(MAX(distance / effectiveVelocity, 0.12), kKayokoSearchFullscreenAnimationDuration);
}

#pragma mark - Search Presentation

- (void)beginSearchWithActiveTableView:(KayokoHistoryListView *)activeTableView completion:(void (^)(void))completion {
    if ([self isSearchActive]) {
        return;
    }

    [self setSearchActive:YES];
    [self setNormalFrameBeforeSearch:[[self containerView] frame]];
    [self setHasNormalFrameBeforeSearch:YES];

    if ([self presentationMode] == KayokoPanelPresentationModeCompactLandscapeFullscreen) {
        UIView *containerView = [self containerView];
        [containerView layoutIfNeeded];
        [activeTableView layoutIfNeeded];
        if ([containerView isKindOfClass:[KayokoMainView class]]) {
            [(KayokoMainView *)containerView setSearchTitleRowCollapsed:YES];
        }
        [UIView animateWithDuration:kKayokoSearchCompactLandscapeTitleRowAnimationDuration
            delay:0
            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                    UIViewAnimationOptionCurveEaseInOut
            animations:^{
              [self revealSearchBarInTableView:activeTableView animated:YES];
              [containerView layoutIfNeeded];
              [activeTableView layoutIfNeeded];
            }
            completion:^(__unused BOOL finished) {
              if (completion) {
                  completion();
              }
            }];
        return;
    }

    [self revealSearchBarInTableView:activeTableView animated:YES];

    UIView *containerView = [self containerView];
    // If the system keyboard is already docked (common when opening search while typing),
    // seed its inset immediately so the card can animate above the keyboard instead of jumping.
    [self seedHostKeyboardBottomInsetFromVisibleKeyboardIfNeeded];

    // Portrait search stays a floating card (IMG_0644). Only reveal the search bar and
    // lift the card above an already-visible keyboard; never go edge-to-edge.
    CGRect targetFrame = [self activeSearchFrame];
    BOOL needsFrameAnimation = !CGRectEqualToRect([containerView frame], targetFrame) ||
                               !CGAffineTransformIsIdentity([containerView transform]);
    if (!needsFrameAnimation) {
        // First open usually keeps the same floating-card frame. Skip a no-op spring that
        // still forces blur/shadow/layout work and feels like a hitch. Defer completion by one
        // turn so the search-bar reveal can start before token bootstrap work runs.
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
        return;
    }

    [UIView animateWithDuration:kKayokoSearchFullscreenAnimationDuration
        delay:0
        usingSpringWithDamping:kKayokoSearchFullscreenAnimationDamping
        initialSpringVelocity:0
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                UIViewAnimationOptionCurveEaseOut
        animations:^{
          [containerView setTransform:CGAffineTransformIdentity];
          [containerView setFrame:targetFrame];
          [containerView setNeedsLayout];
          [containerView layoutIfNeeded];
        }
        completion:^(__unused BOOL finished) {
          if (completion) {
              completion();
          }
        }];
}

- (void)endSearchRestoringFrame:(BOOL)restoresFrame
                activeTableView:(KayokoHistoryListView *)activeTableView
                     completion:(void (^)(void))completion {
    [self endSearchRestoringFrame:restoresFrame activeTableView:activeTableView animations:nil completion:completion];
}

- (void)endSearchRestoringFrame:(BOOL)restoresFrame
                activeTableView:(KayokoHistoryListView *)activeTableView
                     animations:(void (^)(void))animations
                     completion:(void (^)(void))completion {
    [self endSearchRestoringFrame:restoresFrame
                  activeTableView:activeTableView
                       animations:animations
                     panVelocityY:0
                       completion:completion];
}

- (void)endSearchRestoringFrame:(BOOL)restoresFrame
                activeTableView:(KayokoHistoryListView *)activeTableView
                     animations:(void (^)(void))animations
                   panVelocityY:(CGFloat)panVelocityY
                     completion:(void (^)(void))completion {
    [self setSearchActive:NO];
    [self resetKeyboardInsets];

    CGRect targetFrame =
        [self hasNormalFrameBeforeSearch] ? [self normalFrameBeforeSearch] : [[self containerView] frame];
    [self setHasNormalFrameBeforeSearch:NO];

    UIView *containerView = [self containerView];
    [containerView layoutIfNeeded];
    if ([containerView isKindOfClass:[KayokoMainView class]]) {
        KayokoMainView *mainView = (KayokoMainView *)containerView;
        BOOL keepsFullscreenSafeArea = ![self usesPortraitCardSearchPresentation];
        if (!keepsFullscreenSafeArea) {
            [mainView setContentRespectsSafeArea:NO];
            [mainView setContentSafeAreaAdditionalInsets:UIEdgeInsetsZero];
        }
    }

    if ([self presentationMode] == KayokoPanelPresentationModeCompactLandscapeFullscreen) {
        [containerView layoutIfNeeded];
        [activeTableView layoutIfNeeded];
        if ([containerView isKindOfClass:[KayokoMainView class]]) {
            [(KayokoMainView *)containerView setSearchTitleRowCollapsed:NO];
        }
        [self setHasNormalFrameBeforeSearch:NO];
        [UIView animateWithDuration:kKayokoSearchCompactLandscapeTitleRowAnimationDuration
            delay:0
            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                    UIViewAnimationOptionCurveEaseInOut
            animations:^{
              [self hideSearchBarInTableView:activeTableView animated:YES];
              if (animations) {
                  animations();
              }
              [containerView layoutIfNeeded];
              [activeTableView layoutIfNeeded];
            }
            completion:^(__unused BOOL finished) {
              if (completion) {
                  completion();
              }
            }];
        return;
    }

    if (restoresFrame && !CGRectEqualToRect([[self containerView] frame], targetFrame)) {
        NSTimeInterval duration = panVelocityY == 0
                                      ? kKayokoSearchFullscreenAnimationDuration
                                      : [self fullscreenPanAnimationDurationToFrame:targetFrame velocityY:panVelocityY];
        CGFloat initialSpringVelocity = 0;
        CGFloat remainingDistance = fabs(CGRectGetMinY(targetFrame) - CGRectGetMinY([containerView frame]));
        if (panVelocityY != 0 && remainingDistance > 1) {
            initialSpringVelocity = fabs(panVelocityY) / remainingDistance;
        }

        [UIView animateWithDuration:duration
            delay:0
            usingSpringWithDamping:kKayokoSearchFullscreenAnimationDamping
            initialSpringVelocity:initialSpringVelocity
            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
            animations:^{
              [containerView setFrame:targetFrame];
              [containerView setNeedsLayout];
              [containerView layoutIfNeeded];
              [self hideSearchBarInTableView:activeTableView animated:NO];
              if (animations) {
                  animations();
              }
            }
            completion:^(__unused BOOL finished) {
              if (completion) {
                  completion();
              }
            }];
    } else {
        [containerView setFrame:targetFrame];
        [containerView setNeedsLayout];
        [containerView layoutIfNeeded];
        [self hideSearchBarInTableView:activeTableView animated:NO];
        if (animations) {
            animations();
        }
        if (completion) {
            completion();
        }
    }
}

#pragma mark - Fullscreen Pan

- (void)handleFullscreenPanGestureRecognizer:(UIPanGestureRecognizer *)recognizer
                             activeTableView:(KayokoHistoryListView *)activeTableView
                                  headerView:(nullable KayokoHeaderView *)headerView {
    if (![self isSearchActive]) {
        return;
    }

    BOOL beganInHeaderView = headerView != nil;
    UIView *trackingView = [[self containerView] superview] ?: [self containerView];
    CGPoint translation = [recognizer translationInView:trackingView];
    CGFloat progress = [self fullscreenCollapseProgressForTranslation:translation.y];

    if ([recognizer state] == UIGestureRecognizerStateBegan || [recognizer state] == UIGestureRecognizerStateChanged) {
        CGRect fullscreenFrame = [self fullscreenFrame];
        CGRect collapsedFrame = [self collapsedFrame];
        CGRect frame = [self frameFromFullscreenFrame:fullscreenFrame collapsedFrame:collapsedFrame progress:progress];
        UIView *containerView = [self containerView];
        [containerView setTransform:CGAffineTransformIdentity];
        [containerView setFrame:frame];
        [containerView setNeedsLayout];
        [containerView layoutIfNeeded];
        return;
    }

    if ([recognizer state] != UIGestureRecognizerStateEnded) {
        UIView *containerView = [self containerView];
        CGRect fullscreenFrame = [self fullscreenFrame];
        [UIView animateWithDuration:kKayokoSearchFullscreenAnimationDuration
            delay:0
            usingSpringWithDamping:kKayokoSearchFullscreenAnimationDamping
            initialSpringVelocity:0
            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
            animations:^{
              [containerView setFrame:fullscreenFrame];
              [containerView setNeedsLayout];
              [containerView layoutIfNeeded];
            }
            completion:nil];
        return;
    }

    CGPoint velocity = [recognizer velocityInView:trackingView];
    BOOL shouldCollapse =
        translation.y > 0 && ((beganInHeaderView && velocity.y >= kKayokoSearchFullscreenCollapseVelocity) ||
                              progress >= kKayokoSearchFullscreenCollapseProgress);
    if (velocity.y <= kKayokoSearchFullscreenReboundVelocity) {
        shouldCollapse = NO;
    }

    if (shouldCollapse) {
        [[self delegate] searchPresentationController:self didRequestCollapseFromFullscreenPanWithVelocity:velocity.y];
        return;
    }

    UIView *containerView = [self containerView];
    CGRect fullscreenFrame = [self fullscreenFrame];
    NSTimeInterval duration = [self fullscreenPanAnimationDurationToFrame:fullscreenFrame velocityY:velocity.y];
    [UIView animateWithDuration:duration
        delay:0
        usingSpringWithDamping:kKayokoSearchFullscreenAnimationDamping
        initialSpringVelocity:0
        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:^{
          [containerView setFrame:fullscreenFrame];
          [containerView setNeedsLayout];
          [containerView layoutIfNeeded];
        }
        completion:nil];
}

#pragma mark - Bottom Insets

- (CGFloat)hiddenSearchBottomInsetForTableView:(KayokoHistoryListView *)tableView {
    if ([self isSearchActive]) {
        return 0;
    }

    return [tableView minimumBottomInsetForMaintainingHiddenHeaderWithAdditionalContentHeightReduction:0];
}

- (CGFloat)safeAreaBottomInsetForTableView:(KayokoHistoryListView *)tableView {
    UIView *containerView = [self containerView];
    if ([containerView isKindOfClass:[KayokoMainView class]]) {
        return [(KayokoMainView *)containerView safeAreaBottomInsetForContentView:tableView];
    }

    return MAX([tableView safeAreaInsets].bottom, 0);
}

- (void)applyBottomInsetToTableView:(KayokoHistoryListView *)tableView {
    [tableView setContentInsetAdjustmentBehavior:UIScrollViewContentInsetAdjustmentNever];
    [tableView setKeyboardBottomInset:[self keyboardBottomInset]];
    [tableView updateNoSearchResultsPlaceholderLayout];

    UIEdgeInsets contentInset = [tableView contentInset];
    CGFloat keyboardBottomInset = [self keyboardBottomInset];
    CGFloat hiddenSearchBottomInset = [self hiddenSearchBottomInsetForTableView:tableView];
    CGFloat safeAreaBottomInset = [self safeAreaBottomInsetForTableView:tableView];
    CGFloat obscuredBottomInset = MAX(keyboardBottomInset, safeAreaBottomInset);
    contentInset.bottom = MAX(hiddenSearchBottomInset, obscuredBottomInset);
    [tableView setContentInset:contentInset];

    [tableView setAutomaticallyAdjustsScrollIndicatorInsets:NO];
    UIEdgeInsets indicatorInsets = UIEdgeInsetsMake(0, 0, obscuredBottomInset, 0);
    [tableView setVerticalScrollIndicatorInsets:indicatorInsets];
}

- (void)applyBottomInsetsToTableViews {
    [self applyBottomInsetToTableView:[self historyTableView]];
    [self applyBottomInsetToTableView:[self favoritesTableView]];
}

#pragma mark - Keyboard Notifications

- (void)setKeyboardBottomInset:(CGFloat)keyboardBottomInset {
    keyboardBottomInset = MAX(keyboardBottomInset, 0);
    if (_keyboardBottomInset == keyboardBottomInset) {
        return;
    }

    _keyboardBottomInset = keyboardBottomInset;
    [[self delegate] searchPresentationController:self didUpdateKeyboardBottomInset:keyboardBottomInset];
}

- (void)resetKeyboardInsets {
    [self setKeyboardBottomInset:0];
    [self setHostKeyboardBottomInset:0];
    [self applyBottomInsetsToTableViews];
}

- (void)resetAfterSearchStateClearedWithActiveTableView:(KayokoHistoryListView *)activeTableView {
    [self resetAfterSearchStateClearedWithActiveTableView:activeTableView restoresContainerFrame:YES];
}

- (CGRect)resetAfterSearchStateClearedWithActiveTableView:(KayokoHistoryListView *)activeTableView
                                   restoresContainerFrame:(BOOL)restoresContainerFrame {
    [self setSearchActive:NO];
    [self resetKeyboardInsets];

    UIView *containerView = [self containerView];
    CGRect targetFrame = [self hasNormalFrameBeforeSearch] ? [self normalFrameBeforeSearch] : [containerView frame];
    [self setHasNormalFrameBeforeSearch:NO];
    if (restoresContainerFrame) {
        [containerView setFrame:targetFrame];
    }
    [containerView setNeedsLayout];

    if ([containerView isKindOfClass:[KayokoMainView class]]) {
        KayokoMainView *mainView = (KayokoMainView *)containerView;
        BOOL keepsFullscreenSafeArea = ![self usesPortraitCardSearchPresentation];
        [mainView setSearchTitleRowCollapsed:NO];
        [mainView setContentSafeAreaAdditionalInsets:UIEdgeInsetsZero];
        if (!keepsFullscreenSafeArea) {
            [mainView setContentRespectsSafeArea:NO];
        }
    }

    [containerView layoutIfNeeded];
    [self hideSearchBarInTableView:activeTableView animated:NO];
    [activeTableView layoutIfNeeded];
    return targetFrame;
}

- (BOOL)shouldHandleSearchKeyboardNotification:(NSNotification *)notification {
    if (![self isSearchActive]) {
        return NO;
    }

    BOOL isLocal = [notification.userInfo[UIKeyboardIsLocalUserInfoKey] boolValue];
    if (!isLocal) {
        return NO;
    }

    return YES;
}

- (void)updateKeyboardBottomInset:(CGFloat)keyboardBottomInset
    withAnimationParametersFromNotification:(NSNotification *)notification {
    CGFloat hostKeyboardBottomInset = MAX(keyboardBottomInset, 0);
    BOOL usesPortraitCard = [self usesPortraitCardSearchPresentation];
    // Portrait card sits above the keyboard, so list content does not need keyboard padding.
    CGFloat contentKeyboardBottomInset = usesPortraitCard ? 0 : hostKeyboardBottomInset;
    BOOL hostInsetUnchanged = fabs([self hostKeyboardBottomInset] - hostKeyboardBottomInset) <= 0.5;
    BOOL contentInsetUnchanged = fabs([self keyboardBottomInset] - contentKeyboardBottomInset) <= 0.5;
    CGRect targetFrame = usesPortraitCard ? [self portraitSearchFrameForHostKeyboardBottomInset:hostKeyboardBottomInset]
                                          : [[self containerView] frame];
    BOOL frameUnchanged = CGRectEqualToRect([[self containerView] frame], targetFrame);
    if (hostInsetUnchanged && contentInsetUnchanged && frameUnchanged) {
        return;
    }

    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve =
        (UIViewAnimationCurve)[notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    UIViewAnimationOptions options = (UIViewAnimationOptions)(curve << 16) |
                                     UIViewAnimationOptionBeginFromCurrentState |
                                     UIViewAnimationOptionAllowUserInteraction;
    // When the keyboard is already visible, iOS often reports duration 0 for the focus handoff
    // into the search field. Still animate the card lift so it does not hard-jump.
    BOOL needsPortraitFrameAnimation = usesPortraitCard && !frameUnchanged;
    if (needsPortraitFrameAnimation && duration <= 0.01) {
        duration = kKayokoSearchFullscreenAnimationDuration;
        options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                  UIViewAnimationOptionCurveEaseOut;
    }

    void (^updates)(void) = ^{
      [self setHostKeyboardBottomInset:hostKeyboardBottomInset];
      [self setKeyboardBottomInset:contentKeyboardBottomInset];
      if (usesPortraitCard) {
          UIView *containerView = [self containerView];
          [containerView setTransform:CGAffineTransformIdentity];
          [containerView setFrame:targetFrame];
          [containerView setNeedsLayout];
      }
      [self applyBottomInsetsToTableViews];
      [[self containerView] layoutIfNeeded];
    };

    if (duration <= 0) {
        updates();
        return;
    }

    [[self containerView] layoutIfNeeded];
    if (needsPortraitFrameAnimation && duration >= kKayokoSearchFullscreenAnimationDuration - 0.001) {
        [UIView animateWithDuration:duration
                              delay:0
             usingSpringWithDamping:kKayokoSearchFullscreenAnimationDamping
              initialSpringVelocity:0
                            options:options
                         animations:updates
                         completion:nil];
        return;
    }

    [UIView animateWithDuration:duration delay:0 options:options animations:updates completion:nil];
}

- (void)handleKeyboardWillChangeFrameNotification:(NSNotification *)notification {
    if (![self shouldHandleSearchKeyboardNotification:notification]) {
        return;
    }

    CGRect keyboardEndFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    // Measure against the host so portrait can lift the whole card above the keyboard.
    UIView *referenceView = [[self containerView] superview] ?: [self containerView];
    CGRect keyboardFrameInView = [referenceView convertRect:keyboardEndFrame fromView:nil];
    CGFloat keyboardBottomInset = 0;
    if (!CGRectIsNull(keyboardFrameInView) && !CGRectIsEmpty(keyboardFrameInView)) {
        CGFloat referenceBottom = CGRectGetMaxY([referenceView bounds]);
        CGFloat keyboardTop = CGRectGetMinY(keyboardFrameInView);
        if (keyboardTop < referenceBottom - 0.5) {
            keyboardBottomInset = MAX(referenceBottom - keyboardTop, 0);
        }
    }
    [self updateKeyboardBottomInset:keyboardBottomInset withAnimationParametersFromNotification:notification];
}

- (void)handleKeyboardWillHideNotification:(NSNotification *)notification {
    if (![self isSearchActive]) {
        return;
    }

    [self updateKeyboardBottomInset:0 withAnimationParametersFromNotification:notification];
}

@end
