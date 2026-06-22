#import "Tweak.h"
#import "CC26Preferences/CC26LocalizableManager.h"

#pragma mark - Runtime safety helpers

static BOOL cc26_isSpringBoardProcess(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

static BOOL cc26_hooksInitialized = NO;

static NSString *cc26_preferencesPath(BOOL rootlessPath) {
    NSString *relativePath = @"/var/mobile/Library/Preferences/com.cureux.cc26.plist";
    return rootlessPath ? ROOT_PATH_NS_VAR(relativePath) : relativePath;
}

static NSDictionary *cc26_preferencesDictionary(void) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:cc26_preferencesPath(YES)];
    if (!preferences) {
        preferences = [NSDictionary dictionaryWithContentsOfFile:cc26_preferencesPath(NO)];
    }
    return preferences ?: @{};
}

static id cc26_preferenceObject(NSString *key) {
    id value = [[[NSUserDefaults standardUserDefaults] persistentDomainForName:domain] objectForKey:key];
    if (!value) {
        value = cc26_preferencesDictionary()[key];
    }
    return value;
}

static id cc26_getIvarObject(id object, const char *ivarName) {
    if (!object || !ivarName) return nil;

    Ivar ivar = NULL;
    Class cls = object_getClass(object);
    while (cls && !ivar) {
        ivar = class_getInstanceVariable(cls, ivarName);
        cls = class_getSuperclass(cls);
    }
    if (!ivar) return nil;

    id value = nil;
    @try {
        value = object_getIvar(object, ivar);
    } @catch (NSException *exception) {
        NSLog(@"[CC26] Failed to read ivar %s on %@: %@", ivarName, object, exception);
    }
    return value;
}

#pragma mark - Border radius helpers

CGFloat getModuleRadius(UIView *moduleView) {
    CGFloat width = moduleView.frame.size.width;
    CGFloat height = moduleView.frame.size.height;
    if ((width < 100 && height < 100) && width == height) { // 1x1 module
        return width / 2;
    } else if ((width > height) || (height > width)) {
        return fminf(width, height) / 2; // Rectangular module
    } else if ((width > 100 && height > 100) && width == height) { // large square module
        return width / 4;
    } else  if (width > 100 && height > 100) { // 1x1 module
        return width / 4;
    }
    return 0; // may need more cases for odd shaped modules such as CCSupport's 2x4 module
}

NSArray *findAllSubviewsOfClass(UIView *view, Class cls) {
    if (!view || !cls) return @[];

    NSMutableArray *result = [NSMutableArray array];
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:cls]) [result addObject:sub];
        [result addObjectsFromArray:findAllSubviewsOfClass(sub, cls)];
    }
    return result;
}

UIView *findSubviewOfClass(UIView *view, Class cls) {
    if (!view || !cls) return nil;

    if ([view isKindOfClass:cls]) return view;
    for (UIView *subview in view.subviews) {
        UIView *match = findSubviewOfClass(subview, cls);
        if (match) return match;
    }
    return nil;
}

UIView *findSubviewWithClassNameContaining(UIView *view, NSString *needle) {
    if (!view || needle.length == 0) return nil;

    if ([NSStringFromClass([view class]) rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return view;
    for (UIView *subview in view.subviews) {
        UIView *match = findSubviewWithClassNameContaining(subview, needle);
        if (match) return match;
    }
    return nil;
}


#pragma mark - Media module helpers

static BOOL cc26_isInsideContentModule(UIView *view) {
    UIView *ancestor = view;
    while (ancestor) {
        if ([ancestor isKindOfClass:%c(CCUIContentModuleContentContainerView)]) return YES;
        ancestor = ancestor.superview;
    }
    return NO;
}

static MRUNowPlayingView *cc26_parentNowPlayingView(UIView *view) {
    UIView *ancestor = view;
    while (ancestor) {
        if ([ancestor isKindOfClass:%c(MRUNowPlayingView)]) return (MRUNowPlayingView *)ancestor;
        ancestor = ancestor.superview;
    }
    return nil;
}

static BOOL cc26_isCompactNowPlaying(UIView *view) {
    if (!cc26_isInsideContentModule(view)) return NO;
    MRUNowPlayingView *nowPlayingView = cc26_parentNowPlayingView(view);
    if (!nowPlayingView) return NO;

    @try {
        NSInteger layout = [[nowPlayingView valueForKey:@"_layout"] integerValue];
        if (layout == 1 || layout == 2) return NO;
    } @catch (NSException *exception) {}
    return YES;
}

static void cc26_forceSubviewOpacity(UIView *view) {
    if (!view) return;

    view.alpha = 1.0;
    view.layer.opacity = 1.0;
    for (UIView *subview in view.subviews) {
        if (!subview.hidden) {
            subview.alpha = 1.0;
            subview.layer.opacity = 1.0;
        }
    }
}

static void cc26_adjustLabelFonts(UIView *view, BOOL titleStyle) {
    if (!view) return;

    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            label.font = [UIFont systemFontOfSize:13.0 weight:titleStyle ? UIFontWeightSemibold : UIFontWeightRegular];
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.72;
            label.textAlignment = NSTextAlignmentLeft;
            label.numberOfLines = 1;
        } else {
            cc26_adjustLabelFonts(subview, titleStyle);
        }
    }
}

static void cc26_applyRoundedModuleLayer(UIView *view, CGFloat radius, CGFloat borderWidth) {
    if (!view) return;

    view.clipsToBounds = YES;
    view.layer.cornerRadius = radius;
    view.layer.continuousCorners = YES;
    view.layer.borderWidth = borderWidth;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    view.layer.masksToBounds = YES;
}

static void cc26_cleanExpandedBackdropViews(UIView *containerView, BOOL preserveModuleView) {
    NSArray *materials = findAllSubviewsOfClass(containerView, %c(MTMaterialView));
    for (UIView *materialView in materials) {
        if (preserveModuleView && materialView == containerView) continue;

        CGRect frameInContainer = [materialView.superview convertRect:materialView.frame toView:containerView];
        CGFloat widthRatio = containerView.bounds.size.width > 0 ? frameInContainer.size.width / containerView.bounds.size.width : 0;
        CGFloat heightRatio = containerView.bounds.size.height > 0 ? frameInContainer.size.height / containerView.bounds.size.height : 0;

        if (widthRatio > 0.72 && heightRatio > 0.72) {
            materialView.alpha = 0.0;
            materialView.hidden = YES;
            materialView.backgroundColor = [UIColor clearColor];
        }
    }
}


#pragma mark - Slider glyph coloring helpers

void colorLayers(NSArray *layers, CGColorRef color) {
    if (!layers || !color) return;

    for (CALayer *sublayer in layers) {
        if ([sublayer isMemberOfClass:%c(CAShapeLayer)]) {
            CAShapeLayer *shapelayer = (CAShapeLayer *)sublayer;
            shapelayer.fillColor = color;
            shapelayer.strokeColor = color;
            shapelayer.shadowColor = [UIColor clearColor].CGColor;
        } else if (sublayer.sublayers.count == 0) {
            sublayer.backgroundColor = color;
            sublayer.borderColor = color;
            sublayer.contentsMultiplyColor = color;
            sublayer.shadowColor = [UIColor clearColor].CGColor;
        }
        colorLayers(sublayer.sublayers, color);
    }
}

%group CC26

static const NSInteger CC26OverlayBackdropTag = 26026;

static void cc26_updateOverlayBackdrop(UIView *view, BOOL visible) {
    if (!view) return;

    UIView *existingView = [view viewWithTag:CC26OverlayBackdropTag];
    UIVisualEffectView *backdrop = [existingView isKindOfClass:[UIVisualEffectView class]] ? (UIVisualEffectView *)existingView : nil;

    if (!enabled || !visible) {
        backdrop.alpha = 0.0;
        backdrop.hidden = YES;
        return;
    }

    if (!backdrop) {
        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        backdrop = [[UIVisualEffectView alloc] initWithEffect:effect];
        backdrop.tag = CC26OverlayBackdropTag;
        backdrop.userInteractionEnabled = NO;
        backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        UIView *tintView = [[UIView alloc] initWithFrame:backdrop.contentView.bounds];
        tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tintView.backgroundColor = [UIColor colorWithWhite:0.70 alpha:0.16];
        [backdrop.contentView addSubview:tintView];

        NSUInteger index = MIN((NSUInteger)1, view.subviews.count);
        [view insertSubview:backdrop atIndex:index];
    } else if (backdrop.superview == view) {
        NSUInteger index = MIN((NSUInteger)1, view.subviews.count - 1);
        [view insertSubview:backdrop atIndex:index];
    }

    backdrop.frame = view.bounds;
    backdrop.alpha = 1.0;
    backdrop.hidden = NO;
}

static void cc26_applyModuleMaterialStyle(UIView *containerView, CGFloat radius) {
    containerView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];

    NSArray *materials = findAllSubviewsOfClass(containerView, %c(MTMaterialView));
    for (UIView *materialView in materials) {
        CGFloat materialMin = fminf(materialView.bounds.size.width, materialView.bounds.size.height);
        CGFloat materialRadius = materialMin > 0 ? materialMin / 2.0 : radius;
        materialView.hidden = NO;
        materialView.alpha = 0.86;
        materialView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        materialView.layer.cornerRadius = materialRadius;
        materialView.layer.continuousCorners = YES;
        materialView.clipsToBounds = YES;
    }
}

%hook MRUNowPlayingHeaderView
- (void)layoutSubviews {
    %orig;

    if (!enabled || !cc26_isCompactNowPlaying(self)) return;

    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (width <= 0 || height <= 0) return;

    UIView *artworkView = cc26_getIvarObject(self, "_artworkView");
    UIView *routingButton = cc26_getIvarObject(self, "_routingButton");
    UIView *labelView = cc26_getIvarObject(self, "_labelView");

    CGFloat artworkSize = mediaArtworkSize >= 0 ? mediaArtworkSize : MIN(52.0, height * 0.58);
    artworkSize = MAX(34.0, artworkSize);
    CGFloat routingSize = mediaRoutingBtnSize >= 0 ? mediaRoutingBtnSize : MIN(42.0, artworkSize * 0.84);
    routingSize = MAX(30.0, routingSize);
    CGFloat artworkX = mediaArtworkX >= 0 ? mediaArtworkX : 11.0;
    CGFloat artworkY = mediaArtworkY >= 0 ? mediaArtworkY : 8.0;
    CGFloat routingX = mediaRoutingBtnX >= 0 ? mediaRoutingBtnX : width - routingSize - 12.0;
    CGFloat routingY = mediaRoutingBtnY >= 0 ? mediaRoutingBtnY : artworkY + (artworkSize - routingSize) / 2.0;

    if (artworkView) {
        artworkView.translatesAutoresizingMaskIntoConstraints = YES;
        artworkView.frame = CGRectMake(artworkX, artworkY, artworkSize, artworkSize);
        artworkView.alpha = 1.0;
        artworkView.layer.opacity = 1.0;
        artworkView.layer.cornerRadius = artworkSize * 0.22;
        artworkView.layer.continuousCorners = YES;
        artworkView.layer.masksToBounds = YES;
        artworkView.clipsToBounds = YES;
    }

    if (routingButton) {
        routingButton.translatesAutoresizingMaskIntoConstraints = YES;
        routingButton.frame = CGRectMake(routingX, routingY, routingSize, routingSize);
        routingButton.alpha = 1.0;
        routingButton.layer.opacity = 1.0;
        routingButton.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
        routingButton.layer.cornerRadius = routingSize / 2.0;
        routingButton.layer.continuousCorners = YES;
        routingButton.layer.masksToBounds = YES;
    }

    if (labelView) {
        CGFloat labelX = mediaLabelX >= 0 ? mediaLabelX : 0.0;
        CGFloat labelY = mediaLabelY >= 0 ? mediaLabelY : artworkY + artworkSize + 6.0;
        CGFloat labelW = mediaLabelW >= 0 ? mediaLabelW : width;
        CGFloat labelH = mediaLabelH >= 0 ? mediaLabelH : MAX(height - labelY, 34.0);
        labelView.translatesAutoresizingMaskIntoConstraints = YES;
        labelView.frame = CGRectMake(labelX, labelY, labelW, labelH);
        labelView.clipsToBounds = YES;
        cc26_forceSubviewOpacity(labelView);
    }

    self.clipsToBounds = NO;
    cc26_adjustLabelFonts(self, NO);
}
%end

%hook MPUMarqueeView
- (void)setAlpha:(CGFloat)alpha {
    if (enabled && [self.superview isKindOfClass:%c(MRUNowPlayingLabelView)] && cc26_isCompactNowPlaying(self)) {
        %orig(1.0);
        cc26_forceSubviewOpacity(self);
        return;
    }
    %orig;
}
%end

%hook MRUNowPlayingLabelView
- (void)setAlpha:(CGFloat)alpha {
    if (enabled && cc26_isCompactNowPlaying(self)) {
        %orig(1.0);
        cc26_forceSubviewOpacity(self);
        return;
    }
    %orig;
}
- (void)layoutSubviews {
    %orig;

    if (!enabled || !cc26_isCompactNowPlaying(self)) return;

    UIView *titleMarquee = cc26_getIvarObject(self, "_titleMarqueeView");
    UIView *subtitleMarquee = cc26_getIvarObject(self, "_subtitleMarqueeView");
    UIView *titleLabel = cc26_getIvarObject(self, "_titleLabel");
    UIView *subtitleLabel = cc26_getIvarObject(self, "_subtitleLabel");
    UIView *routeLabel = cc26_getIvarObject(self, "_routeLabel");

    UIView *titleView = titleMarquee ?: titleLabel;
    UIView *subtitleView = subtitleMarquee ?: subtitleLabel;
    if (routeLabel) routeLabel.hidden = YES;

    if (titleView && subtitleView) {
        CGFloat width = self.bounds.size.width;
        CGFloat titleHeight = 16.0;
        CGFloat subtitleHeight = 14.0;
        CGFloat lineSpacing = MAX(0.0, mediaLabelLineSpacing);
        CGFloat totalHeight = titleHeight + lineSpacing + subtitleHeight;
        CGFloat startY = MAX(0.0, (self.bounds.size.height - totalHeight) / 2.0);

        titleView.translatesAutoresizingMaskIntoConstraints = YES;
        subtitleView.translatesAutoresizingMaskIntoConstraints = YES;
        titleView.frame = CGRectMake(0, startY, width, titleHeight);
        subtitleView.frame = CGRectMake(0, startY + titleHeight + lineSpacing, width, subtitleHeight);
        titleView.clipsToBounds = YES;
        subtitleView.clipsToBounds = YES;

        cc26_forceSubviewOpacity(self);
        cc26_forceSubviewOpacity(titleView);
        cc26_forceSubviewOpacity(subtitleView);
        cc26_adjustLabelFonts(titleView, YES);
        cc26_adjustLabelFonts(subtitleView, NO);
    }
}
%end

%hook MRUNowPlayingControlsView
static BOOL cc26ControlsLayoutInProgress = NO;
- (void)layoutSubviews {
    %orig;

    if (!enabled || cc26ControlsLayoutInProgress || !cc26_isCompactNowPlaying(self)) return;
    cc26ControlsLayoutInProgress = YES;

    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    CGFloat padding = 8.0;

    UIView *headerView = cc26_getIvarObject(self, "_headerView");
    if (headerView) {
        CGFloat headerHeight = height * 0.66;
        headerView.translatesAutoresizingMaskIntoConstraints = YES;
        headerView.frame = CGRectMake(padding, padding, width - 2.0 * padding, headerHeight);
        headerView.clipsToBounds = NO;
        [headerView setNeedsLayout];
        [headerView layoutIfNeeded];
    }

    UIView *transportView = cc26_getIvarObject(self, "_transportControlsView");
    if (transportView) {
        CGFloat controlsHeight = transportView.frame.size.height;
        if (controlsHeight < 20.0) controlsHeight = 44.0;
        CGFloat controlsWidth = width * 0.75;
        CGFloat x = (width - controlsWidth) / 2.0;
        CGFloat y = height - controlsHeight - padding;
        transportView.translatesAutoresizingMaskIntoConstraints = YES;
        transportView.frame = CGRectMake(x, y, controlsWidth, controlsHeight);
        transportView.clipsToBounds = NO;
    }

    self.clipsToBounds = NO;
    cc26ControlsLayoutInProgress = NO;
}
%end

%hook MRUNowPlayingTransportControlsView
- (void)layoutSubviews {
    %orig;

    if (!enabled || !cc26_isCompactNowPlaying(self)) return;

    @try {
        UIButton *leftButton = [self valueForKey:@"leftButton"];
        UIButton *rightButton = [self valueForKey:@"rightButton"];
        UIButton *middleButton = [self valueForKey:@"middleButton"];
        if (!leftButton || !rightButton || !middleButton) return;

        CGFloat width = self.bounds.size.width;
        CGFloat centerY = self.bounds.size.height / 2.0;
        CGFloat spacing = width * 0.28;
        middleButton.center = CGPointMake(width / 2.0, centerY);
        leftButton.center = CGPointMake(width / 2.0 - spacing, centerY);
        rightButton.center = CGPointMake(width / 2.0 + spacing, centerY);
    } @catch (NSException *exception) {}
}
%end

%hook CCUICAPackageDescription
- (NSURL *)packageURL {
    NSURL *packageURL = %orig;
    if (!enabled || !colorSliderGlyphs) return packageURL;
    if ([packageURL.absoluteString isEqualToString:@"file:///System/Library/ControlCenter/Bundles/DisplayModule.bundle/Brightness.ca/"]) {
        return [NSURL fileURLWithPath:ROOT_PATH_NS(@"/Library/PreferenceBundles/CC26Preferences.bundle/Brightness.ca")];
    }
    if ([packageURL.absoluteString isEqualToString:@"file:///System/Library/PrivateFrameworks/MediaControls.framework/Volume.ca/"]) {
        return [NSURL fileURLWithPath:ROOT_PATH_NS(@"/Library/PreferenceBundles/CC26Preferences.bundle/VolumeBold.ca")];
    }
    return packageURL;
}
%end

%hook CALayer
- (void)setOpacity:(float)opacity {
    if (enabled && colorSliderGlyphs && ([self.delegate isKindOfClass:%c(CCUICAPackageView)] || [self.delegate isKindOfClass:%c(UIImageView)])) {
        id controller = [(UIView *)self.delegate _viewControllerForAncestor];
        if ([controller isKindOfClass:%c(CCUIDisplayModuleViewController)] || [controller isKindOfClass:%c(MRUVolumeViewController)]) {
            opacity = opacity > 0 ? 1.0 : opacity;
        }
    }
    %orig(opacity);
}
%end

%hook CCUIContinuousSliderView
%new
- (void)cc26_applyGlyphColor {
    if (!enabled || !colorSliderGlyphs) return;
    if (!self.window) return;

    static BOOL cc26_isApplyingGlyph = NO;
    if (cc26_isApplyingGlyph) return;
    cc26_isApplyingGlyph = YES;

    UIColor *glyphColor = nil;
    id controller = [self _viewControllerForAncestor];
    if (!controller) { cc26_isApplyingGlyph = NO; return; }

    if ([controller isKindOfClass:%c(CCUIDisplayModuleViewController)]) {
        NSDictionary *brightnessColorDict = cc26_preferenceObject(@"brightnessColorDict");
        glyphColor = (brightnessColorDict != nil) ? [UIColor colorWithRed:[brightnessColorDict[@"red"] floatValue] green:[brightnessColorDict[@"green"] floatValue] blue:[brightnessColorDict[@"blue"] floatValue] alpha:1.0] : [UIColor colorWithRed:0.96 green:0.81 blue:0.27 alpha:1.00];
    } else if ([controller isKindOfClass:%c(MRUVolumeViewController)] || [controller isKindOfClass:%c(SBElasticVolumeViewController)]) {
        NSDictionary *volumeColorDict = cc26_preferenceObject(@"volumeColorDict");
        glyphColor = (volumeColorDict != nil) ? [UIColor colorWithRed:[volumeColorDict[@"red"] floatValue] green:[volumeColorDict[@"green"] floatValue] blue:[volumeColorDict[@"blue"] floatValue] alpha:1.0] : [UIColor colorWithRed:0.35 green:0.67 blue:0.88 alpha:1.00];
    }
    if (!glyphColor) { cc26_isApplyingGlyph = NO; return; }

    UIView *packageView = cc26_getIvarObject(self, "_compensatingGlyphView");

    if (packageView && glyphColor) {
        if ([packageView isKindOfClass:%c(CCUICAPackageView)]) {
            colorLayers(@[packageView.layer], glyphColor.CGColor);
        } else if ([packageView isKindOfClass:%c(UIImageView)]) {
            [(UIImageView *)packageView setTintColor:glyphColor];
        }
    }
    cc26_isApplyingGlyph = NO;
}
- (void)didMoveToWindow {
    %orig;
    [self cc26_applyGlyphColor];
}
- (void)_applyGlyphState:(id)arg1 performConfiguration:(BOOL)arg2 {
    %orig;
    [self cc26_applyGlyphColor];
}
- (void)_setActiveGlyphView:(id)arg1 {
    %orig;
    [self cc26_applyGlyphColor];
}
- (BOOL)isGroupRenderingRequired {
    if (!enabled || !colorSliderGlyphs) return %orig;
    return NO;
}
- (NSArray *)punchOutRootLayers {
    if (!enabled || !colorSliderGlyphs) return %orig;
    return nil;
}
- (NSArray *)punchOutRenderingViews {
    if (!enabled || !colorSliderGlyphs) return %orig;
    return nil;
}
%end

%hook CCUIContentModuleContentContainerView
- (void)layoutSubviews {
    %orig;

    if (!enabled) return;

    BOOL opened = NO;
    @try {
        opened = MSHookIvar<BOOL>(self, "_expanded");
    } @catch (NSException *exception) {
        opened = NO;
    }
    BOOL containsMedia = (findSubviewOfClass(self, %c(MRUNowPlayingView)) != nil);
    BOOL containsConnectivity = (findSubviewWithClassNameContaining(self, @"Connectivity") != nil);

    BOOL containsSlider = (findSubviewOfClass(self, %c(CCUIContinuousSliderView)) != nil);
    BOOL containsSteppedSlider = (findSubviewOfClass(self, %c(CCUISteppedSliderView)) != nil);
    BOOL containsFocus = (findSubviewOfClass(self, %c(FCUIActivityListContentView)) != nil);
    BOOL containsAnySlider = containsSlider || containsSteppedSlider;

    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    CGFloat minDim = fminf(W, H);

    // --- Determine container radius ---
    // Media module takes priority (it contains sliders internally when expanded)
    BOOL isStandaloneSlider = containsAnySlider && !containsMedia;
    CGFloat radius;
    if (isStandaloneSlider) {
        // Standalone sliders: fully rounded (half of shorter side) — never elliptic
        radius = minDim / 2.0;
    } else if (containsConnectivity) {
        radius = opened ? 58.0 : getModuleRadius(self);
    } else if (opened) {
        radius = 65.0;
    } else {
        radius = getModuleRadius(self);
    }

    // --- Container border ---
    // Suppress container border for media/slider/focus when expanded (they handle their own)
    BOOL suppressContainerBorder = opened || (containsMedia || containsConnectivity || isStandaloneSlider || containsFocus);
    CGFloat containerBorderWidth = suppressContainerBorder ? 0.0 : 2.0;

    cc26_applyRoundedModuleLayer(self, radius, containerBorderWidth);
    if (opened) {
        BOOL wantsCleanContainerFill = containsConnectivity || (!containsMedia && !containsAnySlider);
        self.backgroundColor = wantsCleanContainerFill ? [UIColor colorWithWhite:1.0 alpha:0.08] : [UIColor clearColor];
        cc26_cleanExpandedBackdropViews(self, NO);
    } else {
        cc26_applyModuleMaterialStyle(self, radius);
    }

    // --- Slider inner views: fully rounded based on their own bounds ---
    if (containsSlider) {
        NSArray *sliders = findAllSubviewsOfClass(self, %c(CCUIContinuousSliderView));
        for (UIView *slider in sliders) {
            CGFloat sliderMin = fminf(slider.bounds.size.width, slider.bounds.size.height);
            CGFloat sliderRadius = sliderMin / 2.0;
            slider.layer.cornerRadius = sliderRadius;
            slider.layer.continuousCorners = YES;
            slider.clipsToBounds = YES;
            // Only add border on standalone sliders, not sliders inside media
            if (isStandaloneSlider) {
                slider.layer.borderWidth = 1.0;
                slider.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.3].CGColor;
            }
        }
    }

    // --- Stepped slider inner views (e.g. ringer toggle) ---
    if (containsSteppedSlider) {
        NSArray *steppedSliders = findAllSubviewsOfClass(self, %c(CCUISteppedSliderView));
        for (UIView *slider in steppedSliders) {
            CGFloat sliderMin = fminf(slider.bounds.size.width, slider.bounds.size.height);
            CGFloat sliderRadius = sliderMin / 2.0;
            slider.layer.cornerRadius = sliderRadius;
            slider.layer.continuousCorners = YES;
            slider.clipsToBounds = YES;
        }
    }

    // --- MTMaterialView backgrounds: round to their own bounds ---
    if (containsAnySlider) {
        NSArray *materials = findAllSubviewsOfClass(self, %c(MTMaterialView));
        for (UIView *mat in materials) {
            CGFloat matMin = fminf(mat.bounds.size.width, mat.bounds.size.height);
            mat.layer.cornerRadius = matMin / 2.0;
            mat.layer.continuousCorners = YES;
            mat.clipsToBounds = YES;
        }
    }

    if (containsMedia) {
        UIView *nowPlayingView = findSubviewOfClass(self, %c(MRUNowPlayingView));
        if (nowPlayingView) {
            CGFloat mediaRadius = opened ? 58.0 : getModuleRadius(nowPlayingView);
            cc26_applyRoundedModuleLayer(nowPlayingView, mediaRadius, opened ? 1.0 : 0.0);
            nowPlayingView.backgroundColor = opened ? [UIColor colorWithWhite:1.0 alpha:0.10] : [UIColor clearColor];
            cc26_cleanExpandedBackdropViews(nowPlayingView, YES);
        }
    }

    if (containsConnectivity) {
        UIView *connectivityView = findSubviewWithClassNameContaining(self, @"Connectivity");
        if (connectivityView && connectivityView != self) {
            CGFloat connectivityRadius = opened ? 58.0 : getModuleRadius(connectivityView);
            cc26_applyRoundedModuleLayer(connectivityView, connectivityRadius, 0.0);
            connectivityView.backgroundColor = [UIColor clearColor];
            cc26_cleanExpandedBackdropViews(connectivityView, YES);
        }
    }


    // --- Focus/Activity module ---
    if (containsFocus) {
        UIView *focus = findSubviewOfClass(self, %c(FCUIActivityControl));
        if (focus) {
            focus.layer.cornerRadius = 35.0;
            focus.layer.continuousCorners = YES;
            focus.layer.borderWidth = 2.0;
            focus.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.3].CGColor;
            focus.layer.masksToBounds = YES;
        }
    }
}
%end

%hook CCUIModularControlCenterOverlayViewController
- (void)setPresentationState:(NSInteger)state {
    %orig;

    UIView *view = self.view;
    if (!view) return;

    if (!enabled) {
        cc26_updateOverlayBackdrop(view, NO);
        [[view viewWithTag:999] removeFromSuperview];
        [[view viewWithTag:998] removeFromSuperview];
        return;
    }

    cc26_updateOverlayBackdrop(view, state == 1 || state == 2);

    CGFloat iconSize = 14; // Kleinere Icons
    CGFloat buttonPadding = 6; // Button etwas größer für Touchfläche
    CGFloat buttonSize = iconSize + buttonPadding;
    CGFloat yOffset = 23;
    CGFloat safeLeft = view.window.safeAreaInsets.left ?: 36;
    CGFloat safeRight = view.window.safeAreaInsets.right ?: 36;

    if (!enableTopButtons) {
        [[view viewWithTag:999] removeFromSuperview];
        [[view viewWithTag:998] removeFromSuperview];
        return;
    }

    if (enableTopButtons) {
        // Plus-Button
        UIButton *plus = [view viewWithTag:999];
        if (!plus) {
            NSDictionary *addColorDict = cc26_preferenceObject(@"addButtonColorDict");
            UIColor *addColor = (addColorDict != nil) ? [UIColor colorWithRed:[addColorDict[@"red"] floatValue] green:[addColorDict[@"green"] floatValue] blue:[addColorDict[@"blue"] floatValue] alpha:1.0] : [UIColor whiteColor];

            plus = [UIButton buttonWithType:UIButtonTypeSystem];
            plus.tag = 999;

            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:iconSize weight:UIImageSymbolWeightRegular];
            UIImage *plusImage = [[UIImage systemImageNamed:@"plus"] imageByApplyingSymbolConfiguration:config];

            [plus setImage:plusImage forState:UIControlStateNormal];
            plus.tintColor = addColor;
            plus.alpha = 0.0;
            plus.transform = CGAffineTransformMakeScale(0.6, 0.6);
            plus.frame = CGRectMake(safeLeft, yOffset - 10, buttonSize, buttonSize);

            [plus addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                [gen impactOccurred];
                NSURL *url = [NSURL URLWithString:@"prefs:root=ControlCenter&path=CUSTOMIZE_CONTROLS"];
                UIApplication *application = [UIApplication sharedApplication];
                if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
                    [application openURL:url options:@{} completionHandler:nil];
                } else if ([application respondsToSelector:@selector(openURL:)]) {
                    [application openURL:url];
                }
            }] forControlEvents:UIControlEventTouchUpInside];

            [view addSubview:plus];
        }

        // Power-Button
        UIButton *power = [view viewWithTag:998];
        if (!power) {
            NSDictionary *powerColorDict = cc26_preferenceObject(@"powerButtonColorDict");
            UIColor *powerColor = (powerColorDict != nil) ? [UIColor colorWithRed:[powerColorDict[@"red"] floatValue] green:[powerColorDict[@"green"] floatValue] blue:[powerColorDict[@"blue"] floatValue] alpha:1.0] : [UIColor systemRedColor];

            power = [UIButton buttonWithType:UIButtonTypeSystem];
            power.tag = 998;

            UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:iconSize weight:UIImageSymbolWeightRegular];
            UIImage *powerImage = [[UIImage systemImageNamed:@"power"] imageByApplyingSymbolConfiguration:config];

            [power setImage:powerImage forState:UIControlStateNormal];
            power.tintColor = powerColor;
            power.alpha = 0.0;
            power.transform = CGAffineTransformMakeScale(0.6, 0.6);
            power.frame = CGRectMake(view.bounds.size.width - safeRight - buttonSize, yOffset - 10, buttonSize, buttonSize);

            if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){14,0,0}]) {
                UIAction *respringAction = [UIAction actionWithTitle:CC26_LOCALIZABLE(@"Respring")
                                                            image:[UIImage systemImageNamed:@"arrow.clockwise.circle"]
                                                        identifier:nil
                                                            handler:^(__kindof UIAction *action) {
                    pid_t pid;
                    const char *args[] = {"sbreload", NULL};
                    posix_spawn(&pid, ROOT_PATH("/usr/bin/sbreload"), NULL, NULL, (char *const *)args, NULL);
                }];

                UIAction *uicacheAction = [UIAction actionWithTitle:CC26_LOCALIZABLE(@"UICache")
                                                            image:[UIImage systemImageNamed:@"paintbrush.fill"]
                                                        identifier:nil
                                                            handler:^(__kindof UIAction *action) {
                    pid_t pid;
                    const char *args[] = {"uicache", "-a", NULL};
                    posix_spawn(&pid, ROOT_PATH("/usr/bin/uicache"), NULL, NULL, (char *const *)args, NULL);
                }];

                UIAction *userspaceAction = [UIAction actionWithTitle:CC26_LOCALIZABLE(@"Userspace Reboot")
                                                                image:[UIImage systemImageNamed:@"bolt.fill"]
                                                        identifier:nil
                                                            handler:^(__kindof UIAction *action) {
                    pid_t pid;
                    const char *args[] = {"launchctl", "reboot", "userspace", NULL};
                    posix_spawn(&pid, ROOT_PATH("/bin/launchctl"), NULL, NULL, (char *const *)args, NULL);
                }];

                UIMenu *menu = [UIMenu menuWithTitle:CC26_LOCALIZABLE(@"Choose Action")
                                            children:@[respringAction, uicacheAction, userspaceAction]];
                [power setMenu:menu];
                [power setShowsMenuAsPrimaryAction:YES];

                [power addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
                    [gen impactOccurred];
                }] forControlEvents:UIControlEventPrimaryActionTriggered];
            }

            [view addSubview:power];
        }

        // Update Frames (z. B. bei Rotation)
        plus.frame = CGRectMake(safeLeft - 10, yOffset - 10, buttonSize + 15, buttonSize + 15);
        power.frame = CGRectMake(view.bounds.size.width - safeRight - buttonSize - 10, yOffset - 10, buttonSize + 15, buttonSize + 15);

        // Animation je nach Zustand
        switch (state) {
            case 1: {
                plus.transform = CGAffineTransformMakeScale(0.6, 0.6);
                power.transform = CGAffineTransformMakeScale(0.6, 0.6);
                [UIView animateWithDuration:0.45
                                    delay:0.0
                    usingSpringWithDamping:0.7
                    initialSpringVelocity:0.5
                                    options:UIViewAnimationOptionCurveEaseOut
                                animations:^{
                    plus.alpha = 1.0;
                    plus.transform = CGAffineTransformIdentity;
                    power.alpha = 1.0;
                    power.transform = CGAffineTransformIdentity;
                } completion:nil];
                break;
            }
            case 3: {
                [UIView animateWithDuration:0.2 animations:^{
                    plus.alpha = 0.0;
                    plus.transform = CGAffineTransformMakeScale(0.6, 0.6);
                    power.alpha = 0.0;
                    power.transform = CGAffineTransformMakeScale(0.6, 0.6);
                }];
                break;
            }
            default:
                break;
        }
    }
}
%end

%end // CC26 group

static void loadPreferences(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSNumber *enabledValue = (NSNumber *)cc26_preferenceObject(@"enabled");
    enabled = (enabledValue) ? [enabledValue boolValue] : NO;
    NSNumber *enableTopButtonsValue = (NSNumber *)cc26_preferenceObject(@"enableTopButtons");
    enableTopButtons = (enableTopButtonsValue) ? [enableTopButtonsValue boolValue] : YES;
    NSNumber *colorSliderGlyphsValue = (NSNumber *)cc26_preferenceObject(@"colorSliderGlyphs");
    colorSliderGlyphs = (colorSliderGlyphsValue) ? [colorSliderGlyphsValue boolValue] : NO;

    NSNumber *mediaArtworkXValue = (NSNumber *)cc26_preferenceObject(@"mediaArtworkX");
    mediaArtworkX = mediaArtworkXValue ? [mediaArtworkXValue floatValue] : -1;
    NSNumber *mediaArtworkYValue = (NSNumber *)cc26_preferenceObject(@"mediaArtworkY");
    mediaArtworkY = mediaArtworkYValue ? [mediaArtworkYValue floatValue] : -1;
    NSNumber *mediaArtworkSizeValue = (NSNumber *)cc26_preferenceObject(@"mediaArtworkSize");
    mediaArtworkSize = mediaArtworkSizeValue ? [mediaArtworkSizeValue floatValue] : -1;
    NSNumber *mediaRoutingBtnXValue = (NSNumber *)cc26_preferenceObject(@"mediaRoutingBtnX");
    mediaRoutingBtnX = mediaRoutingBtnXValue ? [mediaRoutingBtnXValue floatValue] : -1;
    NSNumber *mediaRoutingBtnYValue = (NSNumber *)cc26_preferenceObject(@"mediaRoutingBtnY");
    mediaRoutingBtnY = mediaRoutingBtnYValue ? [mediaRoutingBtnYValue floatValue] : -1;
    NSNumber *mediaRoutingBtnSizeValue = (NSNumber *)cc26_preferenceObject(@"mediaRoutingBtnSize");
    mediaRoutingBtnSize = mediaRoutingBtnSizeValue ? [mediaRoutingBtnSizeValue floatValue] : -1;
    NSNumber *mediaLabelXValue = (NSNumber *)cc26_preferenceObject(@"mediaLabelX");
    mediaLabelX = mediaLabelXValue ? [mediaLabelXValue floatValue] : -1;
    NSNumber *mediaLabelYValue = (NSNumber *)cc26_preferenceObject(@"mediaLabelY");
    mediaLabelY = mediaLabelYValue ? [mediaLabelYValue floatValue] : -1;
    NSNumber *mediaLabelWValue = (NSNumber *)cc26_preferenceObject(@"mediaLabelW");
    mediaLabelW = mediaLabelWValue ? [mediaLabelWValue floatValue] : -1;
    NSNumber *mediaLabelHValue = (NSNumber *)cc26_preferenceObject(@"mediaLabelH");
    mediaLabelH = mediaLabelHValue ? [mediaLabelHValue floatValue] : -1;
    NSNumber *mediaLabelLineSpacingValue = (NSNumber *)cc26_preferenceObject(@"mediaLabelLineSpacing");
    mediaLabelLineSpacing = mediaLabelLineSpacingValue ? [mediaLabelLineSpacingValue floatValue] : 1.0;
}

%ctor {
    if (!cc26_isSpringBoardProcess()) return;

    dlopen("/System/Library/PrivateFrameworks/ControlCenterUIKit.framework/ControlCenterUIKit", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);

    loadPreferences(NULL, NULL, NULL, NULL, NULL); // Load prefs
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, loadPreferences, (CFStringRef)preferencesNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);

    if (!cc26_hooksInitialized) {
        cc26_hooksInitialized = YES;
        %init(CC26)
    }
}
