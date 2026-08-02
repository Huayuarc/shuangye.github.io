//
//  KayokoSnapperIntegration.m
//  Kayoko
//

#import "KayokoSnapperIntegration.h"

#import <math.h>
#import <UIKit/UIKit.h>

#import "KayokoPasteboardItem.h"
#import "KayokoPasteboardManager.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *const kKayokoSnapperWindowClassName = @"SnapperWindow";
static NSString *const kKayokoSnapperFloatSelectorName = @"wantsToSnapRect:inImage:";
static NSUInteger const kKayokoSnapperMaximumTextLength = 2000;
static CGFloat const kKayokoSnapperMaximumImageDimension = 4096.0;
static CGFloat const kKayokoSnapperMaximumImagePixelCount = 16000000.0;
static CGFloat const kKayokoSnapperFloatingHorizontalMargin = 16.0;
static CGFloat const kKayokoSnapperFloatingTopMargin = 12.0;
static CGFloat const kKayokoSnapperFloatingMaximumImageHeight = 360.0;
static CGFloat const kKayokoSnapperFloatingContentScale = 0.704;
static CGFloat const kKayokoSnapperCornerRadius = 6.0;

typedef void (*KayokoSnapperFloatInvocation)(id target, SEL selector, CGRect rect, UIImage *image);

@implementation KayokoSnapperIntegration

#pragma mark - Availability

+ (Class)snapperWindowClass {
    return NSClassFromString(kKayokoSnapperWindowClassName);
}

+ (nullable UIWindow *)snapperWindow {
    Class snapperWindowClass = [self snapperWindowClass];
    if (!snapperWindowClass) {
        return nil;
    }

    NSMutableOrderedSet<UIWindow *> *windows = [[NSMutableOrderedSet alloc] init];
    NSArray<UIWindow *> *applicationWindows = [[UIApplication sharedApplication] windows];
    if (applicationWindows) {
        [windows addObjectsFromArray:applicationWindows];
    }

    // SpringBoard has used scenes since iOS 13. Include scene windows as a fallback because
    // -windows can omit windows belonging to a background scene during a transition.
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        NSArray<UIWindow *> *sceneWindows = [(UIWindowScene *)scene windows];
        if (sceneWindows) {
            [windows addObjectsFromArray:sceneWindows];
        }
    }

    for (UIWindow *window in windows) {
        if ([window isKindOfClass:snapperWindowClass]) {
            return window;
        }
    }
    return nil;
}

+ (BOOL)isAvailable {
    if (![NSThread isMainThread]) {
        return NO;
    }

    SEL selector = NSSelectorFromString(kKayokoSnapperFloatSelectorName);
    UIWindow *window = [self snapperWindow];
    return window && [window respondsToSelector:selector];
}

#pragma mark - Image Preparation

+ (NSString *)displayTextFromText:(NSString *)text {
    NSString *trimmedText = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmedText length] <= kKayokoSnapperMaximumTextLength) {
        return trimmedText;
    }

    NSRange limitRange = NSMakeRange(0, kKayokoSnapperMaximumTextLength);
    NSRange composedRange = [trimmedText rangeOfComposedCharacterSequencesForRange:limitRange];
    return [[trimmedText substringWithRange:composedRange] stringByAppendingString:@"…"];
}

+ (nullable UIImage *)noteImageFromText:(NSString *)text {
    NSString *displayText = [self displayTextFromText:text ?: @""];
    if ([displayText length] == 0) {
        return nil;
    }

    CGFloat screenWidth = [[UIScreen mainScreen] bounds].size.width;
    CGFloat maximumWidth = MIN(MAX(screenWidth * 0.78, 260.0), 680.0);
    CGFloat horizontalInset = 18.0;
    CGFloat verticalInset = 10.0;
    CGFloat maximumTextHeight = 360.0;
    UIFont *font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightRegular];
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    [paragraphStyle setLineBreakMode:NSLineBreakByTruncatingTail];
    [paragraphStyle setLineSpacing:1.0];

    NSDictionary<NSAttributedStringKey, id> *attributes = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : [UIColor labelColor],
        NSParagraphStyleAttributeName : paragraphStyle
    };
    CGRect measuredTextRect = [displayText boundingRectWithSize:CGSizeMake(maximumWidth - horizontalInset * 2.0,
                                                                             maximumTextHeight)
                                                          options:NSStringDrawingUsesLineFragmentOrigin |
                                                                  NSStringDrawingUsesFontLeading
                                                       attributes:attributes
                                                          context:nil];
    CGFloat imageWidth = MAX(180.0, ceil(measuredTextRect.size.width) + horizontalInset * 2.0);
    CGFloat imageHeight = MAX(46.0, ceil(measuredTextRect.size.height) + verticalInset * 2.0);
    CGSize imageSize = CGSizeMake(imageWidth, imageHeight);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    // Snapper owns the outer rounded clipping and shadow. Keep the crop opaque and use one
    // uniform card color so anti-aliased source corners cannot expose a black or white backing.
    [format setOpaque:YES];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:imageSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull rendererContext) {
      (void)rendererContext;
      CGRect cardRect = CGRectMake(0, 0, imageSize.width, imageSize.height);
      [[UIColor secondarySystemBackgroundColor] setFill];
      UIRectFill(cardRect);

      CGRect textRect = CGRectInset(cardRect, horizontalInset, verticalInset);
      [displayText drawWithRect:textRect
                         options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                      attributes:attributes
                         context:nil];
    }];
}

+ (nullable UIImage *)scaledImageIfNeeded:(UIImage *)image {
    CGSize sourceSize = [image size];
    if (sourceSize.width <= 0.0 || sourceSize.height <= 0.0) {
        return nil;
    }

    CGFloat sourcePixelWidth = sourceSize.width * [image scale];
    CGFloat sourcePixelHeight = sourceSize.height * [image scale];
    CGFloat sourcePixelCount = sourcePixelWidth * sourcePixelHeight;
    CGFloat longestPixelSide = MAX(sourcePixelWidth, sourcePixelHeight);
    if (longestPixelSide <= kKayokoSnapperMaximumImageDimension &&
        sourcePixelCount <= kKayokoSnapperMaximumImagePixelCount) {
        return image;
    }

    CGFloat dimensionScale = kKayokoSnapperMaximumImageDimension / longestPixelSide;
    CGFloat pixelScale = sqrt(kKayokoSnapperMaximumImagePixelCount / sourcePixelCount);
    CGFloat scale = MIN(dimensionScale, pixelScale);
    if (!isfinite(scale) || scale <= 0.0 || scale >= 1.0) {
        return image;
    }

    CGSize targetSize = CGSizeMake(MAX(1.0, floor(sourcePixelWidth * scale)),
                                   MAX(1.0, floor(sourcePixelHeight * scale)));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    [format setOpaque:NO];
    [format setScale:1.0];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull rendererContext) {
      (void)rendererContext;
      [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    }];
}

+ (nullable UIImage *)imageForPasteboardItem:(KayokoPasteboardItem *)item {
    if ([[item imageName] length] > 0) {
        UIImage *image = [[KayokoPasteboardManager sharedInstance] getImageForItem:item];
        return image ? [self scaledImageIfNeeded:image] : nil;
    }
    return [self noteImageFromText:[item content]];
}

+ (CGFloat)topSafeAreaInsetForWindow:(UIWindow *)window {
    CGFloat topInset = [window safeAreaInsets].top;

    // Snapper is a SpringBoard window. During some transitions its own safe-area value can
    // briefly be zero, while an application scene still has the correct device inset.
    // Take the largest valid inset from windows on the same screen as a conservative fallback.
    UIScreen *screen = [window screen];
    NSMutableOrderedSet<UIWindow *> *windows = [[NSMutableOrderedSet alloc] init];
    NSArray<UIWindow *> *applicationWindows = [[UIApplication sharedApplication] windows];
    if (applicationWindows) {
        [windows addObjectsFromArray:applicationWindows];
    }
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            NSArray<UIWindow *> *sceneWindows = [(UIWindowScene *)scene windows];
            if (sceneWindows) {
                [windows addObjectsFromArray:sceneWindows];
            }
        }
    }
    for (UIWindow *candidate in windows) {
        if (screen && [candidate screen] != screen) {
            continue;
        }
        topInset = MAX(topInset, [candidate safeAreaInsets].top);
    }
    return MAX(topInset, 0.0);
}

+ (nullable UIImage *)floatingCanvasForImage:(UIImage *)image
                                     inWindow:(UIWindow *)window
                                     cropRect:(CGRect *)cropRect {
    if (!image || !cropRect) {
        return nil;
    }

    CGSize canvasSize = [window bounds].size;
    if (canvasSize.width <= 0.0 || canvasSize.height <= 0.0) {
        canvasSize = [[UIScreen mainScreen] bounds].size;
    }
    if (canvasSize.width <= 0.0 || canvasSize.height <= 0.0) {
        return nil;
    }

    CGSize imageSize = [image size];
    if (imageSize.width <= 0.0 || imageSize.height <= 0.0) {
        return nil;
    }

    CGFloat topInset = [self topSafeAreaInsetForWindow:window];
    CGFloat maximumWidth = MAX(1.0, canvasSize.width - kKayokoSnapperFloatingHorizontalMargin * 2.0);
    CGFloat availableHeight = MAX(1.0, canvasSize.height - topInset - kKayokoSnapperFloatingTopMargin * 2.0);
    CGFloat maximumHeight = MIN(kKayokoSnapperFloatingMaximumImageHeight, availableHeight);
    CGFloat scale = MIN(kKayokoSnapperFloatingContentScale,
                        MIN(maximumWidth / imageSize.width, maximumHeight / imageSize.height));
    if (!isfinite(scale) || scale <= 0.0) {
        return nil;
    }

    CGSize floatingSize = CGSizeMake(MAX(1.0, floor(imageSize.width * scale)),
                                     MAX(1.0, floor(imageSize.height * scale)));
    CGFloat originX = floor((canvasSize.width - floatingSize.width) * 0.5);
    CGFloat originY = MIN(MAX(topInset + kKayokoSnapperFloatingTopMargin,
                              kKayokoSnapperFloatingTopMargin),
                         MAX(kKayokoSnapperFloatingTopMargin,
                             canvasSize.height - floatingSize.height - kKayokoSnapperFloatingTopMargin));
    CGRect targetRect = CGRectIntegral(CGRectMake(originX, originY, floatingSize.width, floatingSize.height));
    if (CGRectIsEmpty(targetRect) || !CGRectContainsRect((CGRect){ .origin = CGPointZero, .size = canvasSize }, targetRect)) {
        return nil;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    [format setOpaque:NO];
    [format setScale:[[UIScreen mainScreen] scale]];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvasSize format:format];
    UIImage *canvas = [renderer imageWithActions:^(UIGraphicsImageRendererContext *_Nonnull rendererContext) {
      (void)rendererContext;
      [image drawInRect:targetRect];
    }];
    *cropRect = targetRect;
    return canvas;
}

// Snapper owns the outer Snap view and its shadow. Its public-facing entry point does not
// expose a corner-radius parameter, so normalize only the newly-created Snap image view.
// The source image remains a plain opaque rectangle; this avoids a second, baked-in radius.
+ (void)normalizeSnapperAppearanceForWindow:(UIWindow *)window {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      @try {
        id overlay = [window valueForKey:@"snapsOverlay"];
        NSArray *snaps = [overlay valueForKey:@"snapsArray"];
        UIView *snap = [snaps lastObject];
        UIImageView *imageView = [snap valueForKey:@"imageView"];
        if (!snap || !imageView) {
            return;
        }
        [[snap layer] setCornerRadius:kKayokoSnapperCornerRadius];
        [[imageView layer] setCornerRadius:kKayokoSnapperCornerRadius];
        [[imageView layer] setMasksToBounds:YES];
      } @catch (__unused NSException *exception) {
      }
    });
}

#pragma mark - Snapper Invocation

+ (BOOL)floatPasteboardItem:(KayokoPasteboardItem *)item {
    if (!item || ![NSThread isMainThread]) {
        return NO;
    }

    UIWindow *window = [self snapperWindow];
    SEL selector = NSSelectorFromString(kKayokoSnapperFloatSelectorName);
    if (!window || ![window respondsToSelector:selector]) {
        return NO;
    }

    UIImage *image = [self imageForPasteboardItem:item];
    if (!image || [image size].width <= 0.0 || [image size].height <= 0.0) {
        return NO;
    }

    CGRect cropRect = CGRectZero;
    UIImage *canvas = [self floatingCanvasForImage:image inWindow:window cropRect:&cropRect];
    if (!canvas || CGRectIsEmpty(cropRect)) {
        return NO;
    }

    // Snapper 3 exposes this Objective-C method but no public SDK. Keep it isolated behind
    // runtime checks and an exception boundary so a removed or incompatible Snapper never
    // affects Kayoko's own history actions.
    @try {
        KayokoSnapperFloatInvocation invocation = (KayokoSnapperFloatInvocation)[window methodForSelector:selector];
        if (!invocation) {
            return NO;
        }
        invocation(window, selector, cropRect, canvas);
        [self normalizeSnapperAppearanceForWindow:window];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

@end

NS_ASSUME_NONNULL_END
