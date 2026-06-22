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

static NSInteger cc26_nowPlayingLayout(UIView *view, NSInteger fallback) {
    UIView *ancestor = view;
    while (ancestor) {
        if ([ancestor isKindOfClass:%c(MRUNowPlayingView)]) {
            @try {
                return [[ancestor valueForKey:@"_layout"] integerValue];
            } @catch (NSException *exception) {
                NSLog(@"[CC26] Failed to read now playing layout: %@", exception);
                return fallback;
            }
        }
        ancestor = ancestor.superview;
    }
    return fallback;
}

static BOOL cc26_isExpandedNowPlayingLayout(UIView *view) {
    NSInteger layout = cc26_nowPlayingLayout(view, -1);
    return layout == 1 || layout == 2;
}

static BOOL cc26_isInsideControlCenterContainer(UIView *view) {
    UIView *ancestor = view;
    while (ancestor) {
        if ([ancestor isKindOfClass:%c(CCUIContentModuleContentContainerView)]) {
            return YES;
        }
        ancestor = ancestor.superview;
    }
    return NO;
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

#pragma mark - Media module helpers

void adjustLabelFontsInView(UIView *view, BOOL isTitle) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            label.font = [UIFont systemFontOfSize:13.0 weight:isTitle ? UIFontWeightSemibold : UIFontWeightRegular];
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.7;
            label.textAlignment = NSTextAlignmentCenter;
        } else {
            adjustLabelFontsInView(subview, isTitle);
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

static BOOL cc26_isInsideCCCompact(UIView *view) {
    return cc26_isInsideControlCenterContainer(view) && !cc26_isExpandedNowPlayingLayout(view);
}

static void cc26_forceSubviewAlphas(UIView *view) {
    for (UIView *sub in view.subviews) {
        if (!sub.hidden) {
            sub.layer.opacity = 1.0;
        }
    }
}

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
        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialLight];
        backdrop = [[UIVisualEffectView alloc] initWithEffect:effect];
        backdrop.tag = CC26OverlayBackdropTag;
        backdrop.userInteractionEnabled = NO;
        backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        UIView *tintView = [[UIView alloc] initWithFrame:backdrop.contentView.bounds];
        tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tintView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        [backdrop.contentView addSubview:tintView];

        NSUInteger index = MIN((NSUInteger)1, view.subviews.count);
        [view insertSubview:backdrop atIndex:index];
    } else if (backdrop.superview == view) {
        NSUInteger index = MIN((NSUInteger)1, view.subviews.count - 1);
        [view insertSubview:backdrop atIndex:index];
    }

    backdrop.frame = view.bounds;
    backdrop.alpha = 0.62;
    backdrop.hidden = NO;
}

static void cc26_applyModuleMaterialStyle(UIView *containerView, CGFloat radius) {
    containerView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];

    NSArray *materials = findAllSubviewsOfClass(containerView, %c(MTMaterialView));
    for (UIView *materialView in materials) {
        CGFloat materialMin = fminf(materialView.bounds.size.width, materialView.bounds.size.height);
        CGFloat materialRadius = materialMin > 0 ? materialMin / 2.0 : radius;
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

    if (!enabled) return;

    if (!cc26_isInsideControlCenterContainer(self)) return;

    if (cc26_isExpandedNowPlayingLayout(self)) {
        UIView *routingButton = cc26_getIvarObject(self, "_routingButton");
        if (routingButton) {
            routingButton.layer.masksToBounds = NO;
            routingButton.layer.cornerRadius = 0;
            routingButton.backgroundColor = [UIColor clearColor];
        }
        return;
    }

    if (!useCompactMediaLayout) return;

    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W <= 0 || H <= 0) return;

    // Artwork
    UIView *artworkView = cc26_getIvarObject(self, "_artworkView");

    CGFloat artSize = MIN(MAX(W * 0.28, 30.0), 42.0);
    CGFloat artX = (W - artSize) / 2.0;
    CGFloat artY = MAX(8.0, H * 0.10);

    if (artworkView) {
        artworkView.translatesAutoresizingMaskIntoConstraints = YES;
        artworkView.frame = CGRectMake(artX, artY, artSize, artSize);
        artworkView.alpha = 0.92;
        artworkView.layer.cornerRadius = artSize * 0.22;
        artworkView.layer.masksToBounds = YES;
        artworkView.clipsToBounds = YES;
    }

    // Routing button (AirPlay) — compact top-right placement
    UIView *routingButton = cc26_getIvarObject(self, "_routingButton");

    CGFloat btnSize = 24.0;
    CGFloat btnX = W - btnSize - 6.0;
    CGFloat btnY = 8.0;

    if (routingButton) {
        routingButton.alpha = 1.0;
        routingButton.translatesAutoresizingMaskIntoConstraints = YES;
        routingButton.frame = CGRectMake(btnX, btnY, btnSize, btnSize);
        routingButton.backgroundColor = [UIColor clearColor];
        routingButton.layer.cornerRadius = 0;
        routingButton.layer.masksToBounds = NO;
    }

    // Centered label, kept above transport controls
    UIView *labelView = cc26_getIvarObject(self, "_labelView");

    if (labelView) {
        CGFloat labelH = MIN(38.0, MAX(30.0, H * 0.28));
        CGFloat labelY = MAX(artY + artSize + 4.0, H * 0.42);
        CGFloat maxLabelY = H - 38.0 - labelH;
        if (maxLabelY > 0) labelY = MIN(labelY, maxLabelY);
        labelY = MAX(0.0, labelY);
        labelView.translatesAutoresizingMaskIntoConstraints = YES;
        labelView.frame = CGRectMake(8.0, labelY, W - 16.0, labelH);
        labelView.alpha = 1.0;
        labelView.layer.opacity = 1.0;
        labelView.clipsToBounds = YES;
        cc26_forceSubviewAlphas(labelView);
    }

    self.clipsToBounds = NO;
    adjustLabelFontsInView(self, NO);
}
%end

%hook MPUMarqueeView
- (void)setAlpha:(CGFloat)alpha {
    if (enabled && useCompactMediaLayout && [self.superview isKindOfClass:%c(MRUNowPlayingLabelView)] && cc26_isInsideCCCompact(self)) {
        %orig(1.0);
        self.layer.opacity = 1.0;
        cc26_forceSubviewAlphas(self);
        return;
    }
    %orig;
}
%end

%hook MRUNowPlayingLabelView
- (void)setAlpha:(CGFloat)alpha {
    if (enabled && useCompactMediaLayout && cc26_isInsideCCCompact(self)) {
        %orig(1.0);
        self.layer.opacity = 1.0;
        cc26_forceSubviewAlphas(self);
        return;
    }
    %orig;
}
- (void)layoutSubviews {
    %orig;

    if (!enabled) return;

    if (!cc26_isInsideControlCenterContainer(self)) return;
    if (cc26_isExpandedNowPlayingLayout(self)) return;
    if (!useCompactMediaLayout) return;

    // Get marquee views and standalone label views
    UIView *titleMarquee = nil;
    UIView *subtitleMarquee = nil;
    UIView *titleLabel = nil;
    UIView *subtitleLabel = nil;

    titleMarquee = cc26_getIvarObject(self, "_titleMarqueeView");
    subtitleMarquee = cc26_getIvarObject(self, "_subtitleMarqueeView");
    titleLabel = cc26_getIvarObject(self, "_titleLabel");
    subtitleLabel = cc26_getIvarObject(self, "_subtitleLabel");

    // Use marquee views for positioning
    UIView *titleView = titleMarquee ?: titleLabel;
    UIView *subtitleView = subtitleMarquee ?: subtitleLabel;

    // _titleLabel/_subtitleLabel are INSIDE the marquee views.
    // Do NOT touch their hidden state — the system manages it
    // to avoid duplication with the marquee's own scrolling content.

    // Hide _routeLabel in compact mode (not needed)
    UIView *routeLabel = cc26_getIvarObject(self, "_routeLabel");
    if (routeLabel) routeLabel.hidden = YES;

    CGFloat lineSpacing = mediaLabelLineSpacing;

    if (titleView && subtitleView) {
        CGFloat W = self.bounds.size.width;
        CGFloat titleH = 16.0;
        CGFloat subtitleH = 14.0;

        titleView.translatesAutoresizingMaskIntoConstraints = YES;
        subtitleView.translatesAutoresizingMaskIntoConstraints = YES;
        titleView.clipsToBounds = YES;
        subtitleView.clipsToBounds = YES;
        // Force visibility on self and children
        self.layer.opacity = 1.0;
        titleView.layer.opacity = 1.0;
        subtitleView.layer.opacity = 1.0;
        cc26_forceSubviewAlphas(titleView);
        cc26_forceSubviewAlphas(subtitleView);

        CGFloat totalH = titleH + lineSpacing + subtitleH;
        CGFloat startY = (self.bounds.size.height - totalH) / 2.0;
        if (startY < 0) startY = 0;

        titleView.frame = CGRectMake(0, startY, W, titleH);
        subtitleView.frame = CGRectMake(0, startY + titleH + lineSpacing, W, subtitleH);

        // Bold title, regular subtitle
        adjustLabelFontsInView(titleView, YES);
        adjustLabelFontsInView(subtitleView, NO);

        // Delayed re-force in case system overrides alpha after layout
        dispatch_async(dispatch_get_main_queue(), ^{
            self.layer.opacity = 1.0;
            for (UIView *sub in self.subviews) {
                if (!sub.hidden) {
                    sub.layer.opacity = 1.0;
                    for (UIView *inner in sub.subviews) {
                        inner.layer.opacity = 1.0;
                    }
                }
            }
        });
    }
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

%hook MRUNowPlayingControlsView
static BOOL cc26ControlsLayoutInProgress = NO;
- (void)layoutSubviews {
    %orig;

    if (!enabled) return;

    if (cc26ControlsLayoutInProgress) return;
    cc26ControlsLayoutInProgress = YES;

    if (!cc26_isInsideControlCenterContainer(self) || cc26_isExpandedNowPlayingLayout(self) || !useCompactMediaLayout) {
        cc26ControlsLayoutInProgress = NO;
        return;
    }

    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    CGFloat pad = 8.0;

    // Position headerView: top portion with padding
    UIView *headerView = cc26_getIvarObject(self, "_headerView");

    if (headerView) {
        CGFloat headerHeight = H - 2 * pad;
        headerView.translatesAutoresizingMaskIntoConstraints = YES;
        headerView.frame = CGRectMake(pad, pad, W - 2 * pad, headerHeight);
        headerView.clipsToBounds = NO;
        [headerView setNeedsLayout];
        [headerView layoutIfNeeded];
    }

    self.clipsToBounds = NO;

    // Position transportControlsView: centered at bottom
    UIView *transportView = cc26_getIvarObject(self, "_transportControlsView");

    if (transportView) {
        CGFloat controlsHeight = MIN(MAX(H * 0.22, 28.0), 34.0);
        CGFloat controlsWidth = MIN(W - 44.0, 92.0);
        CGFloat x = (W - controlsWidth) / 2.0;
        CGFloat y = H - controlsHeight - pad;
        transportView.translatesAutoresizingMaskIntoConstraints = YES;
        transportView.frame = CGRectMake(x, y, controlsWidth, controlsHeight);
    }

    cc26ControlsLayoutInProgress = NO;
}
%end

%hook MRUNowPlayingTransportControlsView
- (void)layoutSubviews {
    %orig;

    if (!enabled) return;

    if (!cc26_isInsideControlCenterContainer(self)) return;
    if (!useCompactMediaLayout) return;

    @try {
        NSInteger layout = cc26_nowPlayingLayout(self, -1);
        if (layout == 2) return;

        UIButton *leftButton = [self valueForKey:@"leftButton"];
        UIButton *rightButton = [self valueForKey:@"rightButton"];
        UIButton *middleButton = [self valueForKey:@"middleButton"];

        if (leftButton && rightButton && middleButton) {
            CGFloat viewWidth = self.bounds.size.width;
            CGFloat centerY = self.bounds.size.height / 2.0;
            CGFloat spacing = MIN(MAX(viewWidth * 0.30, 22.0), 30.0);

            middleButton.center = CGPointMake(viewWidth / 2.0, centerY);
            leftButton.center = CGPointMake(viewWidth / 2.0 - spacing, centerY);
            rightButton.center = CGPointMake(viewWidth / 2.0 + spacing, centerY);
        }

    } @catch (NSException *e) {
        NSLog(@"[CC26] MRUNowPlayingTransportControlsView crash prevented: %@", e);
    }
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
    } else if (opened) {
        radius = 65.0;
    } else {
        radius = getModuleRadius(self);
    }

    // --- Container border ---
    // Suppress container border for media/slider/focus when expanded (they handle their own)
    BOOL suppressContainerBorder = opened && (containsMedia || isStandaloneSlider || containsFocus);
    CGFloat containerBorderWidth = suppressContainerBorder ? 0.0 : 2.0;

    self.clipsToBounds = YES;
    self.layer.cornerRadius = radius;
    self.layer.continuousCorners = YES;
    self.layer.borderWidth = containerBorderWidth;
    self.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.3].CGColor;
    self.layer.masksToBounds = YES;
    cc26_applyModuleMaterialStyle(self, radius);

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

    // --- Media module: single border on MRUNowPlayingView only when expanded ---
    if (containsMedia && opened) {
        UIView *npv = findSubviewOfClass(self, %c(MRUNowPlayingView));
        if (npv) {
            npv.layer.cornerRadius = 65.0;
            npv.layer.continuousCorners = YES;
            npv.layer.borderWidth = 2.0;
            npv.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:0.3].CGColor;
            npv.layer.masksToBounds = YES;
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

    cc26_updateOverlayBackdrop(view, state == 1);

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
    NSNumber *useCompactMediaLayoutValue = (NSNumber *)cc26_preferenceObject(@"useCompactMediaLayout");
    useCompactMediaLayout = (useCompactMediaLayoutValue) ? [useCompactMediaLayoutValue boolValue] : YES;

    NSNumber *val;
    val = cc26_preferenceObject(@"mediaLabelLineSpacing");
    mediaLabelLineSpacing = val ? [val floatValue] : 1.0;
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
