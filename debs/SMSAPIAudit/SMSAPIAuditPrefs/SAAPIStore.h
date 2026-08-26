#import <Foundation/Foundation.h>
@interface SAAPIStore : NSObject
+ (instancetype)shared;
@property(nonatomic,readonly) NSArray<NSDictionary *> *apis;
- (NSDictionary *)statistics;
- (NSArray<NSDictionary *> *)filtered:(NSString *)query method:(NSString *)method favoritesOnly:(BOOL)favorites;
- (BOOL)isFavorite:(NSDictionary *)api;
- (void)toggleFavorite:(NSDictionary *)api;
- (NSArray<NSString *> *)risksForAPI:(NSDictionary *)api;
- (NSString *)previewForAPI:(NSDictionary *)api phone:(NSString *)phone;
- (NSString *)exportReport;
@end
