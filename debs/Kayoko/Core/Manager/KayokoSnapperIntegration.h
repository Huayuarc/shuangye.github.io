//
//  KayokoSnapperIntegration.h
//  Kayoko
//

#import <Foundation/Foundation.h>

@class KayokoPasteboardItem;

NS_ASSUME_NONNULL_BEGIN

/// Optional bridge to Snapper 3. It never links against Snapper: all compatibility checks
/// happen at runtime, so Kayoko continues to work unchanged when Snapper is absent.
@interface KayokoSnapperIntegration : NSObject

+ (BOOL)isAvailable;
+ (BOOL)floatPasteboardItem:(KayokoPasteboardItem *)item;

@end

NS_ASSUME_NONNULL_END
