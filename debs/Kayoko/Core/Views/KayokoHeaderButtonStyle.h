//
//  KayokoHeaderButtonStyle.h
//  Kayoko
//

#import <UIKit/UIKit.h>

static NSUInteger const kKayokoFavoritesButtonImageSize = 22;
static NSUInteger const kKayokoClearButtonImageSize = 20;
static NSUInteger const kKayokoBackButtonImageSize = 20;
static NSUInteger const kKayokoPinButtonImageSize = 18;
static CGFloat const kKayokoLeadingHeaderButtonCenterXInset = 34;
static CGFloat const kKayokoTitleLabelLeadingInset = 60;

// Shared edge gap for floating card chrome.
static CGFloat const kKayokoPanelFloatingInset = 5.0;
// Landscape can span nearly full height; portrait uses preference height.
static CGFloat const kKayokoPanelFloatingMaxWidth = 430.0;

// Fallback only; runtime prefers UIScreen display corner radius.
static CGFloat const kKayokoPanelCornerRadiusFallback = 55.0;
