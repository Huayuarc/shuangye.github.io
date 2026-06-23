// JadeFavoriteModulesCaddy.m
// Container view that holds the user's favorite/frequently used modules
// Presented in a horizontal paging scroll view with multiple pages,
// each page containing up to 6 modules arranged in a 3-column x 2-row grid.

#import "JadeFavoriteModulesCaddy.h"
#import "JadeSmallModule.h"
#import "JadeFullWidthModule.h"
#import <rootless.h>

@interface JadeFavoriteModulesCaddy () <UIScrollViewDelegate> {
    UIScrollView *_scrollView;
    NSMutableArray *_arr;
    NSArray *_stackViews;
    UIStackView *_mainStackView;
    unsigned long long _numberOfPages;
    NSMutableArray<UIView *> *_modules;
}

@property (nonatomic, strong) UIPageControl *pageControl;

@end

@implementation JadeFavoriteModulesCaddy

@synthesize modules = _modules;
@synthesize sectionLabel = _sectionLabel;
@synthesize modulesStackView = _modulesStackView;
@synthesize moduleTintColor = _moduleTintColor;
@synthesize maxVisibleModules = _maxVisibleModules;
@synthesize isExpanded = _isExpanded;
@synthesize isAscendingOrder = _isAscendingOrder;

#pragma mark - Constants

static const CGFloat kModuleSpacing = 8.0;
static const CGFloat kPageControlHeight = 20.0;
static const NSInteger kModulesPerPage = 6;   // 3 columns x 2 rows
static const NSInteger kColumnsPerPage = 3;

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _maxVisibleModules = 12;
        _isExpanded = NO;
        _isAscendingOrder = YES;
        _moduleTintColor = [UIColor whiteColor];
        _numberOfPages = 0;
        _arr = [NSMutableArray array];
        _modules = [NSMutableArray array];

        [self setupViews];
        [self setupConstraints];
    }
    return self;
}

#pragma mark - Setup

- (void)setupViews {
    // Section label
    _sectionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _sectionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _sectionLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _sectionLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
    _sectionLabel.text = @"Favorites";
    _sectionLabel.numberOfLines = 1;
    [self addSubview:_sectionLabel];

    // Horizontal stack view that holds the page stacks
    _mainStackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _mainStackView.translatesAutoresizingMaskIntoConstraints = NO;
    _mainStackView.axis = UILayoutConstraintAxisHorizontal;
    _mainStackView.alignment = UIStackViewAlignmentFill;
    _mainStackView.distribution = UIStackViewDistributionFillEqually;
    _mainStackView.spacing = 0;

    // Scroll view for paging
    _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _scrollView.pagingEnabled = YES;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.bounces = YES;
    _scrollView.alwaysBounceHorizontal = YES;
    _scrollView.scrollEnabled = YES;
    _scrollView.delegate = self;
    _scrollView.clipsToBounds = YES;
    if (@available(iOS 11.0, *)) {
        _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }

    [_scrollView addSubview:_mainStackView];
    [self addSubview:_scrollView];

    // Page control
    _pageControl = [[UIPageControl alloc] initWithFrame:CGRectZero];
    _pageControl.translatesAutoresizingMaskIntoConstraints = NO;
    _pageControl.numberOfPages = 0;
    _pageControl.currentPage = 0;
    _pageControl.hidesForSinglePage = YES;
    _pageControl.pageIndicatorTintColor = [UIColor colorWithWhite:0.5 alpha:0.4];
    _pageControl.currentPageIndicatorTintColor = [UIColor colorWithWhite:0.9 alpha:0.8];
    _pageControl.userInteractionEnabled = NO;
    [self addSubview:_pageControl];

    _modulesStackView = _mainStackView;
}

- (void)setupConstraints {
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];

    // Section label pinned to top
    [constraints addObject:[_sectionLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16]];
    [constraints addObject:[_sectionLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8]];
    [constraints addObject:[_sectionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16]];
    [constraints addObject:[_sectionLabel.heightAnchor constraintEqualToConstant:18]];

    // Scroll view below section label, above page control
    [constraints addObject:[_scrollView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor]];
    [constraints addObject:[_scrollView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]];
    [constraints addObject:[_scrollView.topAnchor constraintEqualToAnchor:_sectionLabel.bottomAnchor constant:8]];
    [constraints addObject:[_scrollView.bottomAnchor constraintEqualToAnchor:_pageControl.topAnchor constant:-4]];

    // Main stack view fills scroll view content
    [constraints addObject:[_mainStackView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor]];
    [constraints addObject:[_mainStackView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor]];
    [constraints addObject:[_mainStackView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor]];
    [constraints addObject:[_mainStackView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor]];
    [constraints addObject:[_mainStackView.heightAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.heightAnchor]];

    // Page control pinned to bottom
    [constraints addObject:[_pageControl.centerXAnchor constraintEqualToAnchor:self.centerXAnchor]];
    [constraints addObject:[_pageControl.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]];
    [constraints addObject:[_pageControl.heightAnchor constraintEqualToConstant:kPageControlHeight]];

    [NSLayoutConstraint activateConstraints:constraints];
}

#pragma mark - Reload

- (void)reload {
    // Remove all existing page stack views
    for (UIStackView *pageStack in _mainStackView.arrangedSubviews) {
        [pageStack removeFromSuperview];
    }
    [_arr removeAllObjects];

    if (!_modules || _modules.count == 0) {
        _numberOfPages = 0;
        _pageControl.numberOfPages = 0;
        _pageControl.currentPage = 0;
        return;
    }

    // Determine which modules to show, respecting maxVisibleModules
    NSArray *modulesToShow = _modules;
    if (modulesToShow.count > _maxVisibleModules) {
        modulesToShow = [modulesToShow subarrayWithRange:NSMakeRange(0, _maxVisibleModules)];
    }

    // Calculate number of pages needed
    NSUInteger totalModules = modulesToShow.count;
    _numberOfPages = (totalModules + kModulesPerPage - 1) / kModulesPerPage;
    _pageControl.numberOfPages = (NSInteger)_numberOfPages;
    _pageControl.currentPage = 0;

    // Build page stack views: each page is a vertical stack of rows,
    // each row is a horizontal stack of modules.
    for (NSUInteger pageIndex = 0; pageIndex < _numberOfPages; pageIndex++) {
        UIStackView *pageStack = [[UIStackView alloc] initWithFrame:CGRectZero];
        pageStack.translatesAutoresizingMaskIntoConstraints = NO;
        pageStack.axis = UILayoutConstraintAxisVertical;
        pageStack.alignment = UIStackViewAlignmentFill;
        pageStack.distribution = UIStackViewDistributionFillEqually;
        pageStack.spacing = kModuleSpacing;

        NSUInteger startIdx = pageIndex * kModulesPerPage;
        NSUInteger remaining = totalModules - startIdx;
        NSUInteger modulesInThisPage = (remaining > kModulesPerPage) ? kModulesPerPage : remaining;
        NSUInteger rowsInThisPage = (modulesInThisPage + kColumnsPerPage - 1) / kColumnsPerPage;

        for (NSUInteger row = 0; row < rowsInThisPage; row++) {
            UIStackView *rowStack = [[UIStackView alloc] initWithFrame:CGRectZero];
            rowStack.translatesAutoresizingMaskIntoConstraints = NO;
            rowStack.axis = UILayoutConstraintAxisHorizontal;
            rowStack.alignment = UIStackViewAlignmentFill;
            rowStack.distribution = UIStackViewDistributionFillEqually;
            rowStack.spacing = kModuleSpacing;

            NSUInteger moduleOffset = row * kColumnsPerPage;
            for (NSUInteger col = 0; col < kColumnsPerPage; col++) {
                NSUInteger moduleIdx = startIdx + moduleOffset + col;
                if (moduleIdx >= totalModules) {
                    // Fill remaining slots with empty spacer views
                    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
                    spacer.translatesAutoresizingMaskIntoConstraints = NO;
                    [rowStack addArrangedSubview:spacer];
                    continue;
                }

                id moduleData = modulesToShow[moduleIdx];
                JadeSmallModule *moduleView;

                if ([moduleData isKindOfClass:[NSString class]]) {
                    // Module data is an identifier string
                    moduleView = [[JadeSmallModule alloc] initWithFrame:CGRectZero];
                    // The identifier is used by JadeSmallModule to load from CCSModuleRepository
                    // For the caddy, we pass it along via KVC or direct property
                    [moduleView setValue:moduleData forKey:@"identifier"];
                } else if ([moduleData isKindOfClass:[JadeSmallModule class]]) {
                    moduleView = (JadeSmallModule *)moduleData;
                } else {
                    // Unknown type, create empty spacer
                    UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
                    spacer.translatesAutoresizingMaskIntoConstraints = NO;
                    [rowStack addArrangedSubview:spacer];
                    [_arr addObject:spacer];
                    continue;
                }

                moduleView.translatesAutoresizingMaskIntoConstraints = NO;
                [rowStack addArrangedSubview:moduleView];
                [_arr addObject:moduleView];
            }

            [pageStack addArrangedSubview:rowStack];
        }

        [_mainStackView addArrangedSubview:pageStack];
    }

    // Apply theme settings
    [self addModuleSettingsIfNeeded];

    // Force layout update
    [self setNeedsLayout];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat scrollViewWidth = _scrollView.bounds.size.width;
    if (scrollViewWidth > 0 && _numberOfPages > 0) {
        _scrollView.contentSize = CGSizeMake(scrollViewWidth * (CGFloat)_numberOfPages, _scrollView.bounds.size.height);
    } else {
        _scrollView.contentSize = CGSizeZero;
    }
}

#pragma mark - Scrolling

- (void)scrollToPage:(NSUInteger)pageIndex animated:(BOOL)animated {
    if (pageIndex >= _numberOfPages) return;

    CGFloat pageWidth = _scrollView.bounds.size.width;
    if (pageWidth <= 0) return;

    CGPoint targetOffset = CGPointMake(pageWidth * (CGFloat)pageIndex, 0);
    [_scrollView setContentOffset:targetOffset animated:animated];
    _pageControl.currentPage = (NSInteger)pageIndex;
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView != _scrollView) return;
    if (_numberOfPages <= 1) return;

    CGFloat pageWidth = scrollView.bounds.size.width;
    if (pageWidth <= 0) return;

    CGFloat currentPageFloat = scrollView.contentOffset.x / pageWidth;
    NSInteger currentPage = (NSInteger)round(currentPageFloat);

    if (currentPage >= 0 && currentPage < (NSInteger)_numberOfPages) {
        _pageControl.currentPage = currentPage;
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView != _scrollView) return;

    CGFloat pageWidth = scrollView.bounds.size.width;
    if (pageWidth <= 0) return;

    NSInteger currentPage = (NSInteger)round(scrollView.contentOffset.x / pageWidth);
    _pageControl.currentPage = currentPage;
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    if (scrollView != _scrollView) return;

    CGFloat pageWidth = scrollView.bounds.size.width;
    if (pageWidth <= 0) return;

    NSInteger currentPage = (NSInteger)round(scrollView.contentOffset.x / pageWidth);
    _pageControl.currentPage = currentPage;
}

#pragma mark - Theme / Appearance

- (void)addModuleSettingsIfNeeded {
    // Apply consistent styling to all module views in the caddy
    UIColor *bgColor = [UIColor colorWithWhite:0.15 alpha:1.0];
    UIColor *tintColor = _moduleTintColor ?: [UIColor whiteColor];

    for (UIView *view in _arr) {
        if ([view isKindOfClass:[JadeSmallModule class]]) {
            JadeSmallModule *module = (JadeSmallModule *)view;
            [module setModuleBackgroundColor:bgColor animated:NO];
            module.moduleTintColor = tintColor;
            module.moduleCornerRadius = 13.0;
        } else if ([view isKindOfClass:[JadeFullWidthModule class]]) {
            JadeFullWidthModule *fullModule = (JadeFullWidthModule *)view;
            [fullModule setModuleBackgroundColor:bgColor animated:NO];
            fullModule.moduleTintColor = tintColor;
            fullModule.moduleCornerRadius = 13.0;
        }
    }
}

#pragma mark - Module Management

- (void)addModule:(UIView *)module {
    if (!module) return;
    NSMutableArray *mutableModules = [_modules mutableCopy];
    [mutableModules addObject:module];
    _modules = mutableModules;
    [self reload];
}

- (void)removeModule:(UIView *)module {
    if (!module) return;
    if ([_modules containsObject:module]) {
        NSMutableArray *mutableModules = [_modules mutableCopy];
        [mutableModules removeObject:module];
        _modules = mutableModules;
        [self reload];
    }
}

- (void)reloadModules {
    [self reload];
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    _isExpanded = expanded;
    _maxVisibleModules = expanded ? 24 : 12;
    [self reload];

    if (animated) {
        [UIView animateWithDuration:0.3 animations:^{
            [self.superview layoutIfNeeded];
        }];
    }
}

- (void)reorderModules {
    if (!_isAscendingOrder) {
        NSArray *reversed = [[_modules reverseObjectEnumerator] allObjects];
        _modules = [reversed mutableCopy];
    }
    [self reload];
}

- (void)clearAllModules {
    _modules = [NSMutableArray array];
    [self reload];
}

@end
