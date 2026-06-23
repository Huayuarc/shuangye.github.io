#import "AkaraConnectivity.h"
#import "AkaraCommon.h"
#import <QuartzCore/QuartzCore.h>

static NSString * const AKRCellReuseIdentifier = @"AkaraConnectivityCell";
static NSString * const AKRSystemConnectivityBundlePath = @"/System/Library/ControlCenter/Bundles/ConnectivityModule.bundle";

static NSBundle *AKRSystemConnectivityBundle(void) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bundle = [NSBundle bundleWithPath:AKRSystemConnectivityBundlePath];
        [bundle load];
    });
    return bundle;
}

static id AKRLocalPreferenceValue(NSArray<NSString *> *keys) {
    return AKRPreferenceValue(keys);
}

static BOOL AKRLocalPreferenceBool(NSArray<NSString *> *keys, BOOL defaultValue) {
    return AKRPreferenceBool(keys, defaultValue);
}

static NSDictionary<NSString *, NSString *> *AKRToggleNameMap(void) {
    return @{
        @"1": @"Airplane",
        @"2": @"Wi-Fi",
        @"3": @"Bluetooth",
        @"4": @"Cellular",
        @"5": @"Hotspot",
        @"6": @"AirDrop",
        @"airplane": @"Airplane",
        @"wifi": @"Wi-Fi",
        @"wi-fi": @"Wi-Fi",
        @"bluetooth": @"Bluetooth",
        @"cellular": @"Cellular",
        @"cellular-data": @"Cellular",
        @"hotspot": @"Hotspot",
        @"airdrop": @"AirDrop"
    };
}

static NSString *AKRCanonicalToggleName(id value) {
    if ([value isKindOfClass:NSNumber.class]) {
        value = [(NSNumber *)value stringValue];
    }
    if (![value isKindOfClass:NSString.class]) {
        return nil;
    }

    NSString *stringValue = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (stringValue.length == 0) {
        return nil;
    }

    NSDictionary *map = AKRToggleNameMap();
    NSString *mappedValue = map[stringValue.lowercaseString] ?: map[stringValue];
    if (mappedValue) {
        return mappedValue;
    }

    NSArray<NSString *> *knownNames = @[@"Airplane", @"Wi-Fi", @"Bluetooth", @"Cellular", @"Hotspot", @"AirDrop"];
    for (NSString *knownName in knownNames) {
        if ([knownName caseInsensitiveCompare:stringValue] == NSOrderedSame) {
            return knownName;
        }
    }
    return nil;
}

static NSArray<NSString *> *AKRToggleNamesFromPreference(id value, NSArray<NSString *> *defaultNames) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    if ([value isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)value) {
            NSString *name = AKRCanonicalToggleName(item);
            if (name && ![result containsObject:name]) {
                [result addObject:name];
            }
        }
    } else if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) {
        NSString *stringValue = [value isKindOfClass:NSNumber.class] ? [(NSNumber *)value stringValue] : (NSString *)value;
        NSArray<NSString *> *components = [stringValue componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",;| "]];
        if (components.count <= 1 && stringValue.length > 1) {
            NSMutableArray<NSString *> *characters = [NSMutableArray array];
            for (NSUInteger index = 0; index < stringValue.length; index++) {
                [characters addObject:[stringValue substringWithRange:NSMakeRange(index, 1)]];
            }
            components = characters;
        }

        for (NSString *component in components) {
            NSString *name = AKRCanonicalToggleName(component);
            if (name && ![result containsObject:name]) {
                [result addObject:name];
            }
        }
    }

    return result.count > 0 ? result.copy : defaultNames;
}

static NSString *AKRLocalizationKeyForToggle(NSString *toggleName) {
    NSDictionary<NSString *, NSString *> *keys = @{
        @"Airplane": @"CONTROL_CENTER_STATUS_AIRPLANE_MODE_NAME",
        @"Wi-Fi": @"CONTROL_CENTER_STATUS_WIFI_NAME",
        @"Bluetooth": @"CONTROL_CENTER_STATUS_BLUETOOTH_NAME",
        @"Cellular": @"CONTROL_CENTER_STATUS_CELLULAR_DATA_NAME",
        @"Hotspot": @"CONTROL_CENTER_STATUS_HOTSPOT_NAME",
        @"AirDrop": @"CONTROL_CENTER_STATUS_AIRDROP_NAME"
    };
    return keys[toggleName];
}

static NSString *AKRDisplayNameForToggle(NSString *toggleName, BOOL nativeLabels) {
    if (nativeLabels) {
        NSString *key = AKRLocalizationKeyForToggle(toggleName);
        NSString *localized = [AKRSystemConnectivityBundle() localizedStringForKey:key value:nil table:nil];
        if (localized.length > 0 && ![localized isEqualToString:key]) {
            return localized;
        }
    }

    NSDictionary<NSString *, NSString *> *fallbacks = @{
        @"Airplane": @"Airplane",
        @"Wi-Fi": @"Wi-Fi",
        @"Bluetooth": @"Bluetooth",
        @"Cellular": @"Cellular",
        @"Hotspot": @"Hotspot",
        @"AirDrop": @"AirDrop"
    };
    return fallbacks[toggleName] ?: toggleName;
}

static NSString *AKRSubtitleForToggle(NSString *toggleName) {
    NSDictionary<NSString *, NSString *> *subtitles = @{
        @"Airplane": @"System Toggle",
        @"Wi-Fi": @"Network",
        @"Bluetooth": @"Devices",
        @"Cellular": @"Data",
        @"Hotspot": @"Sharing",
        @"AirDrop": @"Receiving"
    };
    return subtitles[toggleName] ?: @"System Toggle";
}

static NSString *AKRSymbolNameForToggle(NSString *toggleName) {
    NSDictionary<NSString *, NSString *> *symbols = @{
        @"Airplane": @"airplane",
        @"Wi-Fi": @"wifi",
        @"Bluetooth": @"dot.radiowaves.left.and.right",
        @"Cellular": @"antenna.radiowaves.left.and.right",
        @"Hotspot": @"personalhotspot",
        @"AirDrop": @"airdrop"
    };
    return symbols[toggleName] ?: @"circle.grid.2x2";
}

static UIColor *AKRColorForToggle(NSString *toggleName) {
    NSDictionary<NSString *, UIColor *> *colors = @{
        @"Airplane": UIColor.systemOrangeColor,
        @"Wi-Fi": UIColor.systemBlueColor,
        @"Bluetooth": UIColor.systemBlueColor,
        @"Cellular": UIColor.systemGreenColor,
        @"Hotspot": UIColor.systemGreenColor,
        @"AirDrop": UIColor.systemPurpleColor
    };
    return colors[toggleName] ?: UIColor.systemBlueColor;
}

static UIImage *AKRImageForToggle(NSString *toggleName) {
    NSString *symbolName = AKRSymbolNameForToggle(toggleName);
    UIImage *image = nil;
    if ([UIImage respondsToSelector:@selector(systemImageNamed:)]) {
        image = [UIImage systemImageNamed:symbolName];
        if (!image) {
            image = [UIImage systemImageNamed:@"circle.grid.2x2"];
        }
    }
    return image;
}

static void AKRSafelySetValue(id object, NSString *key, id value) {
    if (!object || !key || !value) {
        return;
    }

    @try {
        [object setValue:value forKey:key];
    } @catch (NSException *exception) {
    }
}

static NSArray<NSString *> *AKRAllToggleNames(AkaraConnectivityModuleContentViewController *controller) {
    NSArray<NSString *> *first = controller.firstToggleNames ?: @[];
    NSArray<NSString *> *second = controller.secondToggleNames ?: @[];
    return [first arrayByAddingObjectsFromArray:second];
}

@interface AkaraConnectivityCollectionViewCell ()
- (void)configureWithToggleName:(NSString *)toggleName parentViewController:(UIViewController *)parentViewController;
@end

@implementation AkaraConnectivityCollectionViewCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = UIColor.clearColor;
        self.backgroundColor = UIColor.clearColor;
    }
    return self;
}

- (void)configureWithToggleName:(NSString *)toggleName parentViewController:(UIViewController *)parentViewController {
    [self cleanupViewControllerContainment];
    self.toggleName = toggleName;
    [self setup];

    if (self.roundButtonViewController && !self.roundButtonViewController.parentViewController) {
        [parentViewController addChildViewController:self.roundButtonViewController];
        [self.roundButtonViewController didMoveToParentViewController:parentViewController];
    }
}

- (void)setup {
    [self setupContainerView];
    [self setupRoundButtonView];
    [self setupDoubleTextView];
}

- (void)setupContainerView {
    [self.contentView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    self.containerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.containerView.backgroundColor = UIColor.clearColor;
    [self.contentView addSubview:self.containerView];

    [NSLayoutConstraint activateConstraints:@[
        [self.containerView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [self.containerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [self.containerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [self.containerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor]
    ]];
}

- (void)setupRoundButtonView {
    self.roundButtonViewController = [[AkaraConnectivityRoundButtonViewController alloc] initWithButtonName:self.toggleName];
    UIView *buttonView = self.roundButtonViewController.view;
    buttonView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.containerView addSubview:buttonView];

    CGFloat buttonSize = CGRectGetHeight(self.bounds) > 130.0 ? 58.0 : 52.0;
    [NSLayoutConstraint activateConstraints:@[
        [buttonView.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],
        [buttonView.topAnchor constraintEqualToAnchor:self.containerView.topAnchor constant:6.0],
        [buttonView.widthAnchor constraintEqualToConstant:buttonSize],
        [buttonView.heightAnchor constraintEqualToConstant:buttonSize]
    ]];
}

- (void)setupDoubleTextView {
    self.doubleTextView = [[AkaraConnectivityToggleDoubleTextView alloc] initWithPrimaryLabelText:AKRDisplayNameForToggle(self.toggleName, self.useNativeConnectivityLabels)];
    self.doubleTextView.secondaryNameLabel.text = AKRSubtitleForToggle(self.toggleName);
    self.doubleTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.containerView addSubview:self.doubleTextView];

    [NSLayoutConstraint activateConstraints:@[
        [self.doubleTextView.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:2.0],
        [self.doubleTextView.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-2.0],
        [self.doubleTextView.topAnchor constraintEqualToAnchor:self.roundButtonViewController.view.bottomAnchor constant:6.0],
        [self.doubleTextView.bottomAnchor constraintLessThanOrEqualToAnchor:self.containerView.bottomAnchor constant:-2.0]
    ]];
}

- (BOOL)useNativeConnectivityLabels {
    return AKRLocalPreferenceBool(@[@"akaraUseNativeConnectivityLabels", @"useNativeConnectivityLabels", @"useNativeConnectivityLabelNames", @"nativeConnectivityLabels"], YES);
}

- (void)updateNotExpandedConnectivityButtons {
    self.doubleTextView.primaryLabel.text = AKRDisplayNameForToggle(self.toggleName, self.useNativeConnectivityLabels);
    self.doubleTextView.secondaryNameLabel.text = AKRSubtitleForToggle(self.toggleName);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self cleanupViewControllerContainment];
    self.toggleName = nil;
    self.containerView = nil;
    self.roundButtonViewController = nil;
    self.doubleTextView = nil;
}

- (void)cleanupViewControllerContainment {
    if (self.roundButtonViewController.parentViewController) {
        [self.roundButtonViewController willMoveToParentViewController:nil];
        [self.roundButtonViewController.view removeFromSuperview];
        [self.roundButtonViewController removeFromParentViewController];
    }
    [self.contentView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
}

@end

@implementation AkaraConnectivityModuleContentViewController

@synthesize preferredExpandedContentHeight = _preferredExpandedContentHeight;
@synthesize preferredExpandedContentWidth = _preferredExpandedContentWidth;
@synthesize providesOwnPlatter = _providesOwnPlatter;
@synthesize expanded = _expanded;

- (instancetype)initWithModuleIdentifier:(id)identifier options:(NSDictionary *)options {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _expanded = NO;
        _providesOwnPlatter = YES;
        _preferredExpandedContentWidth = 320.0;
        _preferredExpandedContentHeight = 330.0;

        NSArray<NSString *> *defaultFirst = @[@"Airplane", @"Wi-Fi", @"Bluetooth"];
        NSArray<NSString *> *defaultSecond = @[@"Cellular", @"Hotspot", @"AirDrop"];
        _firstToggleNames = AKRToggleNamesFromPreference(AKRLocalPreferenceValue(@[@"akaraConnectivityFirstRowOrder", @"connectivityFirstRowOrder", @"connectivityFirstPageOrder", @"firstPageOrder"]), defaultFirst);
        _secondToggleNames = AKRToggleNamesFromPreference(AKRLocalPreferenceValue(@[@"akaraConnectivitySecondRowOrder", @"connectivitySecondRowOrder", @"connectivitySecondPageOrder", @"secondPageOrder"]), defaultSecond);
        _connectivityToggles = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    [self setup];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateNotExpandedConnectivityButtons];

    if (AKRLocalPreferenceBool(@[@"akaraScrollBackToFirstConnectivityPage", @"scrollBackToFirstConnectivityPage", @"resetConnectivityPageWhenOpened"], NO)) {
        [self scrollBackToFirstPage];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self.connectivityCollectionView.collectionViewLayout invalidateLayout];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
        [weakSelf.connectivityCollectionView.collectionViewLayout invalidateLayout];
    }];
}

- (void)setup {
    [self setupCollectionView];
    [self setupExpandedStateVC];
    [self updateNotExpandedConnectivityButtons];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateNotExpandedConnectivityButtons) name:@"akaraUpdateNotExpandedSubtitleLabelsNotification" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scrollBackToFirstPage) name:@"akaraScrollBackToFirstConnectivityPageNotification" object:nil];
}

- (void)setupCollectionView {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = 0.0;
    layout.minimumInteritemSpacing = 0.0;

    self.connectivityCollectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.connectivityCollectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.connectivityCollectionView.delegate = self;
    self.connectivityCollectionView.dataSource = self;
    self.connectivityCollectionView.backgroundColor = UIColor.clearColor;
    self.connectivityCollectionView.pagingEnabled = YES;
    self.connectivityCollectionView.showsHorizontalScrollIndicator = NO;
    self.connectivityCollectionView.alwaysBounceHorizontal = NO;
    self.connectivityCollectionView.clipsToBounds = YES;
    [self.connectivityCollectionView registerClass:AkaraConnectivityCollectionViewCell.class forCellWithReuseIdentifier:AKRCellReuseIdentifier];

    [self.view addSubview:self.connectivityCollectionView];
    [NSLayoutConstraint activateConstraints:@[
        [self.connectivityCollectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.connectivityCollectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.connectivityCollectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.connectivityCollectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupExpandedStateVC {
    self.connectivityExpandedViewController = nil;
}

- (BOOL)shouldBeginTransitionToExpandedContentModule {
    return YES;
}

- (BOOL)shouldFinishTransitionToExpandedContentModule {
    return YES;
}

- (BOOL)canDismissPresentedContent {
    return YES;
}

- (void)willTransitionToExpandedContentMode:(BOOL)expanded {
    _expanded = expanded;
    if (expanded) {
        [self updateExpandedConnectivityButtons];
    } else {
        [self updateNotExpandedConnectivityButtons];
    }
}

- (void)didTransitionToExpandedContentMode:(BOOL)expanded {
    _expanded = expanded;
    [self.connectivityCollectionView.collectionViewLayout invalidateLayout];
}

- (void)controlCenterWillPresent {
    if (AKRLocalPreferenceBool(@[@"akaraScrollBackToFirstConnectivityPage", @"scrollBackToFirstConnectivityPage", @"resetConnectivityPageWhenOpened"], NO)) {
        [self scrollBackToFirstPage];
    }
    [self updateNotExpandedConnectivityButtons];
}

- (void)controlCenterDidDismiss {
}

- (void)updateNotExpandedConnectivityButtons {
    UIViewController *expandedViewController = (UIViewController *)self.connectivityExpandedViewController;
    expandedViewController.view.hidden = YES;
    self.connectivityCollectionView.hidden = NO;
    [self.connectivityCollectionView reloadData];
}

- (void)updateExpandedConnectivityButtons {
    UIViewController *expandedViewController = (UIViewController *)self.connectivityExpandedViewController;
    if (expandedViewController) {
        expandedViewController.view.hidden = NO;
        self.connectivityCollectionView.hidden = YES;
    } else {
        self.connectivityCollectionView.hidden = NO;
        [self.connectivityCollectionView reloadData];
    }
}

- (void)scrollBackToFirstPage {
    if (!self.connectivityCollectionView) {
        return;
    }
    [self.connectivityCollectionView setContentOffset:CGPointZero animated:NO];
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)AKRAllToggleNames(self).count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    AkaraConnectivityCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:AKRCellReuseIdentifier forIndexPath:indexPath];
    NSArray<NSString *> *toggleNames = AKRAllToggleNames(self);
    if ((NSUInteger)indexPath.item < toggleNames.count) {
        [cell configureWithToggleName:toggleNames[(NSUInteger)indexPath.item] parentViewController:self];
    }
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat height = MAX(CGRectGetHeight(collectionView.bounds), 96.0);
    CGFloat width = MAX(floor(CGRectGetWidth(collectionView.bounds) / 3.0), 86.0);
    if (self.isExpanded && !self.connectivityExpandedViewController) {
        width = floor(CGRectGetWidth(collectionView.bounds) / 3.0);
        height = floor(CGRectGetHeight(collectionView.bounds) / 2.0);
    }
    return CGSizeMake(width, height);
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    return 0.0;
}

- (CGFloat)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout minimumLineSpacingForSectionAtIndex:(NSInteger)section {
    return 0.0;
}

@end

@implementation AkaraConnectivityRoundButtonViewController

- (instancetype)initWithButtonName:(NSString *)buttonName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _buttonName = [buttonName copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setup];
}

- (void)setup {
    self.view.backgroundColor = UIColor.clearColor;
    [self setupButton:self.buttonName];
}

- (void)setupButton:(NSString *)buttonName {
    [self setupRoundButtonView];
}

- (void)setupRoundButtonView {
    UIImage *image = AKRImageForToggle(self.buttonName);
    UIColor *highlightColor = AKRColorForToggle(self.buttonName);
    Class roundButtonClass = NSClassFromString(@"CCUIRoundButton");
    UIControl *roundButton = nil;

    if (roundButtonClass && [roundButtonClass isSubclassOfClass:UIControl.class]) {
        @try {
            roundButton = [(UIControl *)[roundButtonClass alloc] initWithFrame:CGRectZero];
            AKRSafelySetValue(roundButton, @"glyphImage", image);
            AKRSafelySetValue(roundButton, @"highlightColor", highlightColor);
        } @catch (NSException *exception) {
            roundButton = nil;
        }
    }

    if (!roundButton) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setImage:image forState:UIControlStateNormal];
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = [highlightColor colorWithAlphaComponent:0.92];
        button.layer.cornerRadius = 26.0;
        button.clipsToBounds = YES;
        roundButton = button;
    }

    roundButton.translatesAutoresizingMaskIntoConstraints = NO;
    roundButton.accessibilityLabel = AKRDisplayNameForToggle(self.buttonName, self.useNativeConnectivityLabels);
    [roundButton addTarget:self action:@selector(fallbackButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
    self.ccRoundButton = roundButton;
    [self.view addSubview:roundButton];

    [NSLayoutConstraint activateConstraints:@[
        [roundButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [roundButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [roundButton.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [roundButton.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)fallbackButtonPressed:(UIControl *)sender {
    [UIView animateWithDuration:0.12 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.18 animations:^{
            sender.transform = CGAffineTransformIdentity;
        }];
    }];
}

- (BOOL)useNativeConnectivityLabels {
    return AKRLocalPreferenceBool(@[@"akaraUseNativeConnectivityLabels", @"useNativeConnectivityLabels", @"useNativeConnectivityLabelNames", @"nativeConnectivityLabels"], YES);
}

@end

@implementation AkaraConnectivityToggleDoubleTextView

- (instancetype)initWithPrimaryLabelText:(NSString *)text {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _primaryLabelText = [text copy];
        [self setup];
    }
    return self;
}

- (void)setup {
    self.backgroundColor = UIColor.clearColor;
    [self setupContainerView];
    [self setupPrimaryLabel];
    [self setupSecondaryNameLabel];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateLabelColorWithNotification:) name:@"akaraUpdateDoubleTextViewSecondaryLabelColorNotification" object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setupContainerView {
    self.containerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.containerView.backgroundColor = UIColor.clearColor;
    [self addSubview:self.containerView];

    [NSLayoutConstraint activateConstraints:@[
        [self.containerView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.containerView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.containerView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [self.containerView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor]
    ]];
}

- (void)setupPrimaryLabel {
    self.primaryLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.primaryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.primaryLabel.text = self.primaryLabelText;
    self.primaryLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.primaryLabel.textColor = UIColor.labelColor;
    self.primaryLabel.textAlignment = NSTextAlignmentCenter;
    self.primaryLabel.adjustsFontSizeToFitWidth = YES;
    self.primaryLabel.minimumScaleFactor = 0.72;
    [self.containerView addSubview:self.primaryLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.primaryLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor],
        [self.primaryLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor],
        [self.primaryLabel.topAnchor constraintEqualToAnchor:self.containerView.topAnchor]
    ]];
}

- (void)setupSecondaryNameLabel {
    self.secondaryNameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.secondaryNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.secondaryNameLabel.text = @"System Toggle";
    self.secondaryNameLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightRegular];
    self.secondaryNameLabel.textColor = [UIColor.secondaryLabelColor colorWithAlphaComponent:0.86];
    self.secondaryNameLabel.textAlignment = NSTextAlignmentCenter;
    self.secondaryNameLabel.adjustsFontSizeToFitWidth = YES;
    self.secondaryNameLabel.minimumScaleFactor = 0.7;
    [self.containerView addSubview:self.secondaryNameLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.secondaryNameLabel.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor],
        [self.secondaryNameLabel.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor],
        [self.secondaryNameLabel.topAnchor constraintEqualToAnchor:self.primaryLabel.bottomAnchor constant:1.0],
        [self.secondaryNameLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.containerView.bottomAnchor]
    ]];
}

- (void)updateLabelColorWithNotification:(NSNotification *)notification {
    UIColor *color = notification.userInfo[@"color"];
    if ([color isKindOfClass:UIColor.class]) {
        self.secondaryNameLabel.textColor = color;
    } else {
        self.secondaryNameLabel.textColor = [UIColor.secondaryLabelColor colorWithAlphaComponent:0.86];
    }
}

@end

@implementation AkaraConnectivityToggleViewController

- (instancetype)initWithToggleName:(NSString *)toggleName {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _toggleName = [toggleName copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setup];
}

- (void)setup {
    self.view.backgroundColor = UIColor.clearColor;
    [self setupContainerView];
    [self setupToggleStackView];
    [self setupToggle];
}

- (void)setupToggleStackView {
    self.toggleStackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    self.toggleStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.toggleStackView.axis = UILayoutConstraintAxisVertical;
    self.toggleStackView.alignment = UIStackViewAlignmentCenter;
    self.toggleStackView.distribution = UIStackViewDistributionFill;
    self.toggleStackView.spacing = 6.0;
    [self.containerView addSubview:self.toggleStackView];

    [NSLayoutConstraint activateConstraints:@[
        [self.toggleStackView.centerXAnchor constraintEqualToAnchor:self.containerView.centerXAnchor],
        [self.toggleStackView.centerYAnchor constraintEqualToAnchor:self.containerView.centerYAnchor],
        [self.toggleStackView.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.containerView.leadingAnchor],
        [self.toggleStackView.trailingAnchor constraintLessThanOrEqualToAnchor:self.containerView.trailingAnchor]
    ]];
}

- (void)setupToggle {
    [self setupRoundButtonView];
    self.doubleTextView = [[AkaraConnectivityToggleDoubleTextView alloc] initWithPrimaryLabelText:AKRDisplayNameForToggle(self.toggleName, self.useNativeConnectivityLabels)];
    self.doubleTextView.secondaryNameLabel.text = AKRSubtitleForToggle(self.toggleName);
    [self.toggleStackView addArrangedSubview:self.doubleTextView];
    [NSLayoutConstraint activateConstraints:@[
        [self.doubleTextView.widthAnchor constraintEqualToAnchor:self.containerView.widthAnchor]
    ]];
}

- (void)setupContainerView {
    self.containerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.containerView.backgroundColor = UIColor.clearColor;
    [self.view addSubview:self.containerView];

    [NSLayoutConstraint activateConstraints:@[
        [self.containerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.containerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.containerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.containerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupRoundButtonView {
    self.roundButtonViewController = [[AkaraConnectivityRoundButtonViewController alloc] initWithButtonName:self.toggleName];
    [self addChildViewController:self.roundButtonViewController];
    [self.toggleStackView addArrangedSubview:self.roundButtonViewController.view];
    [NSLayoutConstraint activateConstraints:@[
        [self.roundButtonViewController.view.widthAnchor constraintEqualToConstant:56.0],
        [self.roundButtonViewController.view.heightAnchor constraintEqualToConstant:56.0]
    ]];
    [self.roundButtonViewController didMoveToParentViewController:self];
}

- (BOOL)useNativeConnectivityLabels {
    return AKRLocalPreferenceBool(@[@"akaraUseNativeConnectivityLabels", @"useNativeConnectivityLabels", @"useNativeConnectivityLabelNames", @"nativeConnectivityLabels"], YES);
}

@end
