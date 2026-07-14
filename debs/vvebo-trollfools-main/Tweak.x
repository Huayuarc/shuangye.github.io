#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static NSString *storedUID = nil;

// 从URL中提取UID
NSString* extractUID(NSString *url) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"uid=(\\d+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:url options:0 range:NSMakeRange(0, url.length)];
    if (match) {
        return [url substringWithRange:[match rangeAtIndex:1]];
    }
    return nil;
}

// 转换响应数据
NSData* transformProfileData(NSData *originalData) {
    if (!originalData) return originalData;
    
    NSError *jsonError;
    NSDictionary *jsonData = [NSJSONSerialization JSONObjectWithData:originalData options:0 error:&jsonError];
    if (!jsonData || jsonError) return originalData;
    
    NSArray *cards = jsonData[@"cards"];
    if (!cards) return originalData;
    
    NSMutableArray *statuses = [NSMutableArray array];
    
    for (NSDictionary *card in cards) {
        NSArray *cardGroup = card[@"card_group"];
        NSArray *cardsToProcess = cardGroup ? cardGroup : @[card];
        
        for (NSDictionary *cardItem in cardsToProcess) {
            if ([cardItem[@"card_type"] intValue] == 9) {
                NSMutableDictionary *mblog = [cardItem[@"mblog"] mutableCopy];
                if ([mblog[@"isTop"] boolValue]) {
                    mblog[@"label"] = @"置顶";
                }
                [statuses addObject:mblog];
            }
        }
    }
    
    NSDictionary *cardlistInfo = jsonData[@"cardlistInfo"];
    NSString *sinceId = cardlistInfo[@"since_id"];
    
    NSDictionary *transformedData = @{
        @"statuses": statuses,
        @"since_id": sinceId ?: @"",
        @"total_number": @100
    };
    
    NSData *transformedJsonData = [NSJSONSerialization dataWithJSONObject:transformedData options:0 error:nil];
    return transformedJsonData ?: originalData;
}

// Hook NSURLRequest 来修改请求URL
%hook NSMutableURLRequest

- (void)setURL:(NSURL *)URL {
    NSString *urlString = URL.absoluteString;
    
    // 处理 users/show 请求，存储UID
    if ([urlString containsString:@"users/show"]) {
        NSString *uid = extractUID(urlString);
        if (uid) {
            storedUID = uid;
            NSLog(@"[VVeboFix] Stored UID: %@", uid);
        }
    }
    // 处理 statuses/user_timeline 请求，重定向到 profile/statuses/tab
    else if ([urlString containsString:@"statuses/user_timeline"]) {
        NSString *uid = extractUID(urlString) ?: storedUID;
        if (uid) {
            NSString *newURL = [urlString stringByReplacingOccurrencesOfString:@"statuses/user_timeline" withString:@"profile/statuses/tab"];
            newURL = [newURL stringByReplacingOccurrencesOfString:@"max_id" withString:@"since_id"];
            newURL = [NSString stringWithFormat:@"%@&containerid=230413%@_-_WEIBO_SECOND_PROFILE_WEIBO", newURL, uid];
            
            URL = [NSURL URLWithString:newURL];
            NSLog(@"[VVeboFix] Redirected URL: %@", newURL);
        }
    }
    
    %orig(URL);
}

%end

// Hook NSHTTPURLResponse 来处理响应数据
%hook NSHTTPURLResponse

- (instancetype)initWithURL:(NSURL *)url statusCode:(NSInteger)statusCode HTTPVersion:(NSString *)HTTPVersion headerFields:(NSDictionary<NSString *,NSString *> *)headerFields {
    NSString *urlString = url.absoluteString;
    
    if ([urlString containsString:@"profile/statuses/tab"]) {
        NSLog(@"[VVeboFix] Intercepted profile response: %@", urlString);
    }
    
    return %orig;
}

%end

// Hook NSURLSessionDataTask 的完成回调
%hook NSURLSessionDataTask

- (void)resume {
    NSURLRequest *request = [self originalRequest];
    NSString *urlString = request.URL.absoluteString;
    
    if ([urlString containsString:@"profile/statuses/tab"]) {
        NSLog(@"[VVeboFix] Intercepting profile/statuses/tab request");
        
        // 保存原始的完成处理程序
        id originalCompletionHandler = [self valueForKey:@"_completionHandler"];
        
        // 创建新的完成处理程序
        void (^newCompletionHandler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data && !error) {
                NSData *transformedData = transformProfileData(data);
                if (originalCompletionHandler) {
                    ((void (^)(NSData *, NSURLResponse *, NSError *))originalCompletionHandler)(transformedData, response, error);
                }
            } else {
                if (originalCompletionHandler) {
                    ((void (^)(NSData *, NSURLResponse *, NSError *))originalCompletionHandler)(data, response, error);
                }
            }
        };
        
        // 替换完成处理程序
        [self setValue:newCompletionHandler forKey:@"_completionHandler"];
    }
    
    %orig;
}

%end

%ctor {
    NSLog(@"[VVeboFix] Tweak loaded successfully for VVebo");
}