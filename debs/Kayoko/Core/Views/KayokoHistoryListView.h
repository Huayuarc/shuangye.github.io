//
//  KayokoHistoryListView.h
//  Kayoko
//
//  Created by Alexandra Aurora Göttlicher
//

#import "KayokoEdgeFadingTableView.h"
#import "KayokoPreferenceKeys.h"

NS_ASSUME_NONNULL_BEGIN

@interface KayokoHistoryListView : KayokoEdgeFadingTableView

@property(nonatomic, copy) NSString *name;
@property(nonatomic, assign) NSUInteger previewLineCount;
@property(nonatomic, assign) KayokoItemDetailsMode itemDetailsMode;
@property(nonatomic, assign) CGFloat keyboardBottomInset;
@property(nonatomic, assign) CGFloat searchBarSnapHeight;

- (instancetype)initWithName:(NSString *)name;
- (void)setShowsNoSearchResultsPlaceholder:(BOOL)showsNoSearchResultsPlaceholder;
- (void)updateNoSearchResultsPlaceholderLayout;
- (BOOL)isSearchHeaderExposedAtContentOffset:(CGPoint)contentOffset;
- (BOOL)isContentOffsetAtHiddenSearchHeaderBoundary:(CGPoint)contentOffset;
- (void)adjustTargetContentOffsetForSearchBarSnap:(CGPoint *)targetContentOffset;
- (CGFloat)minimumBottomInsetForMaintainingHiddenHeaderWithAdditionalContentHeightReduction:(CGFloat)heightReduction;
- (void)prepareHiddenHeaderInsetsForRemovingRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)beginTransientContentOffsetPreservationAtContentOffset:(CGPoint)contentOffset;
- (void)restoreHiddenSearchHeaderOffsetWithoutAnimation;
// Reports whether the search bar is currently scrolled out of view (content offset at/below the
// hidden position). Capture this BEFORE a reload to decide if the bar should be kept hidden after.
- (BOOL)isSearchBarHiddenAtCurrentContentOffset;
// Restores a previously-hidden search bar to the hidden position after a reload shrank the list.
// Only call when the bar was hidden pre-reload; the reposition is off-screen, so there is no snap.
// A search bar the user pulled down is left untouched (caller must not call it in that case).
- (void)keepSearchBarHiddenAfterReload;
- (void)scrollToFirstItemKeepingSearchHeaderHiddenWithoutAnimation;
- (void)scrollToTopAnimated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
