#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <math.h>
#import "EQPrefs.h"

// ============================================================
// 地震事件数据模型
// ============================================================
@interface EQEvent : NSObject
@property (nonatomic, copy)   NSString *eventId;
@property (nonatomic, assign) double magnitude;
@property (nonatomic, copy)   NSString *place;
@property (nonatomic, assign) double latitude;
@property (nonatomic, assign) double longitude;
@property (nonatomic, assign) double depth;        // km
@property (nonatomic, assign) NSTimeInterval eventTime; // timestamp
@property (nonatomic, copy)   NSString *source;    // "usgs" or "ceic"
@end

@implementation EQEvent
- (NSString *)description {
    return [NSString stringWithFormat:@"[%@] M%.1f %@ (%.2f,%.2f) depth:%.1fkm time:%@",
            self.source, self.magnitude, self.place,
            self.latitude, self.longitude, self.depth,
            [NSDate dateWithTimeIntervalSince1970:self.eventTime]];
}
@end

// ============================================================
// 配置管理器
// ============================================================
@interface EQConfig : NSObject
@property (nonatomic, assign) double minMagnitude;       // 最低震级阈值
@property (nonatomic, assign) NSTimeInterval pollInterval; // 轮询间隔(秒)
@property (nonatomic, assign) BOOL usePrimarySource;     // YES=USGS, NO=CEIC
@property (nonatomic, assign) NSInteger failoverCount;   // 连续失败次数，触发切换
@property (nonatomic, assign) NSTimeInterval maxEventAge; // 只提醒足够新的目录事件
- (void)reloadPreferences;
@end

@implementation EQConfig
- (instancetype)init {
    self = [super init];
    if (self) {
        [self reloadPreferences];
        self.usePrimarySource = YES;
        self.failoverCount = 0;
    }
    return self;
}
- (void)reloadPreferences {
    self.minMagnitude = MAX(0.0, MIN(9.9, [EQPrefs doubleForKey:@"minMagnitude" defaultValue:2.5]));
    self.pollInterval = MAX(10.0, MIN(300.0, [EQPrefs doubleForKey:@"pollInterval" defaultValue:30.0]));
    self.maxEventAge = MAX(60.0, MIN(3600.0, [EQPrefs doubleForKey:@"maxEventAge" defaultValue:600.0]));
}
- (void)saveFailoverCount:(NSInteger)count {
    self.failoverCount = count;
}
@end

// ============================================================
// USGS API 解析器
// ============================================================
@interface USGSParser : NSObject
+ (NSArray<EQEvent *> *)parseData:(NSData *)data;
@end

@implementation USGSParser
+ (NSArray<EQEvent *> *)parseData:(NSData *)data {
    if (!data) return @[];
    NSError *err = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || !json[@"features"]) return @[];

    NSMutableArray *events = [NSMutableArray array];
    for (NSDictionary *feat in json[@"features"]) {
        NSDictionary *props = feat[@"properties"];
        NSDictionary *geom  = feat[@"geometry"];
        if (!props || !geom) continue;

        EQEvent *ev = [[EQEvent alloc] init];
        ev.eventId = feat[@"id"] ?: props[@"unid"] ?: props[@"source_id"] ?: @"";
        ev.magnitude = [props[@"mag"] doubleValue];
        ev.place = props[@"place"] ?: props[@"flynn_region"] ?: @"未知位置";
        id rawTime = props[@"time"];
        if ([rawTime isKindOfClass:NSNumber.class]) {
            ev.eventTime = [rawTime doubleValue] / 1000.0; // USGS 毫秒时间戳
        } else if ([rawTime isKindOfClass:NSString.class]) {
            NSISO8601DateFormatter *iso = [[NSISO8601DateFormatter alloc] init];
            ev.eventTime = [[iso dateFromString:rawTime] timeIntervalSince1970];
        }
        ev.depth = fabs([props[@"depth"] doubleValue]);
        ev.source = @"USGS";

        NSArray *coords = geom[@"coordinates"];
        if (coords.count >= 2) {
            ev.longitude = [coords[0] doubleValue];
            ev.latitude  = [coords[1] doubleValue];
        }
        if (coords.count >= 3 && ev.depth == 0) {
            ev.depth = fabs([coords[2] doubleValue]);
        }

        [events addObject:ev];
    }
    return events;
}
@end

// ============================================================
// CEIC (中国地震台网) 解析器
// ============================================================
@interface CEICParser : NSObject
+ (NSArray<EQEvent *> *)parseData:(NSData *)data;
@end

@implementation CEICParser
+ (NSArray<EQEvent *> *)parseData:(NSData *)data {
    if (!data) return @[];
    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err) return @[];

    // CEIC 返回格式: {"status":"success","data":[...]} 或 直接数组
    NSArray *items = nil;
    if ([json isKindOfClass:[NSDictionary class]]) {
        items = json[@"data"] ?: json[@"earthquakes"] ?: json[@"list"];
    } else if ([json isKindOfClass:[NSArray class]]) {
        items = json;
    }
    if (![items isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *events = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        EQEvent *ev = [[EQEvent alloc] init];

        // CEIC 常见字段名兼容
        ev.eventId   = item[@"id"] ?: item[@"event_id"] ?: item[@"EQID"] ?: @"";
        ev.magnitude = [item[@"magnitude"] doubleValue] ?: [item[@"mag"] doubleValue] ?: [item[@"M"] doubleValue];
        ev.place     = item[@"location"] ?: item[@"place"] ?: item[@"address"] ?: item[@"region"] ?: @"中国境内";
        ev.latitude  = [item[@"latitude"] doubleValue] ?: [item[@"lat"] doubleValue];
        ev.longitude = [item[@"longitude"] doubleValue] ?: [item[@"lon"] doubleValue];
        ev.depth     = [item[@"depth"] doubleValue] ?: [item[@"Depth"] doubleValue];
        ev.source    = @"CEIC";

        // 时间解析：CEIC 可能用多种格式
        NSString *timeStr = item[@"time"] ?: item[@"otime"] ?: item[@"O_TIME"] ?: item[@"date"];
        if (timeStr) {
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            // 尝试多种格式
            NSArray *formats = @[@"yyyy-MM-dd HH:mm:ss",
                                 @"yyyy/MM/dd HH:mm:ss",
                                 @"yyyy-MM-dd'T'HH:mm:ss",
                                 @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"];
            for (NSString *f in formats) {
                fmt.dateFormat = f;
                NSDate *d = [fmt dateFromString:timeStr];
                if (d) { ev.eventTime = [d timeIntervalSince1970]; break; }
            }
        }
        if (ev.eventTime == 0) ev.eventTime = [[NSDate date] timeIntervalSince1970];

        if (!ev.eventId.length) {
            ev.eventId = [NSString stringWithFormat:@"ceic_%.0f", ev.eventTime];
        }
        [events addObject:ev];
    }
    return events;
}
@end

// ============================================================
// 主守护进程
// ============================================================
@interface EQDaemon : NSObject
@property (nonatomic, strong) EQConfig *config;
@property (nonatomic, strong) NSSet<NSString *> *processedIDs; // 已处理的事件ID
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) NSDate *lastSwitchTime;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL bootstrapping;
@end

@implementation EQDaemon

- (instancetype)init {
    self = [super init];
    if (self) {
        _config = [[EQConfig alloc] init];
        _processedIDs = [NSSet set];
        [self loadProcessedIDs];
    }
    return self;
}

- (NSString *)stateFilePath {
    return @"/var/mobile/Library/Preferences/com.shuangye.earthquake.processed.plist";
}

- (void)loadProcessedIDs {
    NSArray *arr = [NSArray arrayWithContentsOfFile:self.stateFilePath];
    if (arr) self.processedIDs = [NSSet setWithArray:arr];
    NSLog(@"[EQDaemon] Loaded %lu processed events", (unsigned long)self.processedIDs.count);
}

- (void)saveProcessedIDs {
    [self.processedIDs.allObjects writeToFile:self.stateFilePath atomically:YES];
}

- (void)bootstrapProcessedEvents {
    self.bootstrapping = YES;
    [self log:@"首次运行：建立现有地震目录基线，不发出历史事件警报"];
}

- (void)startPolling {
    [self log:@"EQDaemon 启动 — 地震信息提醒守护进程"];
    [self log:[NSString stringWithFormat:@"震级阈值: %.1f | 数据源: %@",
               self.config.minMagnitude, self.config.usePrimarySource ? @"USGS(主)" : @"CEIC(备)"]];

    // 首次启动先把目录中已有事件记为基线，避免安装/重启后集中误报旧震。
    if (self.processedIDs.count == 0) [self bootstrapProcessedEvents];
    [self pollEarthquakes];

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0);
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    uint64_t interval = (uint64_t)(self.config.pollInterval * NSEC_PER_SEC);
    dispatch_source_set_timer(self.timer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
        interval,
        (uint64_t)(MIN(5.0, self.config.pollInterval / 10.0) * NSEC_PER_SEC));

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
        [weakSelf pollEarthquakes];
    });
    dispatch_resume(self.timer);

    self.running = YES;
    dispatch_main();
}

// ============================================================
// 核心：轮询地震 API
// ============================================================
- (void)pollEarthquakes {
    [self.config reloadPreferences];
    if (![EQPrefs boolForKey:@"enabled" defaultValue:YES]) {
        [self log:@"预警已在设置中暂停"];
        return;
    }
    [self log:@"--- 开始轮询地震数据 ---"];

    BOOL usePrimary = self.config.usePrimarySource;
    BOOL primarySuccess = NO;

    if (usePrimary) {
        primarySuccess = [self fetchUSGS];
        if (primarySuccess) {
            self.config.failoverCount = 0;
        } else {
            self.config.failoverCount++;
            [self log:[NSString stringWithFormat:@"USGS 失败(连续%ld次)", (long)self.config.failoverCount]];

            if (self.config.failoverCount >= 3) {
                [self log:@"⚠️ 切换到备用数据源 CEIC"];
                self.config.usePrimarySource = NO;
                self.lastSwitchTime = [NSDate date];
                [self fetchCEIC];
            }
        }
    } else {
        BOOL backupSuccess = [self fetchCEIC];
        if (backupSuccess) {
            self.config.failoverCount = 0;
            // 尝试恢复主源: 每10次尝试一次USGS
            if (arc4random_uniform(10) == 0) {
                BOOL recovered = [self fetchUSGS];
                if (recovered) {
                    [self log:@"✅ USGS 已恢复，切回主数据源"];
                    self.config.usePrimarySource = YES;
                }
            }
        } else {
            self.config.failoverCount++;
            [self log:[NSString stringWithFormat:@"CEIC 也失败(连续%ld次)", (long)self.config.failoverCount]];
            // 双源都失败时尝试恢复USGS
            if (self.config.failoverCount >= 3) {
                [self log:@"尝试恢复 USGS 主数据源..."];
                self.config.usePrimarySource = YES;
                self.config.failoverCount = 0;
            }
        }
    }
}

// ============================================================
// USGS 请求
// ============================================================
- (BOOL)fetchUSGS {
    // 过去一小时 2.5级以上地震
    NSString *urlStr = @"https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_hour.geojson";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:15];
    [req setValue:@"iOS Earthquake Monitor/1.0" forHTTPHeaderField:@"User-Agent"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = NO;

    NSURLSessionTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) {
                [self log:[NSString stringWithFormat:@"USGS 请求失败: %@", err.localizedDescription]];
                dispatch_semaphore_signal(sem);
                return;
            }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            if (http.statusCode != 200) {
                [self log:[NSString stringWithFormat:@"USGS HTTP %ld", (long)http.statusCode]];
                dispatch_semaphore_signal(sem);
                return;
            }
            NSArray *events = [USGSParser parseData:data];
            [self processEvents:events fromSource:@"USGS"];
            success = YES;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    return success;
}

// ============================================================
// CEIC 请求（中国地震台网）
// ============================================================
- (BOOL)fetchCEIC {
    // CEIC 未提供稳定、可直接消费的公开 JSON 接口；旧 speedsearch 地址现返回 404 HTML。
    // 使用独立机构 EMSC 的 FDSN GeoJSON 作为备用源，避免把网页误判为成功响应。
    NSArray *urls = @[
        @"https://www.seismicportal.eu/fdsnws/event/1/query?format=json&limit=50&minmag=2.5",
    ];

    __block BOOL anySuccess = NO;
    for (NSString *urlStr in urls) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                           cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                       timeoutInterval:10];
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X)"
              forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        NSURLSessionTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
                NSString *contentType = [http.allHeaderFields[@"Content-Type"] lowercaseString];
                if (!err && data && http.statusCode == 200 && [contentType containsString:@"json"]) {
                    NSArray *events = [USGSParser parseData:data];
                    for (EQEvent *event in events) event.source = @"EMSC";
                    [self processEvents:events fromSource:@"EMSC"];
                    if (events.count > 0) anySuccess = YES;
                }
                dispatch_semaphore_signal(sem);
            }];
        [task resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
        if (anySuccess) break;
    }

    // 如果 CEIC 不可达，尝试 USGS 中国区域过滤
    if (!anySuccess) {
        [self log:@"CEIC 不可达，尝试 USGS 中国区域数据..."];
        anySuccess = [self fetchUSGSChinaRegion];
    }
    return anySuccess;
}

// USGS 中国区域过滤（作为 CEIC 中断时的补充）
- (BOOL)fetchUSGSChinaRegion {
    // 中国地理范围: lat 18-54, lon 73-135
    NSString *urlStr = @"https://earthquake.usgs.gov/fdsnws/event/1/query?format=geojson"
                        "&minlatitude=18&maxlatitude=54&minlongitude=73&maxlongitude=135"
                        "&minmagnitude=2.5&orderby=time&limit=20";
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:15];
    [req setValue:@"iOS Earthquake Monitor/1.0" forHTTPHeaderField:@"User-Agent"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block BOOL success = NO;

    NSURLSessionTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (!err && data) {
                NSArray *events = [USGSParser parseData:data];
                [self processEvents:events fromSource:@"USGS-CN"];
                if (events.count > 0) success = YES;
            }
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));
    return success;
}

// ============================================================
// 地震事件处理核心
// ============================================================
- (void)processEvents:(NSArray<EQEvent *> *)events fromSource:(NSString *)source {
    if (events.count == 0) {
        [self log:[NSString stringWithFormat:@"%@: 无新地震数据", source]];
        return;
    }

    if (self.bootstrapping) {
        NSMutableSet *baseline = [self.processedIDs mutableCopy];
        for (EQEvent *ev in events) if (ev.eventId.length) [baseline addObject:ev.eventId];
        self.processedIDs = baseline;
        [self saveProcessedIDs];
        self.bootstrapping = NO;
        [self log:[NSString stringWithFormat:@"已记录 %lu 条基线事件", (unsigned long)events.count]];
        return;
    }

    // 按发生时间排序，优先处理最新事件。
    NSArray *sorted = [events sortedArrayUsingComparator:^NSComparisonResult(EQEvent *a, EQEvent *b) {
        return [@(b.eventTime) compare:@(a.eventTime)];
    }];

    double maxMagnitude = [[events valueForKeyPath:@"@max.magnitude"] doubleValue];
    [self log:[NSString stringWithFormat:@"%@: 收到 %lu 条记录, 最大 M%.1f",
               source, (unsigned long)events.count, maxMagnitude]];

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (EQEvent *ev in sorted) {
        if (!ev.eventId.length || !isfinite(ev.magnitude) || !isfinite(ev.eventTime)) continue;
        NSTimeInterval age = now - ev.eventTime;
        if (age < -120.0 || age > self.config.maxEventAge) {
            if (age > self.config.maxEventAge) {
                NSMutableSet *seen = [self.processedIDs mutableCopy];
                [seen addObject:ev.eventId];
                self.processedIDs = seen;
            }
            continue;
        }
        if (ev.magnitude < self.config.minMagnitude) continue;
        if ([self.processedIDs containsObject:ev.eventId]) continue;

        // 新地震事件！
        [self log:[NSString stringWithFormat:@"🚨 新地震事件: %@", ev]];

        // 更新已处理集合
        NSMutableSet *newSet = [self.processedIDs mutableCopy];
        [newSet addObject:ev.eventId];
        // 限制集合大小
        if (newSet.count > 1000) {
            NSArray *all = newSet.allObjects;
            newSet = [NSMutableSet setWithArray:[all subarrayWithRange:NSMakeRange(all.count-500, 500)]];
        }
        self.processedIDs = newSet;
        [self saveProcessedIDs];

        // 广播通知 + 本地通知
        [self broadcastAlert:ev];
    }
}

// ============================================================
// 广播地震警报
// ============================================================
- (void)broadcastAlert:(EQEvent *)event {
    // 1. 通过 CFPreferences 共享数据
    NSDictionary *eventDict = @{
        @"eventId":   event.eventId ?: @"",
        @"magnitude": @(event.magnitude),
        @"place":     event.place ?: @"未知位置",
        @"latitude":  @(event.latitude),
        @"longitude": @(event.longitude),
        @"depth":     @(event.depth),
        @"time":      @(event.eventTime),
        @"source":    event.source ?: @"unknown",
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
    };
    [eventDict writeToFile:@"/var/mobile/Library/Preferences/com.shuangye.earthquake.latest.plist"
                atomically:YES];

    // 2. Darwin 通知 → SpringBoard Tweak
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.shuangye.earthquake.alert"),
        NULL, NULL, YES);

    [self log:[NSString stringWithFormat:@"已广播地震警报: %@ M%.1f", event.place, event.magnitude]];

    // 3. 本地通知（锁屏提醒）
    [self scheduleLocalNotification:event];
}

// ============================================================
// 本地通知
// ============================================================
- (void)scheduleLocalNotification:(EQEvent *)event {
    // launchd 工具不是已注册的 UIApplication，不能可靠地自行申请通知权限。
    // 锁屏展示由 SpringBoard 注入界面承担；这里仅在系统已授权时作为补充。
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus != UNAuthorizationStatusAuthorized &&
            settings.authorizationStatus != UNAuthorizationStatusProvisional) {
            [center requestAuthorizationWithOptions:UNAuthorizationOptionAlert |
                                                  UNAuthorizationOptionSound |
                                                  UNAuthorizationOptionBadge
                                  completionHandler:^(BOOL granted, NSError *err) {
                if (granted) [self postLocalNotification:event];
            }];
            return;
        }
        [self postLocalNotification:event];
    }];
}

- (void)postLocalNotification:(EQEvent *)event {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"⚠️ 地震预警";
    content.subtitle = [NSString stringWithFormat:@"震级 M%.1f", event.magnitude];
    content.body = [NSString stringWithFormat:@"📍 %@\n📏 深度 %.1fkm", event.place, event.depth];
    content.sound = [UNNotificationSound defaultSound];
    content.badge = @1;

    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger
        triggerWithTimeInterval:1 repeats:NO];

    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:event.eventId
                                                                      content:content
                                                                      trigger:trigger];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req
                                                           withCompletionHandler:nil];
}

// ============================================================
// 日志
// ============================================================
- (void)log:(NSString *)msg {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *ts = [fmt stringFromDate:[NSDate date]];
    NSString *line = [NSString stringWithFormat:@"[EQDaemon][%@] %@", ts, msg];
    NSLog(@"%@", line);

    // 同时写入文件
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:@"/var/mobile/Documents/eqdaemon.log"];
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else {
            [line writeToFile:@"/var/mobile/Documents/eqdaemon.log" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    } @catch (id e) {}
}

@end

// ============================================================
// 入口
// ============================================================
int main(int argc, char *argv[]) {
    @autoreleasepool {
        EQDaemon *daemon = [[EQDaemon alloc] init];
        [daemon startPolling];
    }
    return 0;
}
