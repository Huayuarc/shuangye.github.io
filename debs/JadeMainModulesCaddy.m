// JadeMainModulesCaddy.m
// Primary container view that holds the main control center modules
// arranged in a grid layout (2 columns by default).

#import "JadeMainModulesCaddy.h"
#import "JadeSmallModule.h"
#import "JadeFullWidthModule.h"
#import "JadeWeatherModule.h"
#import "JadeMediaModule.h"
#import "JadeBatteryModule.h"
#import <rootless.h>

@interface JadeMainModulesCaddy () {
    NSMutableArray *_arr;
    NSArray *_stackViews;
    NSLayoutConstraint *_heightConstraint;
    NSMutableArray<UIView *> *_modules;
}

@end

@implementation JadeMainModulesCaddy

@synthesize modules = _modules;
@synthesize sectionLabel = _sectionLabel;
@synthesize modulesStackView = _modulesStackView;
@synthesize moduleTintColor = _moduleTintColor;
@synthesize modulesPerRow = _modulesPerRow;
@synthesize moduleSpacing = _moduleSpacing;
@synthesize isExpanded = _isExpanded;

#pragma mark - Constants

static const CGFloat kDefaultModuleSpacing = 8.0;
static const NSInteger kDefaultModulesPerRow = 2;
static const CGFloat kSectionLabelHeight = 18.0;
static const CGFloat kSectionTopPadding = 8.0;
static const CGFloat kSectionBottomPadding = 4.0;

#pragma mark - Initialization

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _modulesPerRow = kDefaultModulesPerRow;
        _moduleSpacing = kDefaultModuleSpacing;
        _isExpanded = NO;
        _moduleTintColor = [UIColor whiteColor];
        _arr = [NSMutableArray array];
        _modules = [NSMutableArray array];
        _stackViews = [NSArray array];

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
    _sectionLabel.text = @"Modules";
    _sectionLabel.numberOfLines = 1;
    [self addSubview:_sectionLabel];

    // The main vertical stack view holds rows of modules
    _modulesStackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    _modulesStackView.translatesAutoresizingMaskIntoConstraints = NO;
    _modulesStackView.axis = UILayoutConstraintAxisVertical;
    _modulesStackView.alignment = UIStackViewAlignmentFill;
    _modulesStackView.distribution = UIStackViewDistributionFillEqually;
    _modulesStackView.spacing = _moduleSpacing;
    [self addSubview:_modulesStackView];
}

- (void)setupConstraints {
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray array];

    // Section label pinned to top
    [constraints addObject:[_sectionLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16]];
    [constraints addObject:[_sectionLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:kSectionTopPadding]];
    [constraints addObject:[_sectionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16]];
    [constraints addObject:[_sectionLabel.heightAnchor constraintEqualToConstant:kSectionLabelHeight]];

    // Stack view fills remaining area below section label
    [constraints addObject:[_modulesStackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor]];
    [constraints addObject:[_modulesStackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]];
    [constraints addObject:[_modulesStackView.topAnchor constraintEqualToAnchor:_sectionLabel.bottomAnchor constant:kSectionBottomPadding]];

    // Height constraint - initially zero, updated in layoutSubviews
    _heightConstraint = [self.heightAnchor constraintEqualToConstant:0];
    _heightConstraint.priority = UILayoutPriorityDefaultHigh;
    [constraints addObject:_heightConstraint];

    // Bottom of stack view pins to bottom of self
    [constraints addObject:[_modulesStackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]];

    [NSLayoutConstraint activateConstraints:constraints];
}

#pragma mark - Reload

- (void)reload {
    // Remove all existing arranged subviews from the stack
    for (UIView *view in _modulesStackView.arrangedSubviews) {
        [view removeFromSuperview];
    }
    [_arr removeAllObjects];

    if (!_modules || _modules.count == 0) {
        [self setNeedsLayout];
        return;
    }

    NSArray *modulesToShow = _modules;
    NSUInteger totalModules = modulesToShow.count;

    // Calculate number of rows needed based on modulesPerRow
    NSUInteger rows = (totalModules + (NSUInteger)_modulesPerRow - 1) / (NSUInteger)_modulesPerRow;

    // Build row stack views
    NSMutableArray *rowStackViews = [NSMutableArray array];

    for (NSUInteger row = 0; row < rows; row++) {
        UIStackView *rowStack = [[UIStackView alloc] initWithFrame:CGRectZero];
        rowStack.translatesAutoresizingMaskIntoConstraints = NO;
        rowStack.axis = UILayoutConstraintAxisHorizontal;
        rowStack.alignment = UIStackViewAlignmentFill;
        rowStack.distribution = UIStackViewDistributionFillEqually;
        rowStack.spacing = _moduleSpacing;

        NSUInteger startIdx = row * (NSUInteger)_modulesPerRow;
        for (NSInteger col = 0; col < _modulesPerRow; col++) {
            NSUInteger moduleIdx = startIdx + (NSUInteger)col;
            if (moduleIdx >= totalModules) {
                // Fill remaining slots with empty spacer views
                UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
                spacer.translatesAutoresizingMaskIntoConstraints = NO;
                [rowStack addArrangedSubview:spacer];
                continue;
            }

            id moduleData = modulesToShow[moduleIdx];
            UIView *moduleView = nil;

            if ([moduleData isKindOfClass:[UIView class]]) {
                moduleView = (UIView *)moduleData;
            } else if ([moduleData isKindOfClass:[NSString class]]) {
                // Create a small module for the identifier
                JadeSmallModule *smallModule = [[JadeSmallModule alloc] initWithFrame:CGRectZero];
                [smallModule setValue:moduleData forKey:@"identifier"];
                moduleView = smallModule;
            }

            if (moduleView) {
                moduleView.translatesAutoresizingMaskIntoConstraints = NO;
                [rowStack addArrangedSubview:moduleView];
                [_arr addObject:moduleView];
            } else {
                UIView *spacer = [[UIView alloc] initWithFrame:CGRectZero];
                spacer.translatesAutoresizingMaskIntoConstraints = NO;
                [rowStack addArrangedSubview:spacer];
            }
        }

        [_modulesStackView addArrangedSubview:rowStack];
        [rowStackViews addObject:rowStack];
    }

    _stackViews = [rowStackViews copy];

    // Apply consistent theme
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

    [self setNeedsLayout];
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    // Update height constraint based on the stack view's intrinsic content height
    CGFloat stackHeight = _modulesStackView.intrinsicContentSize.height;
    if (stackHeight <= 0) {
        // Fall back to calculating height from arranged subviews
        CGFloat calculatedHeight = 0;
        NSUInteger rowCount = _modulesStackView.arrangedSubviews.count;
        if (rowCount > 0) {
            CGFloat totalSpacing = (CGFloat)(rowCount - 1) * _moduleSpacing;
            CGFloat availableWidth = self.bounds.size.width;
            if (availableWidth > 0) {
                CGFloat cellWidth = (availableWidth - (_modulesPerRow - 1) * _moduleSpacing) / (CGFloat)_modulesPerRow;
                // Module cells are roughly square for small modules
                calculatedHeight = (cellWidth * (CGFloat)rowCount) + totalSpacing;
            }
        }
        stackHeight = calculatedHeight;
    }

    if (stackHeight > 0) {
        _heightConstraint.constant = kSectionTopPadding + kSectionLabelHeight + kSectionBottomPadding + stackHeight;
    }

    // Layout modules in grid formation if needed
    [self layoutModulesInGrid];
}

- (void)layoutModulesInGrid {
    // Ensure all arranged row subviews have equal heights
    // and all module views within each row have proper sizing
    for (UIStackView *rowStack in _modulesStackView.arrangedSubviews) {
        if (![rowStack isKindOfClass:[UIStackView class]]) continue;
        for (UIView *moduleView in rowStack.arrangedSubviews) {
            // Ensure the module view fills its cell
            moduleView.translatesAutoresizingMaskIntoConstraints = NO;
        }
    }
}

#pragma mark - Modules Property

- (NSMutableArray<UIView *> *)modules {
    return _modules;
}

- (void)setModules:(NSMutableArray<UIView *> *)modules {
    _modules = [modules mutableCopy];
    [self reload];
}

#pragma mark - Module Management

- (void)addModule:(UIView *)module {
    if (!module) return;
    NSMutableArray *mutableModules = [_modules mutableCopy] ?: [NSMutableArray array];
    [mutableModules addObject:module];
    _modules = mutableModules;
    [self reload];
}

- (void)removeModule:(UIView *)module {
    if (!module) return;
    NSMutableArray *mutableModules = [_modules mutableCopy];
    if ([mutableModules containsObject:module]) {
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
    [self reload];

    if (animated) {
        [UIView animateWithDuration:0.3 animations:^{
            [self.superview layoutIfNeeded];
        }];
    }
}

- (void)reorderModules {
    // Default order is insertion order; subclasses may override
    [self reload];
}

- (void)clearAllModules {
    _modules = [NSMutableArray array];
    [self reload];
}


@end
