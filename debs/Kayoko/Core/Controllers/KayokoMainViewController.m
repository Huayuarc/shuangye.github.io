//
//  KayokoMainViewController.m
//  Kayoko
//

#import "KayokoMainViewController.h"
#import "KayokoClearConfirmationView.h"
#import "KayokoClearConfirmationViewController.h"
#import "KayokoEmptyStateView.h"
#import "KayokoExternalHideCoordinator.h"
#import "KayokoHeaderButtonStyle.h"
#import "KayokoHeaderView.h"
#import "KayokoHistoryController.h"
#import "KayokoHistoryListView.h"
#import "KayokoHistoryListViewController.h"
#import "KayokoMainView.h"
#import "KayokoNoteEditorView.h"
#import "KayokoNoteEditorViewController.h"
#import "KayokoPanelPresentationController.h"
#import "KayokoPasteboardItem.h"
#import "KayokoPasteboardManager.h"
#import "KayokoPreviewView.h"
#import "KayokoPreviewViewController.h"
#import "KayokoSearchController.h"
#import "KayokoTagChipBarView.h"
#import "KayokoTableViewCell.h"
#import "KayokoTagCatalog.h"
#import "KayokoWordSelectionView.h"
#import "KayokoWordSelectionViewController.h"

#import <QuartzCore/QuartzCore.h>


static CGFloat const kKayokoTransientEdgeBackHorizontalDominance = 1.2;
static CGFloat const kKayokoTransientEdgeBackCompletionProgress = 0.35;
static CGFloat const kKayokoTransientEdgeBackCompletionVelocity = 650;
static NSTimeInterval const kKayokoTransientEdgeBackMinimumAnimationDuration = 0.08;
static NSTimeInterval const kKayokoTransientEdgeBackMaximumAnimationDuration = 0.22;
static NSTimeInterval const kKayokoSearchInputExternalHideSuppressionDuration = 0.75;

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openSensitiveURL:(NSURL *)url withOptions:(NSDictionary *)options error:(NSError **)error;
@end

NS_ASSUME_NONNULL_BEGIN

@interface KayokoMainViewController () <KayokoClearConfirmationViewControllerDelegate, KayokoHistoryControllerDelegate,
                                        KayokoPanelPresentationControllerDelegate, KayokoSearchControllerDelegate,
                                        KayokoHistoryListViewControllerDelegate, KayokoNoteEditorViewControllerDelegate,
                                        KayokoWordSelectionViewControllerDelegate, UIGestureRecognizerDelegate>
#pragma mark - Views

@property(nonatomic, strong) KayokoMainView *mainView;
@property(nonatomic, strong) KayokoEmptyStateView *historyEmptyStateView;
@property(nonatomic, strong) KayokoEmptyStateView *favoritesEmptyStateView;
@property(nonatomic, strong) KayokoEmptyStateView *storageErrorView;

#pragma mark - Child Controllers

@property(nonatomic, strong) KayokoHistoryListViewController *historyListViewController;
@property(nonatomic, strong) KayokoHistoryListViewController *favoritesListViewController;
@property(nonatomic, strong) KayokoClearConfirmationViewController *clearConfirmationViewController;
@property(nonatomic, strong) KayokoPreviewViewController *previewViewController;
@property(nonatomic, strong) KayokoWordSelectionViewController *wordSelectionViewController;
@property(nonatomic, strong) KayokoNoteEditorViewController *noteEditorViewController;

#pragma mark - Coordinators

@property(nonatomic, strong) KayokoHistoryController *historyController;
@property(nonatomic, strong) KayokoPanelPresentationController *panelPresentationController;
@property(nonatomic, strong) KayokoSearchController *searchController;

#pragma mark - State

@property(nonatomic, copy, nullable) NSString *clearConfirmationHistoryKey;
@property(nonatomic, strong, nullable) NSError *storageError;
@property(nonatomic, assign) BOOL preparingToShow;
@property(nonatomic, assign) NSUInteger showRequestIdentifier;
@property(nonatomic, assign, getter=isDismissingPanel) BOOL dismissingPanel;
@property(nonatomic, strong) KayokoExternalHideCoordinator *externalHideCoordinator;

#pragma mark - Transient Content

@property(nonatomic, assign) BOOL restoresSearchFirstResponderAfterTransientContent;
@property(nonatomic, assign) BOOL hasSearchContentOffsetBeforeTransientContent;
@property(nonatomic, assign) CGPoint searchContentOffsetBeforeTransientContent;
@property(nonatomic, weak, nullable) UIView *activeSourceContentView;
@property(nonatomic, strong) UIScreenEdgePanGestureRecognizer *transientEdgeBackGestureRecognizer;
@property(nonatomic, weak, nullable) UIView *interactiveTransientReturnSourceView;
@property(nonatomic, weak, nullable) UIView *interactiveTransientReturnContentView;
@property(nonatomic, assign) BOOL interactiveTransientReturnWasPreview;
@property(nonatomic, assign) BOOL didRestoreSearchDuringInteractiveTransientReturn;

#pragma mark - Note Editing

@property(nonatomic, strong, nullable) KayokoPasteboardItem *noteEditingItem;
@property(nonatomic, copy, nullable) NSString *noteEditingHistoryKey;
@property(nonatomic, weak, nullable) KayokoHistoryListViewController *noteEditingSourceListViewController;
@property(nonatomic, assign) NSUInteger noteEditingRequestIdentifier;
@property(nonatomic, assign) BOOL noteEditingBeganFromSearch;
@property(nonatomic, assign) BOOL noteEditingKeepsSearchHeaderHidden;
@property(nonatomic, assign, getter=isFinishingNoteEditing) BOOL finishingNoteEditing;
@property(nonatomic, assign) CGRect noteEditingOriginalPanelFrame;
@property(nonatomic, assign) NSTimeInterval noteEditingKeyboardAnimationDuration;
@property(nonatomic, assign) UIViewAnimationOptions noteEditingKeyboardAnimationOptions;
@end

NS_ASSUME_NONNULL_END

@implementation KayokoMainViewController

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _itemDetailsMode = kKayokoPreferenceKeyItemDetailsModeDefaultValue;
        _clearButtonMode = kKayokoPreferenceKeyClearButtonModeDefaultValue;
        _kayokoSupportedInterfaceOrientations = UIInterfaceOrientationMaskAll;
        _presentationMode = KayokoPanelPresentationModePortraitDrawer;
        _externalHideCoordinator = [[KayokoExternalHideCoordinator alloc] init];
        _mainView = [[KayokoMainView alloc] initWithFrame:frame];
        [self setView:_mainView];
        _historyListViewController = [[KayokoHistoryListViewController alloc]
            initWithName:[[KayokoPasteboardManager localizationBundle] localizedStringForKey:@"History"
                                                                                       value:nil
                                                                                       table:@"Tweak"]
              historyKey:kKayokoHistoryKeyHistory];
        [_historyListViewController setDelegate:self];
        [self addChildViewController:_historyListViewController];
        [_mainView installContentView:[_historyListViewController tableView] hidden:NO];
        [_historyListViewController didMoveToParentViewController:self];

        _favoritesListViewController = [[KayokoHistoryListViewController alloc]
            initWithName:[[KayokoPasteboardManager localizationBundle] localizedStringForKey:@"Favorites"
                                                                                       value:nil
                                                                                       table:@"Tweak"]
              historyKey:kKayokoHistoryKeyFavorites];
        [_favoritesListViewController setDelegate:self];
        [self addChildViewController:_favoritesListViewController];
        [_mainView installContentView:[_favoritesListViewController tableView] hidden:YES];
        [_favoritesListViewController didMoveToParentViewController:self];

        _historyController =
            [[KayokoHistoryController alloc] initWithHistoryListViewController:_historyListViewController
                                                   favoritesListViewController:_favoritesListViewController];
        [_historyController setDelegate:self];

        __weak typeof(self) weakSelf = self;
        [[[_mainView headerView] historySegmentedControl]
            addTarget:self
               action:@selector(handleHistorySegmentedControlChanged:)
     forControlEvents:UIControlEventValueChanged];
        // Keep leading button available for future actions / transient screens.
        [[[_mainView headerView] leadingButton] setHidden:NO];
        [[[_mainView headerView] leadingButton] setShowsMenuAsPrimaryAction:YES];
        [[[_mainView headerView] trailingButton] addTarget:self
                                                    action:@selector(handleClearButtonPressed)
                                          forControlEvents:UIControlEventTouchUpInside];
        [[[_mainView headerView] titleTapControl] addTarget:self
                                                     action:@selector(handleTitleTapControlPressed)
                                           forControlEvents:UIControlEventTouchUpInside];

        _panelPresentationController = [[KayokoPanelPresentationController alloc] initWithPanelView:_mainView];
        [_panelPresentationController setDelegate:self];

        _clearConfirmationViewController = [[KayokoClearConfirmationViewController alloc] init];
        [_clearConfirmationViewController setDelegate:self];
        [self addChildViewController:_clearConfirmationViewController];
        [_mainView installContentView:[_clearConfirmationViewController confirmationView] hidden:YES];
        [_clearConfirmationViewController didMoveToParentViewController:self];

        _historyEmptyStateView = [[KayokoEmptyStateView alloc] init];
        [_historyEmptyStateView updateWithHistoryKey:kKayokoHistoryKeyHistory];
        [_mainView installContentView:_historyEmptyStateView hidden:YES];

        _favoritesEmptyStateView = [[KayokoEmptyStateView alloc] init];
        [_favoritesEmptyStateView updateWithHistoryKey:kKayokoHistoryKeyFavorites];
        [_mainView installContentView:_favoritesEmptyStateView hidden:YES];

        _storageErrorView = [[KayokoEmptyStateView alloc] init];
        [_mainView installContentView:_storageErrorView hidden:YES];

        _previewViewController = [[KayokoPreviewViewController alloc] init];
        [_previewViewController setHapticFeedbackHandler:^(UIImpactFeedbackStyle style) {
          [[weakSelf panelPresentationController] triggerHapticFeedbackWithStyle:style];
        }];
        [self addChildViewController:_previewViewController];
        KayokoHeaderView *previewHeaderView = [[_previewViewController previewView] headerView];
        [_mainView installFullContentView:[_previewViewController previewView] headerView:previewHeaderView hidden:YES];
        [_panelPresentationController registerHeaderView:previewHeaderView];
        [_previewViewController didMoveToParentViewController:self];
        [[previewHeaderView leadingButton] addTarget:self
                                              action:@selector(handleTransientBackButtonPressed)
                                    forControlEvents:UIControlEventTouchUpInside];
        [[previewHeaderView trailingButton] addTarget:self
                                               action:@selector(handlePreviewActionButtonPressed)
                                     forControlEvents:UIControlEventTouchUpInside];
        [[previewHeaderView titleTapControl] addTarget:self
                                                action:@selector(handleTitleTapControlPressed)
                                      forControlEvents:UIControlEventTouchUpInside];

        _wordSelectionViewController = [[KayokoWordSelectionViewController alloc]
            initWithName:[[KayokoPasteboardManager localizationBundle] localizedStringForKey:@"Preview"
                                                                                       value:nil
                                                                                       table:@"Tweak"]];
        [_wordSelectionViewController setDelegate:self];
        [self addChildViewController:_wordSelectionViewController];
        KayokoHeaderView *wordSelectionHeaderView = [[_wordSelectionViewController wordSelectionView] headerView];
        [_mainView installFullContentView:[_wordSelectionViewController view]
                               headerView:wordSelectionHeaderView
                                   hidden:YES];
        [_panelPresentationController registerHeaderView:wordSelectionHeaderView];
        [_wordSelectionViewController didMoveToParentViewController:self];
        [[wordSelectionHeaderView leadingButton] addTarget:self
                                                    action:@selector(handleTransientBackButtonPressed)
                                          forControlEvents:UIControlEventTouchUpInside];
        [[wordSelectionHeaderView trailingButton] addTarget:self
                                                     action:@selector(handlePreviewActionButtonPressed)
                                           forControlEvents:UIControlEventTouchUpInside];
        [[wordSelectionHeaderView titleTapControl] addTarget:self
                                                      action:@selector(handleTitleTapControlPressed)
                                            forControlEvents:UIControlEventTouchUpInside];

        _searchController =
            [[KayokoSearchController alloc] initWithContainerView:_mainView
                                                       headerView:[_mainView headerView]
                                        historyListViewController:_historyListViewController
                                      favoritesListViewController:_favoritesListViewController
                                             panGestureRecognizer:[_panelPresentationController panGestureRecognizer]];
        [_searchController setDelegate:self];

        _noteEditorViewController = [[KayokoNoteEditorViewController alloc] init];
        [_noteEditorViewController setDelegate:self];
        [self addChildViewController:_noteEditorViewController];
        KayokoNoteEditorView *noteEditorView = (KayokoNoteEditorView *)[_noteEditorViewController view];
        [noteEditorView setHidden:YES];
        // Keep note editor inside rounded chrome clip view so it respects continuous corners.
        [[_mainView chromeClipView] addSubview:noteEditorView];
        [noteEditorView setTranslatesAutoresizingMaskIntoConstraints:NO];
        [NSLayoutConstraint activateConstraints:@[
            [[noteEditorView topAnchor] constraintEqualToAnchor:[[_mainView chromeClipView] topAnchor]],
            [[noteEditorView leadingAnchor] constraintEqualToAnchor:[[_mainView chromeClipView] leadingAnchor]],
            [[noteEditorView trailingAnchor] constraintEqualToAnchor:[[_mainView chromeClipView] trailingAnchor]],
            [[noteEditorView bottomAnchor] constraintEqualToAnchor:[[_mainView chromeClipView] bottomAnchor]]
        ]];
        [_noteEditorViewController didMoveToParentViewController:self];

        _transientEdgeBackGestureRecognizer = [[UIScreenEdgePanGestureRecognizer alloc]
            initWithTarget:self
                    action:@selector(handleTransientEdgeBackGestureRecognizer:)];
        [_transientEdgeBackGestureRecognizer setEdges:UIRectEdgeLeft];
        [_transientEdgeBackGestureRecognizer setDelegate:self];
        [_mainView addGestureRecognizer:_transientEdgeBackGestureRecognizer];

        [[_previewViewController previewView]
            requireImagePanGestureRecognizerToFailGestureRecognizer:_transientEdgeBackGestureRecognizer];
        [[_wordSelectionViewController wordSelectionView]
            requireSelectionGestureRecognizerToFailGestureRecognizer:_transientEdgeBackGestureRecognizer];
    }
    return self;
}

#pragma mark - Configuration

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return [self kayokoSupportedInterfaceOrientations];
}

- (BOOL)isHidden {
    return [[self mainView] isHidden];
}

- (void)setOutsideDismissOverlayView:(UIControl *)outsideDismissOverlayView {
    [[self panelPresentationController] setOutsideDismissOverlayView:outsideDismissOverlayView];
}

- (void)applyUserInterfaceStyle:(UIUserInterfaceStyle)style {
    [self setOverrideUserInterfaceStyle:style];
    [[self view] setOverrideUserInterfaceStyle:style];

    for (UIViewController *childViewController in [self childViewControllers]) {
        [childViewController setOverrideUserInterfaceStyle:style];
        [[childViewController view] setOverrideUserInterfaceStyle:style];
    }

    [[self historyEmptyStateView] setOverrideUserInterfaceStyle:style];
    [[self favoritesEmptyStateView] setOverrideUserInterfaceStyle:style];
    [[self storageErrorView] setOverrideUserInterfaceStyle:style];
}

- (void)setDismissOnOutsideTouch:(BOOL)dismissOnOutsideTouch {
    _dismissOnOutsideTouch = dismissOnOutsideTouch;
    [[self panelPresentationController] setDismissOnOutsideTouch:dismissOnOutsideTouch];
}

- (void)setPreviewLineCount:(NSUInteger)previewLineCount {
    _previewLineCount = previewLineCount;
    [[self historyListViewController] setPreviewLineCount:previewLineCount];
    [[self favoritesListViewController] setPreviewLineCount:previewLineCount];
}

- (void)setItemDetailsMode:(KayokoItemDetailsMode)itemDetailsMode {
    if (itemDetailsMode != kKayokoItemDetailsModeOff && itemDetailsMode != kKayokoItemDetailsModeImagesOnly &&
        itemDetailsMode != kKayokoItemDetailsModeAll) {
        itemDetailsMode = kKayokoPreferenceKeyItemDetailsModeDefaultValue;
    }
    _itemDetailsMode = itemDetailsMode;
    [[self historyListViewController] setItemDetailsMode:itemDetailsMode];
    [[self favoritesListViewController] setItemDetailsMode:itemDetailsMode];
}

- (void)setClearButtonMode:(KayokoClearButtonMode)clearButtonMode {
    if (clearButtonMode != kKayokoClearButtonModeOff && clearButtonMode != kKayokoClearButtonModeHistoryOnly &&
        clearButtonMode != kKayokoClearButtonModeAlways) {
        clearButtonMode = kKayokoPreferenceKeyClearButtonModeDefaultValue;
    }
    _clearButtonMode = clearButtonMode;
    [self updateClearButtonState];
}

- (void)setShouldPlayFeedback:(BOOL)shouldPlayFeedback {
    _shouldPlayFeedback = shouldPlayFeedback;
    [[self panelPresentationController] setShouldPlayFeedback:shouldPlayFeedback];
}


- (void)setPresentationMode:(KayokoPanelPresentationMode)presentationMode {
    _presentationMode = presentationMode;
    [[self panelPresentationController] setPresentationMode:presentationMode];
    [[self searchController] setPresentationMode:presentationMode];
    [[[self noteEditorViewController] noteEditorView]
        setCompactLayout:presentationMode == KayokoPanelPresentationModeCompactLandscapeFullscreen];
    [self applyBasePresentationLayout];
}

- (void)applyBasePresentationLayout {
    if ([self presentationMode] == KayokoPanelPresentationModeCompactLandscapeFullscreen) {
        [[self mainView] setContentSafeAreaAdditionalInsets:UIEdgeInsetsZero];
        [[self mainView] setContentRespectsSafeArea:YES];
        return;
    }

    if (![[self searchController] isSearchActive]) {
        [[self mainView] setContentRespectsSafeArea:NO];
        [[self mainView] setContentSafeAreaAdditionalInsets:UIEdgeInsetsZero];
    }
}


#pragma mark - Layout and Lookup

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self handleViewLayout];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self handleViewLayout];
}

- (void)handleViewLayout {
    [[self searchController] layout];
}

- (NSString *)effectiveActiveHistoryKey {
    return [[self historyController]
        effectiveActiveHistoryKeyWithClearConfirmationHistoryKey:[self clearConfirmationHistoryKey]];
}

- (KayokoHistoryListView *)activeTableView {
    return [[self historyController] activeTableViewWithClearConfirmationHistoryKey:[self clearConfirmationHistoryKey]];
}

- (KayokoHistoryListViewController *)activeListViewController {
    return [[self historyController] listViewControllerForHistoryKey:[self effectiveActiveHistoryKey]];
}

- (KayokoHistoryListViewController *)listViewControllerForHistoryKey:(NSString *)historyKey {
    return [[self historyController] listViewControllerForHistoryKey:historyKey];
}

- (KayokoHistoryListViewController *)activeListViewControllerForSearchController:
    (KayokoSearchController *)searchController {
    (void)searchController;
    return [self activeListViewController];
}

#pragma mark - External Hide Coordinator

- (BOOL)externalHideRequestShouldWaitForAnimations {
    return [self preparingToShow] || [[self mainView] isAnimating] || [[self panelPresentationController] isAnimating];
}

- (void)executePendingExternalHideRequestIfReady {
    if ([[self externalHideCoordinator] shouldSuppressExternalHide] ||
        [self externalHideRequestShouldWaitForAnimations]) {
        return;
    }

    // Never let a queued host hide request yank the card out from under an active search session
    // that still owns the keyboard. Otherwise a host-hide that arrives while the user is (re)focusing
    // the search field would fire once the input suppression window elapses and close the panel.
    // Genuine search-end paths (cancel/x) call this again with search inactive, so a legitimately
    // queued hide still fires then.
    if ([[self searchController] isSearchActive] && [[self searchController] isActiveSearchFirstResponder]) {
        return;
    }

    KayokoExternalHideRequest *request = [[self externalHideCoordinator] takePendingExternalHideRequest];
    if (!request || [self isHidden]) {
        return;
    }

    [self hideWithAnimationStyle:[request animationStyle] completion:[request completion]];
}

- (void)beginSearchInputExternalHideSuppression {
    __weak typeof(self) weakSelf = self;
    [[self externalHideCoordinator]
        beginSearchInputTransitionSuppressionWithDuration:kKayokoSearchInputExternalHideSuppressionDuration
                                        expirationHandler:^{
                                          [weakSelf executePendingExternalHideRequestIfReady];
                                        }];
}

- (void)endSearchInputExternalHideSuppression {
    if (![[self externalHideCoordinator] shouldSuppressExternalHide]) {
        return;
    }

    [[self externalHideCoordinator] endSearchInputTransitionSuppression];
    [self executePendingExternalHideRequestIfReady];
}

- (void)clearExternalHideCoordinator {
    [[self externalHideCoordinator] clear];
}

#pragma mark - KayokoSearchControllerDelegate

- (void)searchControllerWillBeginSearchInputTransition:(KayokoSearchController *)searchController {
    (void)searchController;
    [self beginSearchInputExternalHideSuppression];
}

- (void)searchControllerWillAnimateSearchState:(KayokoSearchController *)searchController {
    (void)searchController;
    [[self mainView] setAnimating:YES];
    [[self panelPresentationController] finishOutsideDismissOverlayShow];
}

- (void)searchControllerDidFinishAnimatingSearchState:(KayokoSearchController *)searchController {
    [[self mainView] setAnimating:NO];
    [[self panelPresentationController] finishOutsideDismissOverlayShow];
    if (![searchController isSearchActive]) {
        [self endSearchInputExternalHideSuppression];
    }
    [self executePendingExternalHideRequestIfReady];
}

- (void)searchController:(KayokoSearchController *)searchController
    didUpdateKeyboardBottomInset:(CGFloat)keyboardBottomInset {
    [[[self clearConfirmationViewController] confirmationView] setKeyboardBottomInset:keyboardBottomInset];
    [[self historyEmptyStateView] setKeyboardBottomInset:keyboardBottomInset];
    [[self favoritesEmptyStateView] setKeyboardBottomInset:keyboardBottomInset];
    [[self storageErrorView] setKeyboardBottomInset:keyboardBottomInset];
    [[[self previewViewController] previewView] setKeyboardBottomInset:keyboardBottomInset];
    [[[self wordSelectionViewController] wordSelectionView] setKeyboardBottomInset:keyboardBottomInset];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == [self transientEdgeBackGestureRecognizer]) {
        return [self canBeginTransientEdgeBackGestureRecognizer:(UIScreenEdgePanGestureRecognizer *)gestureRecognizer];
    }

    return YES;
}

#pragma mark - KayokoPanelPresentationControllerDelegate

- (void)panelPresentationControllerDidRequestDismiss:(KayokoPanelPresentationController *)controller {
    [self hideRestoringFocus];
}

- (void)panelPresentationControllerDidTapGrabberArea:(KayokoPanelPresentationController *)controller {
    if ([[self searchController] isSearchActive]) {
        [[self searchController] cancelSearchWithCompletion:nil];
    } else {
        [[self panelPresentationController] prepareStandardDismissAnimation];
        [self hideRestoringFocus];
    }
}

- (BOOL)panelPresentationControllerShouldHandleFullscreenSearchPan:(KayokoPanelPresentationController *)controller {
    return ![self isNoteEditing] && [self presentationMode] != KayokoPanelPresentationModeCompactLandscapeFullscreen &&
           [[self searchController] isSearchActive];
}

- (BOOL)panelPresentationController:(KayokoPanelPresentationController *)controller
    shouldBeginExpandedPanelPanFromView:(nullable UIView *)view
                               velocity:(CGPoint)velocity {
    (void)controller;
    (void)view;
    (void)velocity;
    if ([self isHidden] || [[self panelPresentationController] isAnimating]) {
        return NO;
    }
    if ([self isNoteEditing]) {
        KayokoNoteEditorView *noteEditorView = [[self noteEditorViewController] noteEditorView];
        if ([view isDescendantOfView:[noteEditorView textField]] ||
            [view isDescendantOfView:[noteEditorView saveButton]] ||
            [view isDescendantOfView:[noteEditorView cancelButton]] ||
            [view isDescendantOfView:[noteEditorView tagChipBarView]]) {
            return NO;
        }
        return [view isDescendantOfView:noteEditorView];
    }
    if ([self isShowingClearConfirmation] || [self isPreviewActive] || [self isWordSelectionActive]) {
        return NO;
    }

    UIView *activeContentView = [self activeHistoryContentView];
    return activeContentView == [[self historyListViewController] tableView] ||
           activeContentView == [[self favoritesListViewController] tableView] ||
           activeContentView == [self historyEmptyStateView] || activeContentView == [self favoritesEmptyStateView] ||
           activeContentView == [self storageErrorView];
}

- (BOOL)isFullscreenSearchActive {
    return [[self searchController] isSearchActive];
}

- (BOOL)shouldSuppressSystemMultitaskingGesture {
    return NO;
}

- (void)panelPresentationController:(KayokoPanelPresentationController *)controller
    handleFullscreenSearchPanGestureRecognizer:(UIPanGestureRecognizer *)recognizer
                                    headerView:(nullable KayokoHeaderView *)headerView {
    [[self searchController] handleFullscreenPanGestureRecognizer:recognizer headerView:headerView];
}

#pragma mark - KayokoHistoryControllerDelegate

- (BOOL)historyControllerIsPanelVisible:(KayokoHistoryController *)controller {
    return ![self isHidden];
}

- (BOOL)historyControllerShouldSuppressVisibleUpdates:(KayokoHistoryController *)controller {
    return [self isDismissingPanel];
}

- (void)historyControllerNeedsVisibleReload:(KayokoHistoryController *)controller {
    [self reload];
}

- (void)historyController:(KayokoHistoryController *)controller
    didUpdateActiveTableView:(KayokoHistoryListView *)tableView {
    [self setStorageError:nil];
    [self updateActiveTableViewState:tableView];
}

- (void)historyController:(KayokoHistoryController *)controller didFailLoadingHistoryWithError:(NSError *)error {
    [self showStorageError:error];
}

- (void)searchController:(KayokoSearchController *)searchController didFailLoadingSearchWithError:(NSError *)error {
    [self showStorageError:error];
}

- (void)handleApplicationMetadataChanged {
    [[self searchController] handleApplicationMetadataChanged];
}

#pragma mark - KayokoHistoryListViewControllerDelegate

- (void)historyListViewControllerDidRequestHide:(KayokoHistoryListViewController *)controller {
    [[self panelPresentationController] prepareStandardDismissAnimation];
    [self hideRestoringFocus];
}

- (void)historyListViewControllerDidRequestHideAfterDirectPaste:(KayokoHistoryListViewController *)controller {
    [[self panelPresentationController] prepareStandardDismissAnimation];
    [self hideAfterDirectPaste];
}

- (void)historyListViewController:(KayokoHistoryListViewController *)controller
         didRequestPreviewForItem:(KayokoPasteboardItem *)item {
    [self showContentForItem:item];
}

- (void)historyListViewController:(KayokoHistoryListViewController *)controller
        didRequestEditNoteForItem:(KayokoPasteboardItem *)item
                 presentationCell:(KayokoTableViewCell *)presentationCell
                       sourceCell:(KayokoTableViewCell *)sourceCell {
    [self beginNoteEditingForItem:item
               listViewController:controller
                 presentationCell:presentationCell
                       sourceCell:sourceCell];
}

- (void)historyListViewControllerDidChangeContentState:(KayokoHistoryListViewController *)controller {
    [self updateContentState];
}

- (void)historyListViewController:(KayokoHistoryListViewController *)controller
            didMoveItemDictionary:(NSDictionary<NSString *, id> *)dictionary
               fromHistoryWithKey:(NSString *)sourceHistoryKey
                 toHistoryWithKey:(NSString *)destinationHistoryKey {
    [self handlePasteboardItemDictionary:dictionary
                     movedFromHistoryKey:sourceHistoryKey
                            toHistoryKey:destinationHistoryKey];
}

#pragma mark - Content Lookup

- (KayokoHistoryListView *)tableViewForHistoryKey:(NSString *)historyKey {
    return [[self historyController] tableViewForHistoryKey:historyKey];
}

- (KayokoEmptyStateView *)emptyStateViewForHistoryKey:(NSString *)historyKey {
    return [historyKey isEqualToString:kKayokoHistoryKeyFavorites] ? [self favoritesEmptyStateView]
                                                                   : [self historyEmptyStateView];
}

- (UIView *)contentViewForHistoryKey:(NSString *)historyKey {

    if ([self storageError]) {
        [[self storageErrorView] updateWithStorageError:[self storageError]];
        [[self storageErrorView] setKeyboardBottomInset:[[self searchController] keyboardBottomInset]];
        return [self storageErrorView];
    }

    KayokoHistoryListViewController *listViewController = [self listViewControllerForHistoryKey:historyKey];
    if ([[listViewController items] count] > 0) {
        return [listViewController tableView];
    }

    KayokoEmptyStateView *emptyStateView = [self emptyStateViewForHistoryKey:historyKey];
    [emptyStateView setKeyboardBottomInset:[[self searchController] keyboardBottomInset]];
    return emptyStateView;
}

- (UIView *)activeHistoryContentView {
    if (![[[self historyListViewController] tableView] isHidden]) {
        return [[self historyListViewController] tableView];
    }

    if (![[[self favoritesListViewController] tableView] isHidden]) {
        return [[self favoritesListViewController] tableView];
    }

    if (![[self historyEmptyStateView] isHidden]) {
        return [self historyEmptyStateView];
    }

    if (![[self favoritesEmptyStateView] isHidden]) {
        return [self favoritesEmptyStateView];
    }

    if (![[self storageErrorView] isHidden]) {
        return [self storageErrorView];
    }

    return [self emptyStateViewForHistoryKey:[self effectiveActiveHistoryKey]];
}

- (NSString *)titleForContentView:(UIView *)view {
    if (view == [[self historyListViewController] tableView] || view == [self historyEmptyStateView]) {
        return [[KayokoPasteboardManager localizationBundle] localizedStringForKey:@"History" value:nil table:@"Tweak"];
    }
    if (view == [[self favoritesListViewController] tableView] || view == [self favoritesEmptyStateView]) {
        return [[KayokoPasteboardManager localizationBundle] localizedStringForKey:@"Favorites" value:nil table:@"Tweak"];
    }
    if (view == [self storageErrorView]) {
        return [[self storageErrorView] name] ?: @"";
    }
    if (view == [[self clearConfirmationViewController] confirmationView]) {
        return [[KayokoPasteboardManager localizationBundle] localizedStringForKey:@"Clear" value:nil table:@"Tweak"]
            ?: @"Clear";
    }
    if (view == [[self previewViewController] previewView]) {
        return [[[self previewViewController] previewView] name] ?: @"";
    }
    if (view == [[self wordSelectionViewController] view] ||
        view == [[self wordSelectionViewController] wordSelectionView]) {
        return [[[self wordSelectionViewController] wordSelectionView].headerView.titleLabel text] ?: @"";
    }
    return [[[[[self mainView] headerView] titleLabel] text] copy] ?: @"";
}


#pragma mark - History Content

- (void)prepareHistoryListForDisplayIfNeededForHistoryKey:(NSString *)historyKey contentView:(UIView *)contentView {
    KayokoHistoryListViewController *listViewController = [self listViewControllerForHistoryKey:historyKey];
    if (contentView != [listViewController tableView] || [[self searchController] isSearchActive] ||
        [listViewController hasActiveSearch]) {
        return;
    }

    if (![[self historyController] consumeScrollToTopBeforeNextDisplayForHistoryKey:historyKey]) {
        return;
    }

    [[listViewController tableView] scrollToFirstItemKeepingSearchHeaderHiddenWithoutAnimation];
}

- (void)setHistoryContentVisibleForKey:(NSString *)historyKey {
    [[self historyController] setActiveHistoryKey:historyKey];
    UIView *contentView = [self contentViewForHistoryKey:historyKey];
    KayokoHistoryListView *tableView = [[self listViewControllerForHistoryKey:historyKey] tableView];
    BOOL preparesListBeforeDisplay = [self isHidden] || [tableView isHidden];
    [[[self historyListViewController] tableView]
        setHidden:contentView != [[self historyListViewController] tableView]];
    [[[self favoritesListViewController] tableView]
        setHidden:contentView != [[self favoritesListViewController] tableView]];
    [[self historyEmptyStateView] setHidden:contentView != [self historyEmptyStateView]];
    [[self favoritesEmptyStateView] setHidden:contentView != [self favoritesEmptyStateView]];
    [[self storageErrorView] setHidden:contentView != [self storageErrorView]];
    [contentView setAlpha:1];
    [contentView setTransform:CGAffineTransformIdentity];

    [self restoreHistoryHeaderIconForHistoryKey:historyKey];
    [[[self mainView] headerView] setHistorySwitcherVisible:YES animated:NO];
    [self updateFavoritesButtonForHistoryKey:historyKey];
    [[[[self mainView] headerView] alternateTrailingButton] setHidden:YES];
    [[[[self mainView] headerView] titleTapControl] setEnabled:NO];
    [[self searchController] attachToListViewController:[self listViewControllerForHistoryKey:historyKey]
                                         hidesSearchBar:![[self searchController] isSearchActive]];
    [[self searchController] refreshForListViewController:[self activeListViewController]];
    if (preparesListBeforeDisplay) {
        [self prepareHistoryListForDisplayIfNeededForHistoryKey:historyKey contentView:contentView];
    }
    [[self mainView] setTitleText:[self titleForContentView:contentView]];
    [self updateClearButtonState];
}

- (void)markHistoryKeyLoaded:(NSString *)historyKey {
    [[self historyController] markHistoryKeyLoaded:historyKey];
}

- (void)markHistoryKeyDirty:(NSString *)historyKey {
    [[self historyController] markHistoryKeyDirty:historyKey];
}

- (void)updateActiveTableViewState:(KayokoHistoryListView *)tableView {
    if (tableView == [self activeTableView]) {
        KayokoHistoryListViewController *activeListViewController = [self activeListViewController];
        // History can change while a transient page is on top (for example an item copied from
        // another device while editing its note). Keep the cached list current, but never let a
        // list-state callback replace the active transient presentation.
        if ([self shouldDeferHistoryPresentationUpdates]) {
            [self updateClearButtonState];
            return;
        }
        if ([self cancelSearchForEmptyActiveHistoryIfNeededHidingView:[self activeHistoryContentView]
                                                            direction:KayokoContentTransitionDirectionForward
                                                           completion:nil]) {
            return;
        }
        if ([[self searchController] isSearchActive] || [activeListViewController hasActiveSearch]) {
            [[self searchController] refreshForListViewController:activeListViewController];
        }
        [self updateClearButtonState];
        if ([self activeHistoryContentView] != [self contentViewForHistoryKey:[self effectiveActiveHistoryKey]]) {
            [self updateContentState];
        }
    }
}

- (void)handleHistoryChanged {
    [[self historyController] handleHistoryChanged];
}

- (nullable NSString *)historyKeyForInitialViewMode {
    switch ([self initialViewMode]) {
    case kKayokoInitialViewModeFavorites:
        return kKayokoHistoryKeyFavorites;
    case kKayokoInitialViewModeHistory:
        return kKayokoHistoryKeyHistory;
    case kKayokoInitialViewModePreviousSelection:
        return nil;
    }
    return nil;
}

- (void)reloadTableViewForHistoryKey:(NSString *)historyKey
              animatingTopInsertions:(BOOL)animatingTopInsertions
                          completion:(void (^)(KayokoHistoryListView *tableView))completion {
    [[self historyController] reloadTableViewForHistoryKey:historyKey
                                    animatingTopInsertions:animatingTopInsertions
                                                completion:completion];
}

- (void)reloadTableViewForHistoryKey:(NSString *)historyKey
                          completion:(void (^)(KayokoHistoryListView *tableView))completion {
    [[self historyController] reloadTableViewForHistoryKey:historyKey completion:completion];
}

#pragma mark - Clear Confirmation

- (void)showClearConfirmationForHistoryKey:(NSString *)historyKey {
    [self showClearConfirmationForHistoryKey:historyKey imagesOnly:NO];
}

- (void)showClearConfirmationForHistoryKey:(NSString *)historyKey imagesOnly:(BOOL)imagesOnly {
    [[self historyController] setActiveHistoryKey:historyKey];
    [self setClearConfirmationHistoryKey:historyKey];
    [[self clearConfirmationViewController] beginWithHistoryKey:historyKey imagesOnly:imagesOnly];
    [[[self clearConfirmationViewController] confirmationView]
        setKeyboardBottomInset:[[self searchController] keyboardBottomInset]];
    [[[[self mainView] headerView] trailingButton] setHidden:YES];

    [[self mainView]
        showContentView:[[self clearConfirmationViewController] confirmationView]
        hideContentView:[self activeHistoryContentView]
                  title:[self titleForContentView:[[self clearConfirmationViewController] confirmationView]]
              direction:KayokoContentTransitionDirectionModalPresenting];
}

- (void)finishHidingClearConfirmationForHistoryKey:(NSString *)historyKey {
    [self setClearConfirmationHistoryKey:nil];
    [self updateClearButtonState];
    UIView *contentView = [self contentViewForHistoryKey:historyKey];
    [self prepareHistoryListForDisplayIfNeededForHistoryKey:historyKey contentView:contentView];
    [[self mainView] showContentView:contentView
                     hideContentView:[[self clearConfirmationViewController] confirmationView]
                               title:[self titleForContentView:contentView]
                           direction:KayokoContentTransitionDirectionModalDismissing];
}

- (void)hideClearConfirmationWithReload:(BOOL)reload {
    [[[self mainView] headerView] setHistorySwitcherVisible:YES animated:NO];
    [self updateFavoritesButtonForHistoryKey:[self effectiveActiveHistoryKey]];
    if ([[[self clearConfirmationViewController] confirmationView] isHidden] || ![self clearConfirmationHistoryKey]) {
        return;
    }

    NSString *historyKey = [self clearConfirmationHistoryKey];
    if (reload) {
        BOOL imagesOnly = [[self clearConfirmationViewController] isImagesOnly];
        if (imagesOnly) {
            // Only image rows were removed; text entries remain, so reload from disk instead of
            // wiping the whole list.
            [self markHistoryKeyDirty:historyKey];
        } else {
            [[self listViewControllerForHistoryKey:historyKey] clearItems];
            [self markHistoryKeyLoaded:historyKey];
        }
        if ([[self effectiveActiveHistoryKey] isEqualToString:historyKey]) {
            [self setClearConfirmationHistoryKey:nil];
            [self updateClearButtonState];
            if (!imagesOnly &&
                [self cancelSearchForEmptyActiveHistoryIfNeededHidingView:[[self clearConfirmationViewController]
                                                                              confirmationView]
                                                                direction:KayokoContentTransitionDirectionModalDismissing
                                                               completion:nil]) {
                return;
            }
            if (imagesOnly) {
                [self reloadTableViewForHistoryKey:historyKey
                            animatingTopInsertions:NO
                                        completion:^(KayokoHistoryListView *tableView) {
                                          (void)tableView;
                                        }];
            }
            [[self searchController] refreshForListViewController:[self activeListViewController]];
        }
    }
    [self finishHidingClearConfirmationForHistoryKey:historyKey];
}

- (void)resetClearConfirmationIfNeeded {
    if (![self clearConfirmationHistoryKey]) {
        return;
    }

    [[[self clearConfirmationViewController] confirmationView] setHidden:YES];
    [[[self clearConfirmationViewController] confirmationView] setAlpha:1];
    [[[self clearConfirmationViewController] confirmationView] setTransform:CGAffineTransformIdentity];
    [self setHistoryContentVisibleForKey:[self clearConfirmationHistoryKey]];
    [self setClearConfirmationHistoryKey:nil];
    [self updateClearButtonState];
}

- (BOOL)isShowingClearConfirmation {
    return [self clearConfirmationHistoryKey] && ![[[self clearConfirmationViewController] confirmationView] isHidden];
}

#pragma mark - Content State

- (void)updateClearButtonState {
    // Clear actions now live inside the leading button's menu, so the trailing trash button
    // is always hidden on the main list header.
    [[[[self mainView] headerView] trailingButton] setHidden:YES];
    NSUInteger itemCount = [self storageError] ? 0 : [[[self activeListViewController] items] count];
    [[self mainView] setClearButtonEnabledForItemCount:itemCount];
}

- (void)showStorageError:(NSError *)error {
    if (!error) {
        return;
    }

    [self setStorageError:error];
    [[self storageErrorView] updateWithStorageError:error];
    [[self storageErrorView] setKeyboardBottomInset:[[self searchController] keyboardBottomInset]];
    [self updateClearButtonState];

    if ([self isHidden]) {
        return;
    }

    UIView *viewToHide = [self activeHistoryContentView];
    UIView *viewToShow = [self storageErrorView];
    if (viewToHide == viewToShow) {
        [[self mainView] setTitleText:[self titleForContentView:viewToShow]];
        return;
    }
    [[self mainView] showContentView:viewToShow
                     hideContentView:viewToHide
                               title:[self titleForContentView:viewToShow]
                           direction:KayokoContentTransitionDirectionForward];
}

#pragma mark - Transient Content

- (BOOL)isNoteEditing {
    return [self noteEditingItem] != nil || ![[[self noteEditorViewController] noteEditorView] isHidden];
}

- (BOOL)isPreviewActive {
    return ![[[self previewViewController] previewView] isHidden] || [[self previewViewController] previewItem] != nil;
}

- (BOOL)isWordSelectionActive {
    return ![[[self wordSelectionViewController] view] isHidden] ||
           [[self wordSelectionViewController] sourceItem] != nil;
}

- (UIView *)activeTransientContentViewForEdgeBackGesture {
    KayokoPreviewView *previewView = [[self previewViewController] previewView];
    if (![previewView isHidden] && [[self previewViewController] previewItem]) {
        return previewView;
    }

    UIView *wordSelectionView = [[self wordSelectionViewController] view];
    if (![wordSelectionView isHidden] && [[self wordSelectionViewController] sourceItem]) {
        return wordSelectionView;
    }

    return nil;
}

- (BOOL)canBeginTransientEdgeBackGestureRecognizer:(UIScreenEdgePanGestureRecognizer *)recognizer {
    if ([self isHidden] || [[self mainView] isAnimating] || [[self panelPresentationController] isAnimating]) {
        return NO;
    }

    UIView *sourceView = [self activeSourceContentView];
    UIView *contentView = [self activeTransientContentViewForEdgeBackGesture];
    if (!sourceView || !contentView) {
        return NO;
    }

    CGPoint velocity = [recognizer velocityInView:[self mainView]];
    if (velocity.x <= 0 || fabs(velocity.x) <= fabs(velocity.y) * kKayokoTransientEdgeBackHorizontalDominance) {
        return NO;
    }

    if (contentView == [[self previewViewController] previewView] &&
        ![[[self previewViewController] previewView] canBeginEdgeBackGesture]) {
        return NO;
    }

    return YES;
}

- (CGFloat)progressForTransientEdgeBackGestureRecognizer:(UIScreenEdgePanGestureRecognizer *)recognizer {
    CGFloat width = MAX(CGRectGetWidth([[[self mainView] contentContainerView] bounds]), 1);
    CGFloat progress = [recognizer translationInView:[self mainView]].x / width;
    return MIN(MAX(progress, 0), 1);
}

- (NSTimeInterval)transientEdgeBackAnimationDurationWithProgress:(CGFloat)progress finishing:(BOOL)finishing {
    CGFloat remainingProgress = finishing ? 1 - progress : progress;
    NSTimeInterval duration = kKayokoTransientEdgeBackMaximumAnimationDuration * remainingProgress;
    return MIN(MAX(duration, kKayokoTransientEdgeBackMinimumAnimationDuration),
               kKayokoTransientEdgeBackMaximumAnimationDuration);
}

- (void)resetInteractiveTransientReturnState {
    [self setInteractiveTransientReturnSourceView:nil];
    [self setInteractiveTransientReturnContentView:nil];
    [self setInteractiveTransientReturnWasPreview:NO];
    [self setDidRestoreSearchDuringInteractiveTransientReturn:NO];
}

- (void)clearSearchAfterTransientContentState {
    [self setRestoresSearchFirstResponderAfterTransientContent:NO];
    [self setHasSearchContentOffsetBeforeTransientContent:NO];
}

- (BOOL)restoreSearchAfterTransientContentIfNeededClearingState:(BOOL)clearsState {
    BOOL didRestore = NO;
    if ([[self searchController] isSearchActive]) {
        CGPoint targetContentOffset = [[[self activeListViewController] tableView] contentOffset];
        if ([self hasSearchContentOffsetBeforeTransientContent]) {
            targetContentOffset = [self searchContentOffsetBeforeTransientContent];
        }
        [[self searchController]
            refreshAfterTransientContentForListViewController:[self activeListViewController]
                                       restoresFirstResponder:[self restoresSearchFirstResponderAfterTransientContent]
                                          targetContentOffset:targetContentOffset];
        didRestore = YES;
    }

    if (clearsState) {
        [self clearSearchAfterTransientContentState];
    }
    return didRestore;
}

- (void)beginInteractiveTransientReturnWithGestureRecognizer:(UIScreenEdgePanGestureRecognizer *)recognizer {
    UIView *sourceView = [self activeSourceContentView];
    UIView *contentView = [self activeTransientContentViewForEdgeBackGesture];
    if (!sourceView || !contentView) {
        return;
    }

    CGFloat progress = [self progressForTransientEdgeBackGestureRecognizer:recognizer];
    UIView *mainHeaderView = [[self mainView] headerView];

    [self setInteractiveTransientReturnSourceView:sourceView];
    [self setInteractiveTransientReturnContentView:contentView];
    [self setInteractiveTransientReturnWasPreview:(contentView == [[self previewViewController] previewView])];
    [[self mainView] beginInteractiveBackwardContentTransitionToView:sourceView
                                                 alongsideViewToShow:mainHeaderView
                                                     hideContentView:contentView];
    [[self mainView] updateInteractiveBackwardContentTransitionToView:sourceView
                                                  alongsideViewToShow:mainHeaderView
                                                      hideContentView:contentView
                                                             progress:progress];
    [self setDidRestoreSearchDuringInteractiveTransientReturn:
              [self restoreSearchAfterTransientContentIfNeededClearingState:NO]];
}

- (void)updateInteractiveTransientReturnWithGestureRecognizer:(UIScreenEdgePanGestureRecognizer *)recognizer {
    UIView *sourceView = [self interactiveTransientReturnSourceView];
    UIView *contentView = [self interactiveTransientReturnContentView];
    if (!sourceView || !contentView) {
        return;
    }

    CGFloat progress = [self progressForTransientEdgeBackGestureRecognizer:recognizer];
    [[self mainView] updateInteractiveBackwardContentTransitionToView:sourceView
                                                  alongsideViewToShow:[[self mainView] headerView]
                                                      hideContentView:contentView
                                                             progress:progress];
}

- (void)finishInteractiveTransientReturnWithDuration:(NSTimeInterval)duration {
    UIView *sourceView = [self interactiveTransientReturnSourceView];
    UIView *contentView = [self interactiveTransientReturnContentView];
    if (!sourceView || !contentView) {
        [self resetInteractiveTransientReturnState];
        return;
    }

    BOOL wasPreview = [self interactiveTransientReturnWasPreview];
    BOOL didRestoreSearch = [self didRestoreSearchDuringInteractiveTransientReturn];
    if (didRestoreSearch) {
        [self clearSearchAfterTransientContentState];
    }
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleSoft];
    UIView *mainHeaderView = [[self mainView] headerView];

    [[self mainView] finishInteractiveBackwardContentTransitionToView:sourceView
        alongsideViewToShow:mainHeaderView
        hideContentView:contentView
        duration:duration
        alongsideAnimations:^{
          if (!didRestoreSearch) {
              [self restoreSearchAfterTransientContentIfNeededClearingState:YES];
          }
        }
        completion:^{
          if (wasPreview) {
              [[self previewViewController] hidePreview];
          } else {
              [[self wordSelectionViewController] hideWordSelection];
          }
          [self setActiveSourceContentView:nil];
          [self resetInteractiveTransientReturnState];
        }];
}

- (void)cancelInteractiveTransientReturnWithDuration:(NSTimeInterval)duration {
    UIView *sourceView = [self interactiveTransientReturnSourceView];
    UIView *contentView = [self interactiveTransientReturnContentView];
    if (!sourceView || !contentView) {
        [self resetInteractiveTransientReturnState];
        return;
    }

    if ([self didRestoreSearchDuringInteractiveTransientReturn]) {
        [[self searchController] resignSearchFirstResponder];
    }

    [[self mainView] cancelInteractiveBackwardContentTransitionToView:sourceView
                                                  alongsideViewToShow:[[self mainView] headerView]
                                                      hideContentView:contentView
                                                             duration:duration
                                                           completion:^{
                                                             [self resetInteractiveTransientReturnState];
                                                           }];
}

- (void)finishOrCancelInteractiveTransientReturnWithGestureRecognizer:(UIScreenEdgePanGestureRecognizer *)recognizer {
    if ([recognizer state] == UIGestureRecognizerStateCancelled ||
        [recognizer state] == UIGestureRecognizerStateFailed) {
        CGFloat progress = [self progressForTransientEdgeBackGestureRecognizer:recognizer];
        [self cancelInteractiveTransientReturnWithDuration:[self transientEdgeBackAnimationDurationWithProgress:progress
                                                                                                      finishing:NO]];
        return;
    }

    CGFloat progress = [self progressForTransientEdgeBackGestureRecognizer:recognizer];
    CGPoint velocity = [recognizer velocityInView:[self mainView]];
    BOOL shouldFinish = progress >= kKayokoTransientEdgeBackCompletionProgress ||
                        velocity.x >= kKayokoTransientEdgeBackCompletionVelocity;
    NSTimeInterval duration = [self transientEdgeBackAnimationDurationWithProgress:progress finishing:shouldFinish];
    if (shouldFinish) {
        [self finishInteractiveTransientReturnWithDuration:duration];
    } else {
        [self cancelInteractiveTransientReturnWithDuration:duration];
    }
}

- (void)handleTransientEdgeBackGestureRecognizer:(UIScreenEdgePanGestureRecognizer *)recognizer {
    switch ([recognizer state]) {
    case UIGestureRecognizerStateBegan:
        [self beginInteractiveTransientReturnWithGestureRecognizer:recognizer];
        break;
    case UIGestureRecognizerStateChanged:
        [self updateInteractiveTransientReturnWithGestureRecognizer:recognizer];
        break;
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
    case UIGestureRecognizerStateFailed:
        [self finishOrCancelInteractiveTransientReturnWithGestureRecognizer:recognizer];
        break;
    default:
        break;
    }
}

- (void)restoreActiveSourceContentView {
    UIView *sourceContentView = [self activeSourceContentView];
    if (!sourceContentView) {
        return;
    }

    [sourceContentView setHidden:NO];
    [sourceContentView setAlpha:1];
    [sourceContentView setTransform:CGAffineTransformIdentity];
}

- (void)refreshSearchAfterEndingTransientContentIfNeeded {
    [self restoreSearchAfterTransientContentIfNeededClearingState:YES];
}

#pragma mark - Header State

- (void)updateFavoritesButtonForHistoryKey:(NSString *)historyKey {
    BOOL showingFavorites = [historyKey isEqualToString:kKayokoHistoryKeyFavorites];
    KayokoHeaderView *headerView = [[self mainView] headerView];
    [headerView setHistorySwitcherVisible:YES animated:NO];
    [headerView setSelectedHistorySegmentIndex:showingFavorites ? 1 : 0];
    // Reference UI: left utility button + pin/trash on the right.
    [headerView updateStyleForButton:[headerView leadingButton]
                       withImageName:@"list.bullet"
                           imageSize:kKayokoFavoritesButtonImageSize
                           tintColor:[UIColor labelColor]];
    [self updateFavoritesFilterMenuForHistoryKey:historyKey];
}

- (void)updateFavoritesFilterMenuForHistoryKey:(NSString *)historyKey {
    UIButton *leadingButton = [[[self mainView] headerView] leadingButton];
    [leadingButton setShowsMenuAsPrimaryAction:YES];
    if ([historyKey isEqualToString:kKayokoHistoryKeyFavorites]) {
        [leadingButton setMenu:[self favoritesFilterMenu]];
    } else {
        [leadingButton setMenu:[self clipboardClearMenu]];
    }
}

- (UIMenu *)favoritesFilterMenu {
    NSBundle *bundle = [KayokoPasteboardManager localizationBundle];
    KayokoSearchController *searchController = [self searchController];
    __weak typeof(self) weakSelf = self;

    UIAction *(^makeAction)(NSString *, BOOL, void (^)(KayokoSearchController *, BOOL)) =
        ^UIAction *(NSString *title, BOOL enabled, void (^apply)(KayokoSearchController *, BOOL)) {
          UIImage *image = [UIImage systemImageNamed:enabled ? @"eye" : @"eye.slash"];
          return [UIAction actionWithTitle:title
                                     image:image
                                identifier:nil
                                   handler:^(__kindof UIAction *_Nonnull unusedAction) {
                                     (void)unusedAction;
                                     __strong typeof(weakSelf) strongSelf = weakSelf;
                                     if (!strongSelf) {
                                         return;
                                     }
                                     apply([strongSelf searchController], !enabled);
                                     [strongSelf updateFavoritesFilterMenuForHistoryKey:
                                                     [strongSelf effectiveActiveHistoryKey]];
                                   }];
        };

    UIAction *categories = makeAction(
        [bundle localizedStringForKey:@"Categories" value:nil table:@"Tweak"],
        [searchController favoritesFilterShowsCategories],
        ^(KayokoSearchController *controller, BOOL value) { [controller setFavoritesFilterShowsCategories:value]; });
    UIAction *tags = makeAction(
        [bundle localizedStringForKey:@"Tags" value:nil table:@"Tweak"],
        [searchController favoritesFilterShowsTags],
        ^(KayokoSearchController *controller, BOOL value) { [controller setFavoritesFilterShowsTags:value]; });
    UIAction *apps = makeAction(
        [bundle localizedStringForKey:@"Applications" value:nil table:@"Tweak"],
        [searchController favoritesFilterShowsApps],
        ^(KayokoSearchController *controller, BOOL value) { [controller setFavoritesFilterShowsApps:value]; });

    return [UIMenu menuWithTitle:@"" children:@[ categories, tags, apps ]];
}

- (UIMenu *)clipboardClearMenu {
    NSBundle *bundle = [KayokoPasteboardManager localizationBundle];
    __weak typeof(self) weakSelf = self;

    UIAction *clearClipboard =
        [UIAction actionWithTitle:[bundle localizedStringForKey:@"Clear Clipboard" value:nil table:@"Tweak"]
                            image:[UIImage systemImageNamed:@"trash"]
                       identifier:nil
                          handler:^(__kindof UIAction *_Nonnull unusedAction) {
                            (void)unusedAction;
                            [weakSelf requestClearClipboardImagesOnly:NO];
                          }];
    [clearClipboard setAttributes:UIMenuElementAttributesDestructive];

    UIAction *clearImages =
        [UIAction actionWithTitle:[bundle localizedStringForKey:@"Clear Images" value:nil table:@"Tweak"]
                            image:[UIImage systemImageNamed:@"photo"]
                       identifier:nil
                          handler:^(__kindof UIAction *_Nonnull unusedAction) {
                            (void)unusedAction;
                            [weakSelf requestClearClipboardImagesOnly:YES];
                          }];

    return [UIMenu menuWithTitle:@"" children:@[ clearClipboard, clearImages ]];
}

- (void)requestClearClipboardImagesOnly:(BOOL)imagesOnly {
    if ([[self panelPresentationController] isAnimating] || ![[[self previewViewController] previewView] isHidden] ||
        ![[[self wordSelectionViewController] view] isHidden] || [self isShowingClearConfirmation]) {
        return;
    }
    [self showClearConfirmationForHistoryKey:kKayokoHistoryKeyHistory imagesOnly:imagesOnly];
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleMedium];
}

- (void)dismissLeadingButtonMenu {
    // Best-effort dismissal of the native UIButton menu when the panel hides. -dismissMenu is
    // iOS 16+, so call it via the runtime to keep building against older SDKs.
    UIButton *leadingButton = [[[self mainView] headerView] leadingButton];
    SEL dismissMenuSelector = NSSelectorFromString(@"dismissMenu");
    if ([leadingButton respondsToSelector:dismissMenuSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [leadingButton performSelector:dismissMenuSelector];
#pragma clang diagnostic pop
    }
}


- (void)restoreHistoryHeaderIconForHistoryKey:(NSString *)historyKey {
    UIButton *favoritesButton = [[[self mainView] headerView] leadingButton];
    [favoritesButton setHidden:NO];
    [favoritesButton setEnabled:YES];
    [favoritesButton setUserInteractionEnabled:YES];
    [[[favoritesButton imageView] layer] setCornerRadius:0];
    [[favoritesButton imageView] setClipsToBounds:NO];
    [self updateFavoritesButtonForHistoryKey:historyKey];
}

#pragma mark - Content Presentation

- (void)showContentView:(UIView *)viewToShow
        hideContentView:(UIView *)viewToHide
              direction:(KayokoContentTransitionDirection)direction
             completion:(nullable void (^)(void))completion {
    [[self mainView] showContentView:viewToShow
                     hideContentView:viewToHide
                               title:[self titleForContentView:viewToShow]
                           direction:direction
                          completion:completion];
}

- (BOOL)cancelSearchForEmptyActiveHistoryIfNeededHidingView:(UIView *)viewToHide
                                                  direction:(KayokoContentTransitionDirection)direction
                                                 completion:(void (^)(void))completion {
    if (![[self searchController] isSearchActive] || [[[self activeListViewController] items] count] > 0) {
        return NO;
    }

    [self updateClearButtonState];
    UIView *viewToShow = [self contentViewForHistoryKey:[self effectiveActiveHistoryKey]];
    if (viewToShow == viewToHide) {
        [[self searchController] cancelSearchWithCompletion:completion];
        return YES;
    }

    [[self mainView] prepareContentTransitionToView:viewToShow
                                    hideContentView:viewToHide
                                              title:[self titleForContentView:viewToShow]
                                          direction:direction];
    [[self searchController]
        cancelSearchWithAnimations:^{
          [[self mainView] applyPreparedContentTransitionToView:viewToShow
                                                hideContentView:viewToHide
                                                      direction:direction];
        }
        completion:^{
          [[self mainView] completePreparedContentTransitionHidingView:viewToHide completion:completion];
        }];
    return YES;
}

- (void)updateContentState {

    if (![self shouldDeferHistoryPresentationUpdates]) {
        if ([self cancelSearchForEmptyActiveHistoryIfNeededHidingView:[self activeHistoryContentView]
                                                            direction:KayokoContentTransitionDirectionForward
                                                           completion:nil]) {
            return;
        }

        UIView *viewToHide = [self activeHistoryContentView];
        UIView *viewToShow = [self contentViewForHistoryKey:[self effectiveActiveHistoryKey]];

        if (viewToShow != viewToHide) {
            [self prepareHistoryListForDisplayIfNeededForHistoryKey:[self effectiveActiveHistoryKey]
                                                        contentView:viewToShow];
            [[self mainView] showContentView:viewToShow
                             hideContentView:viewToHide
                                       title:[self titleForContentView:viewToShow]
                                   direction:KayokoContentTransitionDirectionForward];
        } else {
            [[self mainView] setTitleText:[self titleForContentView:viewToShow]];
        }
    }

    [self updateClearButtonState];
}

- (BOOL)shouldDeferHistoryPresentationUpdates {
    return [self isNoteEditing] || [self isShowingClearConfirmation] || [self isPreviewActive] ||
           [self isWordSelectionActive];
}


#pragma mark - Actions

- (void)handleHistorySegmentedControlChanged:(UISegmentedControl *)sender {
    if (!sender) {
        return;
    }

    BOOL wantsFavorites = [sender selectedSegmentIndex] == 1;
    NSString *targetKey = wantsFavorites ? kKayokoHistoryKeyFavorites : kKayokoHistoryKeyHistory;
    NSString *currentKey = [self effectiveActiveHistoryKey];
    if ([currentKey isEqualToString:targetKey]) {
        [self updateFavoritesButtonForHistoryKey:currentKey];
        return;
    }

    if ([[self panelPresentationController] isAnimating]) {
        // Keep control visually in sync with the currently visible page.
        [self updateFavoritesButtonForHistoryKey:currentKey];
        return;
    }

    [self switchToHistoryKey:targetKey animated:YES];
}

- (void)switchToHistoryKey:(NSString *)targetKey animated:(BOOL)animated {
    if ([targetKey length] == 0) {
        return;
    }
    if ([[self panelPresentationController] isAnimating]) {
        [self updateFavoritesButtonForHistoryKey:[self effectiveActiveHistoryKey]];
        return;
    }
    // Instantly drop confirmation UI; do not start a competing transition animation.
    if ([self isShowingClearConfirmation]) {
        [self resetClearConfirmationIfNeeded];
    }

    NSString *historyKey = [self effectiveActiveHistoryKey];
    if ([historyKey isEqualToString:targetKey]) {
        [self updateFavoritesButtonForHistoryKey:targetKey];
        return;
    }

    BOOL targetIsFavorites = [targetKey isEqualToString:kKayokoHistoryKeyFavorites];
    UIView *viewToHide = [self activeHistoryContentView];
    KayokoContentTransitionDirection direction =
        animated ? (targetIsFavorites ? KayokoContentTransitionDirectionSiblingForward
                                      : KayokoContentTransitionDirectionSiblingBackward)
                 : KayokoContentTransitionDirectionForward;

    __weak typeof(self) weakSelf = self;
    [self reloadTableViewForHistoryKey:targetKey
                            completion:^(KayokoHistoryListView *targetTableView) {
                              __strong typeof(weakSelf) strongSelf = weakSelf;
                              (void)targetTableView;
                              if (!strongSelf) {
                                  return;
                              }
                              // Bail out if the visible page changed while reloading.
                              if (![[strongSelf effectiveActiveHistoryKey] isEqualToString:historyKey] ||
                                  [[strongSelf panelPresentationController] isAnimating]) {
                                  [strongSelf updateFavoritesButtonForHistoryKey:[strongSelf effectiveActiveHistoryKey]];
                                  return;
                              }

                              [[strongSelf historyController] setActiveHistoryKey:targetKey];
                              [[strongSelf searchController]
                                  attachToListViewController:[strongSelf listViewControllerForHistoryKey:targetKey]
                                              hidesSearchBar:![[strongSelf searchController] isSearchActive]];
                              [[strongSelf searchController]
                                  refreshForListViewController:[strongSelf activeListViewController]];
                              [strongSelf updateClearButtonState];

                              UIView *viewToShow = [strongSelf contentViewForHistoryKey:targetKey];
                              [strongSelf prepareHistoryListForDisplayIfNeededForHistoryKey:targetKey
                                                                                contentView:viewToShow];
                              if (viewToShow != viewToHide) {
                                  [[strongSelf mainView] showContentView:viewToShow
                                                         hideContentView:viewToHide
                                                                   title:[strongSelf titleForContentView:viewToShow]
                                                               direction:direction];
                              } else {
                                  [[strongSelf mainView] setTitleText:[strongSelf titleForContentView:viewToShow]];
                              }

                              [strongSelf updateFavoritesButtonForHistoryKey:targetKey];
                              [[strongSelf panelPresentationController]
                                  triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleSoft];
                            }];
}

- (void)handleFavoritesButtonPressed {

    if ([[self panelPresentationController] isAnimating]) {
        return;
    }

    if ([self isShowingClearConfirmation]) {
        [self hideClearConfirmationWithReload:NO];
        [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleSoft];
        return;
    }

    NSString *historyKey = [self effectiveActiveHistoryKey];
    BOOL showingFavorites = [historyKey isEqualToString:kKayokoHistoryKeyFavorites];
    NSString *targetKey = showingFavorites ? kKayokoHistoryKeyHistory : kKayokoHistoryKeyFavorites;
    [self switchToHistoryKey:targetKey animated:YES];
}

- (void)handleTransientBackButtonPressed {

    if ([[self panelPresentationController] isAnimating]) {
        return;
    }

    if (![[[self previewViewController] previewView] isHidden]) {
        [self hidePreview];
        [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleSoft];
        return;
    }

    if (![[[self wordSelectionViewController] view] isHidden]) {
        [self hideWordSelection];
        [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleSoft];
    }
}

- (void)handlePreviewActionButtonPressed {
    if (![[[self wordSelectionViewController] view] isHidden]) {
        [[self wordSelectionViewController] handleActionButtonWithAutomaticallyPaste:[self automaticallyPaste]];
        return;
    }

    if (![[[self previewViewController] previewView] isHidden]) {
        [[self previewViewController] handleActionButtonWithCompletion:^(BOOL success) {
          if (success) {
              [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleMedium];
              [[self panelPresentationController] prepareStandardDismissAnimation];
              [self hideAfterDirectPaste];
          }
        }];
    }
}

- (void)handleClearButtonPressed {
    if ([[self panelPresentationController] isAnimating] || ![[[self previewViewController] previewView] isHidden] ||
        ![[[self wordSelectionViewController] view] isHidden] || [self isShowingClearConfirmation] ||
        NO) {
        return;
    }

    [self showClearConfirmationForHistoryKey:[self effectiveActiveHistoryKey]];
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleMedium];
}

- (void)handleTitleTapControlPressed {
    if ([[self panelPresentationController] isAnimating] || [[self mainView] isAnimating]) {
        return;
    }

    if (![[[self wordSelectionViewController] view] isHidden]) {
        [[self wordSelectionViewController] scrollToTopAnimated:YES];
        return;
    }

    if (![[[self previewViewController] previewView] isHidden]) {
        [[self previewViewController] scrollToTopAnimated:YES];
        return;
    }

    [[self activeListViewController] scrollToTopAnimated:YES];
}

#pragma mark - Item Handling

- (void)handlePasteboardItemDictionary:(NSDictionary<NSString *, id> *)dictionary
                   movedFromHistoryKey:(NSString *)sourceHistoryKey
                          toHistoryKey:(NSString *)destinationHistoryKey {
    [[self historyController] handlePasteboardItemDictionary:dictionary
                                         movedFromHistoryKey:sourceHistoryKey
                                                toHistoryKey:destinationHistoryKey];
}

#pragma mark - Note Editing

- (CGRect)noteEditingPanelFrameForKeyboardBottomInset:(CGFloat)keyboardBottomInset {
    UIView *mainView = [self mainView];
    UIView *superview = [mainView superview];
    if (!superview) {
        return [mainView frame];
    }

    CGRect bounds = [superview bounds];
    CGRect currentFrame = [mainView frame];
    CGFloat inset = kKayokoPanelFloatingInset;

    // Preserve floating-card width/x. Never expand note editing to full host bounds.
    CGFloat width = CGRectGetWidth(currentFrame);
    CGFloat x = CGRectGetMinX(currentFrame);
    if (width <= 0.0 || width >= CGRectGetWidth(bounds) - 1.0) {
        width = MIN(kKayokoPanelFloatingMaxWidth, CGRectGetWidth(bounds) - inset * 2.0);
        width = MAX(width, 280.0);
        x = CGRectGetMidX(bounds) - width * 0.5;
    }

    // Match portrait search: this is a self-contained floating card above the keyboard, not a
    // full-height panel hidden behind it. The note form remains top-anchored inside the card.
    CGFloat contentHeight = [[[self noteEditorViewController] noteEditorView] editingContentHeight];
    CGFloat preferredHeight = contentHeight + 12.0;
    CGFloat availableBottom = CGRectGetMaxY(bounds) - MAX(keyboardBottomInset, 0.0) - inset;
    CGFloat maximumHeight = MAX(availableBottom - inset, 0.0);
    CGFloat targetHeight = MIN(preferredHeight, maximumHeight);
    CGFloat y = availableBottom - targetHeight;
    if (y < inset) {
        y = inset;
        targetHeight = MIN(preferredHeight, MAX(CGRectGetHeight(bounds) - inset * 2.0, 0.0));
    }
    return CGRectMake(x, y, width, targetHeight);
}

- (void)beginNoteEditingForItem:(KayokoPasteboardItem *)item
             listViewController:(KayokoHistoryListViewController *)listViewController
               presentationCell:(KayokoTableViewCell *)presentationCell
                     sourceCell:(KayokoTableViewCell *)sourceCell {
    if (!item || !listViewController || !presentationCell || [self isNoteEditing] || [[self mainView] isAnimating] ||
        [[self panelPresentationController] isAnimating]) {
        return;
    }

    UIView *mainView = [self mainView];
    BOOL beganFromSearch = [[self searchController] isSearchActive];
    UIWindow *searchSourceWindow = beganFromSearch ? [sourceCell window] : nil;
    BOOL hasSearchSourceFrame = searchSourceWindow != nil;
    CGRect searchSourceFrameInWindow =
        hasSearchSourceFrame ? [sourceCell convertRect:[sourceCell bounds] toView:searchSourceWindow] : CGRectNull;
    // Use only the keyboard that is visible now. Reusing a previously-hidden keyboard height
    // makes the editor race to its final position before the next keyboard animation begins.
    CGFloat keyboardBottomInset = [[self noteEditorViewController] visibleKeyboardBottomInset];
    [listViewController setCellPresentationHidden:YES forItem:item];
    [self clearSearchAfterTransientContentState];
    [self setNoteEditingBeganFromSearch:beganFromSearch];
    [self setFinishingNoteEditing:NO];
    if (beganFromSearch) {
        [self setNoteEditingOriginalPanelFrame:[[self searchController] resetSearchStatePreservingContainerFrame]];
        sourceCell = [listViewController scrollItemToVisible:item];
        presentationCell = [listViewController presentationCellForItem:item];
    } else {
        [self setNoteEditingOriginalPanelFrame:[mainView frame]];
    }
    [self setNoteEditingKeyboardAnimationDuration:0.25];
    [self setNoteEditingKeyboardAnimationOptions:UIViewAnimationOptionCurveEaseInOut |
                                                 UIViewAnimationOptionBeginFromCurrentState |
                                                 UIViewAnimationOptionAllowUserInteraction];

    KayokoHistoryListView *sourceTableView = [listViewController tableView];
    KayokoNoteEditorView *noteEditorView = [[self noteEditorViewController] noteEditorView];
    [noteEditorView setCompactLayout:[self presentationMode] == KayokoPanelPresentationModeCompactLandscapeFullscreen];
    BOOL keepsSearchHeaderHidden =
        beganFromSearch || ![sourceTableView isSearchHeaderExposedAtContentOffset:[sourceTableView contentOffset]];
    [self setNoteEditingKeepsSearchHeaderHidden:keepsSearchHeaderHidden];
    [self setActiveSourceContentView:sourceTableView];
    [self setNoteEditingItem:item];
    [self setNoteEditingHistoryKey:[listViewController historyKey]];
    [self setNoteEditingSourceListViewController:listViewController];
    NSUInteger requestIdentifier = [self noteEditingRequestIdentifier] + 1;
    [self setNoteEditingRequestIdentifier:requestIdentifier];
    [self clearExternalHideCoordinator];

    CGFloat cellHeight = CGRectGetHeight([sourceCell bounds]);
    if (cellHeight <= 0) {
        cellHeight = [[listViewController tableView] rowHeight];
    }
    [[self noteEditorViewController] prepareForItem:item
                                   presentationCell:presentationCell
                                         cellHeight:cellHeight
                                keyboardBottomInset:keyboardBottomInset];

    [[self mainView] layoutIfNeeded];
    [noteEditorView setHidden:NO];
    [noteEditorView setAlpha:1];
    [noteEditorView setAutomaticallyPositionsPreviewCell:NO];
    [noteEditorView layoutIfNeeded];

    CGRect targetPanelFrame = [self noteEditingPanelFrameForKeyboardBottomInset:keyboardBottomInset];

    BOOL usesSearchSourceFrame = hasSearchSourceFrame && [noteEditorView window] == searchSourceWindow;
    BOOL hasSourceFrame = usesSearchSourceFrame || (sourceCell && [sourceCell window]);
    CGRect sourceFrame = [noteEditorView targetPreviewCellFrame];
    if (usesSearchSourceFrame) {
        sourceFrame = [noteEditorView convertRect:searchSourceFrameInWindow fromView:searchSourceWindow];
    } else if (hasSourceFrame) {
        sourceFrame = [sourceCell convertRect:[sourceCell bounds] toView:noteEditorView];
    }
    [[noteEditorView previewCell] setFrame:sourceFrame];
    [[noteEditorView previewCell] setAlpha:hasSourceFrame ? 1 : 0];
    [[noteEditorView inputRowView] setAlpha:0];
    [[noteEditorView tagChipBarView] setAlpha:0];

    KayokoHeaderView *headerView = [[self mainView] headerView];
    [[self mainView] setAnimating:YES];
    [UIView animateWithDuration:0.3
        delay:0
        usingSpringWithDamping:1
        initialSpringVelocity:0
        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
        animations:^{
          [mainView setFrame:targetPanelFrame];
          [mainView layoutIfNeeded];
          [noteEditorView layoutIfNeeded];
          [headerView setAlpha:0];
          [sourceTableView setAlpha:0];
          [[noteEditorView previewCell] setFrame:[noteEditorView targetPreviewCellFrame]];
          [[noteEditorView previewCell] setAlpha:1];
          [[noteEditorView inputRowView] setAlpha:1];
          [[noteEditorView tagChipBarView] setAlpha:1];
        }
        completion:^(__unused BOOL finished) {
          [listViewController setCellPresentationHidden:NO forItem:item];
          if ([self noteEditingRequestIdentifier] != requestIdentifier || ![self isNoteEditing]) {
              return;
          }
          [headerView setHidden:YES];
          [sourceTableView setHidden:YES];
          [noteEditorView setAutomaticallyPositionsPreviewCell:YES];
          [noteEditorView setNeedsLayout];
          [[self mainView] setAnimating:NO];
          [[self searchController] resignSearchFirstResponder];
          [[self noteEditorViewController] beginEditing];
          [self executePendingExternalHideRequestIfReady];
        }];
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleMedium];
}

- (void)resetNoteEditingState {
    KayokoNoteEditorView *noteEditorView = [[self noteEditorViewController] noteEditorView];
    [noteEditorView setHidden:YES];
    [[self noteEditingSourceListViewController] setCellPresentationHidden:NO forItem:[self noteEditingItem]];
    [noteEditorView setAlpha:1];
    [noteEditorView setAutomaticallyPositionsPreviewCell:YES];
    [[noteEditorView inputRowView] setAlpha:1];
    [[noteEditorView tagChipBarView] setAlpha:1];
    [[self noteEditorViewController] reset];
    [self setNoteEditingItem:nil];
    [self setNoteEditingHistoryKey:nil];
    [self setNoteEditingSourceListViewController:nil];
    [self setNoteEditingBeganFromSearch:NO];
    [self setNoteEditingKeepsSearchHeaderHidden:NO];
    [self setFinishingNoteEditing:NO];
    [self setNoteEditingOriginalPanelFrame:CGRectZero];
    [self setNoteEditingRequestIdentifier:[self noteEditingRequestIdentifier] + 1];
}

- (void)animateNoteEditingReturnWithRequestIdentifier:(NSUInteger)requestIdentifier
                                   ensuresItemVisible:(BOOL)ensuresItemVisible
                                     targetPanelFrame:(CGRect)targetPanelFrame
                                             duration:(NSTimeInterval)duration
                                              options:(UIViewAnimationOptions)options {
    if ([self noteEditingRequestIdentifier] != requestIdentifier || ![self isNoteEditing] || [self isDismissingPanel]) {
        return;
    }

    UIView *sourceView = [self activeSourceContentView];
    KayokoHeaderView *headerView = [[self mainView] headerView];
    KayokoNoteEditorView *noteEditorView = [[self noteEditorViewController] noteEditorView];
    KayokoMainView *mainView = [self mainView];
    [sourceView setHidden:NO];
    [sourceView setAlpha:0];
    [headerView setHidden:NO];
    [headerView setAlpha:0];
    [noteEditorView setAutomaticallyPositionsPreviewCell:NO];

    KayokoHistoryListViewController *listViewController = [self noteEditingSourceListViewController];
    KayokoPasteboardItem *item = [self noteEditingItem];
    [listViewController setCellPresentationHidden:YES forItem:item];
    KayokoHistoryListView *tableView = [listViewController tableView];
    [mainView setAnimating:YES];

    duration = duration > 0 ? duration : 0.3;
    options |= UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    [UIView animateWithDuration:duration
        delay:0
        options:options
        animations:^{
          [mainView setFrame:targetPanelFrame];
          [mainView layoutIfNeeded];
          [UIView performWithoutAnimation:^{
            if (ensuresItemVisible) {
                [listViewController scrollItemToVisible:item];
            }
            if ([self noteEditingKeepsSearchHeaderHidden]) {
                [tableView restoreHiddenSearchHeaderOffsetWithoutAnimation];
            } else {
                [tableView layoutIfNeeded];
            }
          }];

          [sourceView setAlpha:1];
          [headerView setAlpha:1];
          [[noteEditorView inputRowView] setAlpha:0];
          [[noteEditorView tagChipBarView] setAlpha:0];
          KayokoTableViewCell *targetCell = [listViewController visibleCellForItem:item];
          if (targetCell && [targetCell window]) {
              [[noteEditorView previewCell] setFrame:[targetCell convertRect:[targetCell bounds]
                                                                      toView:noteEditorView]];
          } else {
              [[noteEditorView previewCell] setAlpha:0];
          }
        }
        completion:^(__unused BOOL finished) {
          if ([self noteEditingRequestIdentifier] != requestIdentifier) {
              [listViewController setCellPresentationHidden:NO forItem:item];
              return;
          }
          [sourceView setAlpha:1];
          [sourceView setTransform:CGAffineTransformIdentity];
          [headerView setHidden:NO];
          [headerView setAlpha:1];
          [self setActiveSourceContentView:nil];
          [self resetNoteEditingState];
          [[self mainView] setAnimating:NO];
        }];
}

- (void)finishNoteEditingWithRequestIdentifier:(NSUInteger)requestIdentifier {
    if ([self noteEditingRequestIdentifier] != requestIdentifier || ![self isNoteEditing] || [self isDismissingPanel]) {
        return;
    }

    [self setFinishingNoteEditing:YES];
    [self clearSearchAfterTransientContentState];
    KayokoNoteEditorView *noteEditorView = [[self noteEditorViewController] noteEditorView];
    [noteEditorView setAutomaticallyPositionsPreviewCell:NO];
    if ([[self searchController] isSearchActive]) {
        [[self searchController] resetSearchState];
    }
    [[self noteEditorViewController] resignEditing];

    NSTimeInterval duration = [self noteEditingKeyboardAnimationDuration];
    UIViewAnimationOptions options = [self noteEditingKeyboardAnimationOptions];
    [self animateNoteEditingReturnWithRequestIdentifier:requestIdentifier
                                     ensuresItemVisible:[self noteEditingBeganFromSearch]
                                       targetPanelFrame:[self noteEditingOriginalPanelFrame]
                                               duration:duration
                                                options:options];
}

- (void)noteEditorViewControllerDidRequestCancel:(KayokoNoteEditorViewController *)controller {
    if (![self isNoteEditing] || [self isDismissingPanel] || [self isFinishingNoteEditing]) {
        return;
    }
    // Restore the live preview title before the dismiss animation so cancelled edits
    // do not briefly show unsaved note text over the original item.
    [controller restorePreviewToSavedState];
    [self finishNoteEditingWithRequestIdentifier:[self noteEditingRequestIdentifier]];
}

- (void)noteEditorViewController:(KayokoNoteEditorViewController *)controller
                 didSelectTagUUID:(NSString *)tagUUID {
    (void)controller;
    (void)tagUUID;
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleLight];
}

- (void)noteEditorViewController:(KayokoNoteEditorViewController *)controller
              didRequestSaveNote:(NSString *)note
                       tagUUID:(NSString *)tagUUID {
    KayokoPasteboardItem *item = [self noteEditingItem];
    NSString *historyKey = [self noteEditingHistoryKey];
    KayokoHistoryListViewController *listViewController = [self noteEditingSourceListViewController];
    NSUInteger requestIdentifier = [self noteEditingRequestIdentifier];
    if (!item || [historyKey length] == 0 || !listViewController) {
        [controller setSaving:NO];
        return;
    }

    [[KayokoPasteboardManager sharedInstance]
                  setNote:note
                  tagUUID:tagUUID
        forPasteboardItem:item
         inHistoryWithKey:historyKey
               completion:^(BOOL success) {
                 if (!success) {
                     if ([self noteEditingRequestIdentifier] == requestIdentifier && [self isNoteEditing] &&
                         ![self isDismissingPanel]) {
                         [controller setSaving:NO];
                         [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleRigid];
                     }
                     return;
                 }

                 [item setNote:note];
                 [item setTagUUID:tagUUID];
                 [listViewController updateNote:note
                                        tagUUID:tagUUID
                                        forItem:item
                                     completion:^{
                                       [self finishNoteEditingWithRequestIdentifier:requestIdentifier];
                                     }];
               }];
}

- (void)noteEditorViewController:(KayokoNoteEditorViewController *)controller
    didUpdateKeyboardBottomInset:(CGFloat)keyboardBottomInset
               animationDuration:(NSTimeInterval)animationDuration
                         options:(UIViewAnimationOptions)options {
    if (controller != [self noteEditorViewController] || ![self isNoteEditing]) {
        return;
    }

    // Cancelling first resigns the field. Its keyboard-hide notification must not start a
    // second layout animation while the card is already returning to the list cell.
    if ([self isFinishingNoteEditing] || [self isDismissingPanel]) {
        return;
    }

    [self setNoteEditingKeyboardAnimationDuration:animationDuration];
    [self setNoteEditingKeyboardAnimationOptions:options];

    KayokoNoteEditorView *noteEditorView = [controller noteEditorView];
    UIView *mainView = [self mainView];
    UIView *superview = [mainView superview];
    BOOL adjustsPanelFrame = superview != nil;
    CGRect targetFrame =
        adjustsPanelFrame ? [self noteEditingPanelFrameForKeyboardBottomInset:keyboardBottomInset] : [mainView frame];

    void (^updates)(void) = ^{
      [noteEditorView setAnchorsEditingContentToTop:YES];
      [noteEditorView setKeyboardBottomInset:0];
      if (adjustsPanelFrame) {
          [mainView setFrame:targetFrame];
      }
      [mainView layoutIfNeeded];
    };
    if (animationDuration <= 0) {
        updates();
        return;
    }
    [mainView layoutIfNeeded];
    [UIView animateWithDuration:animationDuration delay:0 options:options animations:updates completion:nil];
}

#pragma mark - Transient Presentation

- (void)showContentForItem:(KayokoPasteboardItem *)item {
    BOOL restoresSearchFirstResponder = [[self searchController] isActiveSearchFirstResponder];
    [self setRestoresSearchFirstResponderAfterTransientContent:restoresSearchFirstResponder];
    if (restoresSearchFirstResponder) {
        [self setSearchContentOffsetBeforeTransientContent:[[[self activeListViewController] tableView] contentOffset]];
        [self setHasSearchContentOffsetBeforeTransientContent:YES];
    } else {
        [self setHasSearchContentOffsetBeforeTransientContent:NO];
    }
    NSString *historyKey = [self effectiveActiveHistoryKey];
    KayokoHistoryListView *sourceTableView = [self tableViewForHistoryKey:historyKey];
    [self setActiveSourceContentView:sourceTableView];
    NSString *previewText =
        [([item content] ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL canUseWordSelection = [self swipeToSelectWords] && [[item imageName] isEqualToString:@""] &&
                               [[self wordSelectionViewController] canShowText:previewText];
    UIView *viewToShow = nil;
    UIView *transitionContentView = nil;
    if (canUseWordSelection) {
        [[self wordSelectionViewController] showWordSelectionWithItem:item
                                                     sourceHistoryKey:historyKey
                                                   automaticallyPaste:[self automaticallyPaste]];
        viewToShow = [[self wordSelectionViewController] view];
        transitionContentView = [[self wordSelectionViewController] wordSelectionView].transitionContentView;
    } else {
        [[self previewViewController] showPreviewWithItem:item sourceHistoryKey:historyKey];
        viewToShow = [[self previewViewController] previewView];
        transitionContentView = [[self previewViewController] previewView].transitionContentView;
    }

    KayokoHeaderView *mainHeaderView = [[self mainView] headerView];
    [mainHeaderView setHidden:YES];
    [mainHeaderView setAlpha:1.0];
    [[self mainView] showContentView:viewToShow
                   transitioningView:transitionContentView
                     hideContentView:sourceTableView
                   transitioningView:sourceTableView
                           direction:KayokoContentTransitionDirectionForward
                 alongsideAnimations:nil
                          completion:^{
                            if (restoresSearchFirstResponder) {
                                [[self searchController] resignSearchFirstResponder];
                            }
                          }];
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleMedium];
}

- (void)hidePreview {
    [[[self mainView] headerView] setHistorySwitcherVisible:YES animated:NO];
    [self updateFavoritesButtonForHistoryKey:[self effectiveActiveHistoryKey]];
    if ([[[self previewViewController] previewView] isHidden] || [[self panelPresentationController] isAnimating]) {
        return;
    }

    UIView *sourceView = [self activeSourceContentView];
    KayokoPreviewView *previewView = [[self previewViewController] previewView];
    if (!sourceView) {
        [[self previewViewController] resetPreviewState];
        [[previewView headerView] setHidden:NO];
        [self setActiveSourceContentView:nil];
        [[[self mainView] headerView] setHidden:NO];
        [[[self mainView] headerView] setAlpha:1.0];
        [self refreshSearchAfterEndingTransientContentIfNeeded];
        return;
    }

    UIView *mainHeaderView = [[self mainView] headerView];
    [mainHeaderView setHidden:NO];
    [mainHeaderView setAlpha:1.0];
    [[previewView headerView] setHidden:YES];
    [[self mainView] showContentView:sourceView
        transitioningView:sourceView
        hideContentView:previewView
        transitioningView:[previewView transitionContentView]
        direction:KayokoContentTransitionDirectionBackward
        alongsideAnimations:^{
          [self refreshSearchAfterEndingTransientContentIfNeeded];
        }
        completion:^{
          [[self previewViewController] hidePreview];
          [[previewView headerView] setHidden:NO];
          [self setActiveSourceContentView:nil];
          [mainHeaderView setHidden:NO];
          [mainHeaderView setAlpha:1.0];
        }];
}

- (void)hideWordSelection {
    [[[self mainView] headerView] setHistorySwitcherVisible:YES animated:NO];
    [self updateFavoritesButtonForHistoryKey:[self effectiveActiveHistoryKey]];
    if ([[[self wordSelectionViewController] view] isHidden] || [[self panelPresentationController] isAnimating]) {
        return;
    }

    UIView *sourceView = [self activeSourceContentView];
    UIView *wordSelectionView = [[self wordSelectionViewController] view];
    if (!sourceView) {
        [[self wordSelectionViewController] resetWordSelectionState];
        [[[[self wordSelectionViewController] wordSelectionView] headerView] setHidden:NO];
        [self setActiveSourceContentView:nil];
        [[[self mainView] headerView] setHidden:NO];
        [[[self mainView] headerView] setAlpha:1.0];
        [self refreshSearchAfterEndingTransientContentIfNeeded];
        return;
    }

    UIView *mainHeaderView = [[self mainView] headerView];
    [mainHeaderView setHidden:NO];
    [mainHeaderView setAlpha:1.0];
    [[[[self wordSelectionViewController] wordSelectionView] headerView] setHidden:YES];
    [[self mainView] showContentView:sourceView
        transitioningView:sourceView
        hideContentView:wordSelectionView
        transitioningView:[[self wordSelectionViewController] wordSelectionView].transitionContentView
        direction:KayokoContentTransitionDirectionBackward
        alongsideAnimations:^{
          [self refreshSearchAfterEndingTransientContentIfNeeded];
        }
        completion:^{
          [[self wordSelectionViewController] hideWordSelection];
          [[[[self wordSelectionViewController] wordSelectionView] headerView] setHidden:NO];
          [self setActiveSourceContentView:nil];
          [mainHeaderView setHidden:NO];
          [mainHeaderView setAlpha:1.0];
        }];
}

#pragma mark - KayokoClearConfirmationViewControllerDelegate

- (void)clearConfirmationViewControllerDidCancel:(KayokoClearConfirmationViewController *)controller {
    if ([[self panelPresentationController] isAnimating]) {
        return;
    }

    [self hideClearConfirmationWithReload:NO];
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleSoft];
}

- (void)clearConfirmationViewControllerDidClearHistoryKey:(NSString *)historyKey {
    [self hideClearConfirmationWithReload:YES];
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:UIImpactFeedbackStyleHeavy];
}

- (void)clearConfirmationViewController:(KayokoClearConfirmationViewController *)controller
              didFailClearingHistoryKey:(NSString *)historyKey {
}

#pragma mark - KayokoWordSelectionViewControllerDelegate

- (void)wordSelectionViewController:(KayokoWordSelectionViewController *)controller
    didRequestHideContainerAfterDirectPaste:(BOOL)directPaste {
    [[self panelPresentationController] prepareStandardDismissAnimation];
    if (directPaste) {
        [self hideAfterDirectPaste];
    } else {
        [self hideRestoringFocus];
    }
}

- (void)wordSelectionViewController:(KayokoWordSelectionViewController *)controller
     triggerHapticFeedbackWithStyle:(UIImpactFeedbackStyle)style {
    [[self panelPresentationController] triggerHapticFeedbackWithStyle:style];
}


#pragma mark - Public API

- (void)reload {

    NSString *historyKey = [self effectiveActiveHistoryKey];
    [self reloadTableViewForHistoryKey:historyKey
                animatingTopInsertions:![self isHidden] && [historyKey isEqualToString:kKayokoHistoryKeyHistory]
                            completion:^(KayokoHistoryListView *tableView) {
                              if (![[self effectiveActiveHistoryKey] isEqualToString:historyKey]) {
                                  return;
                              }
                              if ([self isShowingClearConfirmation] ||
                                  ![[[self previewViewController] previewView] isHidden] ||
                                  ![[[self wordSelectionViewController] view] isHidden] || [self isNoteEditing]) {
                                  return;
                              }
                              [self setHistoryContentVisibleForKey:historyKey];
                              [[self searchController] refreshForListViewController:[self activeListViewController]];
                            }];
}

- (void)preloadHistoryIfNeeded {
    [[self historyController] preloadHistoryWithCompletion:nil];
}

- (void)show {
    if ([[self panelPresentationController] isAnimating] || [self preparingToShow]) {
        return;
    }
    if (![self isHidden]) {
        return;
    }

    [self clearExternalHideCoordinator];
    [self setDismissingPanel:NO];
    [self setPreparingToShow:YES];
    [[KayokoTagCatalog sharedCatalog] reloadTags];
    NSUInteger showRequestIdentifier = [self showRequestIdentifier] + 1;
    [self setShowRequestIdentifier:showRequestIdentifier];
    [self resetClearConfirmationIfNeeded];

    [[self historyListViewController] setAutomaticallyPaste:[self automaticallyPaste]];
    [[self favoritesListViewController] setAutomaticallyPaste:[self automaticallyPaste]];
    // Relative timestamps are derived presentation text, so refresh cached lists whenever the panel opens.
    [[[self historyListViewController] tableView] reloadData];
    [[[self favoritesListViewController] tableView] reloadData];

    NSString *initialHistoryKey = [self historyKeyForInitialViewMode];
    if ([initialHistoryKey length] > 0) {
        [[self historyController] setActiveHistoryKey:initialHistoryKey];
    }

    NSString *historyKey = [self effectiveActiveHistoryKey];
    [self reloadTableViewForHistoryKey:historyKey
                animatingTopInsertions:NO
                            completion:^(KayokoHistoryListView *tableView) {
                              if ([self showRequestIdentifier] != showRequestIdentifier) {
                                  return;
                              }
                              [self setPreparingToShow:NO];
                              if (![[self effectiveActiveHistoryKey] isEqualToString:historyKey] || ![self isHidden] ||
                                  [[self panelPresentationController] isAnimating]) {
                                  return;
                              }

                              [self setHistoryContentVisibleForKey:historyKey];
                              [[self searchController] attachToListViewController:[self activeListViewController]
                                                                   hidesSearchBar:YES];
                              [[self panelPresentationController] showPanelWithCompletion:^{
                                [self executePendingExternalHideRequestIfReady];
                              }];
                            }];
}

#pragma mark - Hiding

- (void)hide {
    [self hideWithCompletion:nil];
}

- (void)hideWithStandardDismissAnimation {
    [[self panelPresentationController] prepareStandardDismissAnimation];
    [self hideWithCompletion:nil];
}

- (void)hideAfterDirectPaste {
    BOOL shouldRestoreFocusAfterHide = [self isFullscreenSearchActive];
    [self hideWithCompletion:^{
      if (!shouldRestoreFocusAfterHide) {
          return;
      }
      [[self delegate] mainViewControllerDidRequestFocusRestore:self];
    }];
}

- (void)hideRestoringFocus {
    [self hideWithCompletion:^{
      [[self delegate] mainViewControllerDidRequestFocusRestore:self];
    }];
}

- (void)completeHideAfterShowingTransientContent:(BOOL)wasShowingTransientContent
                                      completion:(void (^)(void))completion {
    [self restoreActiveSourceContentView];
    [[[self mainView] headerView] setHidden:NO];
    [[[self mainView] headerView] setAlpha:1.0];
    [[self previewViewController] resetPreviewState];
    [[self wordSelectionViewController] resetWordSelectionState];
    [self resetNoteEditingState];
    [self setActiveSourceContentView:nil];
    [self setDismissingPanel:NO];
    if (wasShowingTransientContent) {
        [self refreshSearchAfterEndingTransientContentIfNeeded];
    }
    if ([self alwaysScrollToTop]) {
        [[self historyController] markAllHistoryKeysForScrollToTopBeforeNextDisplay];
    }
    if (completion) {
        completion();
    }
    [[self delegate] mainViewControllerDidHide:self];
}

- (void)hideWithCompletion:(void (^)(void))completion {
    [self hideWithAnimationStyle:KayokoPanelHideAnimationStyleDefault completion:completion];
}

- (void)hideWithAnimationStyle:(KayokoPanelHideAnimationStyle)animationStyle completion:(void (^)(void))completion {
    [self setShowRequestIdentifier:[self showRequestIdentifier] + 1];
    [self setPreparingToShow:NO];

    if ([[self panelPresentationController] isAnimating]) {
        return;
    }

    [self dismissLeadingButtonMenu];

    [self clearExternalHideCoordinator];
    [self setDismissingPanel:YES];
    BOOL wasShowingTransientContent = [self isPreviewActive] || [self isWordSelectionActive] || [self isNoteEditing];
    [[self searchController] resignSearchFirstResponder];
    [[self noteEditorViewController] resignEditing];
    [[self panelPresentationController]
        hidePanelWithAnimationStyle:animationStyle
                         completion:^{
                           [[self searchController] resetSearchState];
                           [self completeHideAfterShowingTransientContent:wasShowingTransientContent
                                                               completion:completion];
                         }];
}

- (void)hideForExternalRequestWithAnimationStyle:(KayokoPanelHideAnimationStyle)animationStyle
                                      completion:(nullable void (^)(void))completion {
    if ([self isHidden]) {
        return;
    }

    if ([self isNoteEditing]) {
        return;
    }

    if ([[self externalHideCoordinator] shouldSuppressExternalHide]) {
        return;
    }

    if ([self externalHideRequestShouldWaitForAnimations]) {
        [[self externalHideCoordinator] recordPendingExternalHideRequestWithAnimationStyle:animationStyle
                                                                                completion:completion];
        return;
    }

    [self hideWithAnimationStyle:animationStyle completion:completion];
}

- (void)hideImmediately {
    [self setShowRequestIdentifier:[self showRequestIdentifier] + 1];
    [self setPreparingToShow:NO];

    if ([self isHidden]) {
        return;
    }

    [self dismissLeadingButtonMenu];
    [self clearExternalHideCoordinator];
    [self setDismissingPanel:YES];
    BOOL wasShowingTransientContent = [self isPreviewActive] || [self isWordSelectionActive] || [self isNoteEditing];
    [[self searchController] resignSearchFirstResponder];
    [[self noteEditorViewController] resignEditing];
    [[self panelPresentationController] hidePanelImmediatelyWithCompletion:^{
      [[self searchController] resetSearchState];
      [self completeHideAfterShowingTransientContent:wasShowingTransientContent completion:nil];
    }];
}

@end
