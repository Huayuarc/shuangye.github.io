#import "CPUthermalFreqCCModuleViewController.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <sys/sysctl.h>
#import <stdlib.h>
#import <mach/mach_time.h>

#define S(str) [NSString stringWithUTF8String:(str)]

// ============================================================================
// A15 (iPhone 13 Pro) P-State 频率表 (MHz)
// P-cores (Avalanche):  索引 0..8
// E-cores (Blizzard):   索引 0..4
// ============================================================================
static const NSInteger kPCPUFreqs[] = { 600, 972, 1332, 1692, 2052, 2412, 2772, 3132, 3240 };
static const NSInteger kECPUFreqs[] = { 600, 972, 1332, 1692, 2016 };
static const NSInteger kPCPUFreqCount = 9;
static const NSInteger kECPUFreqCount = 5;

// 平滑参数
static const double kSmoothingAlpha = 0.35;        // 指数平滑系数(值越小越平滑)
static const double kMaxFrequencyJump = 600.0;     // 每秒最大容忍跳变(MHz)
static const double kValidMinMHz = 100.0;
static const double kValidMaxMHz = 3600.0;
static const NSInteger kMinSamplesBeforeDisplay = 3;  // 至少采集N次再显示

// ============================================================================
// IOReport 函数指针类型
// ============================================================================
typedef void *IOReportSubscriptionRef;
typedef CFDictionaryRef (*IOReportCopyChannelsInGroupFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef IOReportSubscriptionRef (*IOReportCreateSubscriptionFn)(CFAllocatorRef, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*IOReportCreateSamplesFn)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*IOReportCreateSamplesDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int (*IOReportIterateFn)(CFDictionaryRef, int (^)(CFDictionaryRef));
typedef int64_t (*IOReportSimpleGetIntegerValueFn)(CFDictionaryRef, int);
typedef CFStringRef (*IOReportChannelGetChannelNameFn)(CFDictionaryRef);
typedef CFStringRef (*IOReportChannelGetUnitLabelFn)(CFDictionaryRef);
typedef int (*IOReportStateGetCountFn)(CFDictionaryRef);
typedef CFStringRef (*IOReportStateGetNameForIndexFn)(CFDictionaryRef, int);
typedef int64_t (*IOReportStateGetResidencyFn)(CFDictionaryRef, int);

// ============================================================================
// 接口
// ============================================================================
@interface CPUthermalFreqCCModuleViewController () {
    // IOReport
    void *_ioReportHandle;
    IOReportCopyChannelsInGroupFn _ioReportCopyChannelsInGroup;
    IOReportCreateSubscriptionFn _ioReportCreateSubscription;
    IOReportCreateSamplesFn _ioReportCreateSamples;
    IOReportCreateSamplesDeltaFn _ioReportCreateSamplesDelta;
    IOReportIterateFn _ioReportIterate;
    IOReportSimpleGetIntegerValueFn _ioReportSimpleGetIntegerValue;
    IOReportChannelGetChannelNameFn _ioReportChannelGetChannelName;
    IOReportChannelGetUnitLabelFn _ioReportChannelGetUnitLabel;
    IOReportStateGetCountFn _ioReportStateGetCount;
    IOReportStateGetNameForIndexFn _ioReportStateGetNameForIndex;
    IOReportStateGetResidencyFn _ioReportStateGetResidency;

    IOReportSubscriptionRef _stateSubscription;
    CFMutableDictionaryRef _stateChannels;
    CFDictionaryRef _lastStateSamples;

    // 运行时状态
    NSInteger _lastDisplayedMHz;
    double _smoothedMHz;
    NSInteger _sampleCount;
    BOOL _hasStableReading;
}
@property (nonatomic, strong) UILabel *frequencyLabel;
@property (nonatomic, strong) UILabel *unitLabel;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation CPUthermalFreqCCModuleViewController

// ============================================================================
#pragma mark - 生命周期
// ============================================================================

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = S("CPU频率");
    self.view.backgroundColor = [UIColor clearColor];
    _smoothedMHz = 0.0;
    _sampleCount = 0;
    _hasStableReading = NO;
    _lastDisplayedMHz = 0;
    [self setupViews];
    [self refreshFrequency];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshFrequency];
    [self startTimer];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self stopTimer];
}

- (void)dealloc {
    [self stopTimer];
    [self cleanupIOReport];
}

// ============================================================================
#pragma mark - UI
// ============================================================================

- (void)setupViews {
    UIView *contentView = [[UIView alloc] initWithFrame:CGRectZero];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    contentView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.36];
    contentView.layer.cornerRadius = 18.0;
    contentView.layer.cornerCurve = kCACornerCurveContinuous;
    contentView.clipsToBounds = YES;
    [self.view addSubview:contentView];

    self.frequencyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.frequencyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.frequencyLabel.textAlignment = NSTextAlignmentCenter;
    self.frequencyLabel.font = [UIFont monospacedDigitSystemFontOfSize:25.0 weight:UIFontWeightHeavy];
    self.frequencyLabel.textColor = [UIColor colorWithRed:1.0 green:0.49 blue:0.12 alpha:1.0];
    self.frequencyLabel.adjustsFontSizeToFitWidth = YES;
    self.frequencyLabel.minimumScaleFactor = 0.55;
    self.frequencyLabel.text = S("----");
    [contentView addSubview:self.frequencyLabel];

    self.unitLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.unitLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.unitLabel.textAlignment = NSTextAlignmentCenter;
    self.unitLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.0 weight:UIFontWeightSemibold];
    self.unitLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    self.unitLabel.text = S("MHz");
    [contentView addSubview:self.unitLabel];

    self.sourceLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.sourceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.sourceLabel.textAlignment = NSTextAlignmentCenter;
    self.sourceLabel.font = [UIFont systemFontOfSize:7.0 weight:UIFontWeightMedium];
    self.sourceLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.42];
    self.sourceLabel.text = S("CPU");
    [contentView addSubview:self.sourceLabel];

    [NSLayoutConstraint activateConstraints:@[
        [contentView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [contentView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.frequencyLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:4.0],
        [self.frequencyLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-4.0],
        [self.frequencyLabel.centerYAnchor constraintEqualToAnchor:contentView.centerYAnchor constant:-4.0],

        [self.unitLabel.topAnchor constraintEqualToAnchor:self.frequencyLabel.bottomAnchor constant:-2.0],
        [self.unitLabel.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor],

        [self.sourceLabel.topAnchor constraintEqualToAnchor:self.unitLabel.bottomAnchor constant:1.0],
        [self.sourceLabel.centerXAnchor constraintEqualToAnchor:contentView.centerXAnchor]
    ]];
}

- (void)startTimer {
    if (self.refreshTimer) return;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                         target:self
                                                       selector:@selector(refreshFrequency)
                                                       userInfo:nil
                                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)stopTimer {
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

// ============================================================================
#pragma mark - 频率读取主入口
// ============================================================================

- (void)refreshFrequency {
    double mhz = [self readCurrentFrequencyMHz];

    if (mhz < kValidMinMHz || mhz > kValidMaxMHz) {
        // 无效值：显示最后有效值（如果有）
        if (_lastDisplayedMHz > 0) {
            self.frequencyLabel.text = [NSString stringWithFormat:S("%ld"), (long)_lastDisplayedMHz];
            self.sourceLabel.text = S("HOLD");
        }
        return;
    }

    // 指数平滑
    if (_smoothedMHz < kValidMinMHz) {
        _smoothedMHz = mhz;
    } else {
        // 离群值剔除：跳变超过阈值则丢弃
        double delta = fabs(mhz - _smoothedMHz);
        if (delta <= kMaxFrequencyJump || _sampleCount < 2) {
            _smoothedMHz = kSmoothingAlpha * mhz + (1.0 - kSmoothingAlpha) * _smoothedMHz;
        }
        // 大幅跳变时不更新平滑值，直接丢弃这帧
    }

    _sampleCount++;

    // 前 N 帧不显示，积累稳定数据
    if (_sampleCount < kMinSamplesBeforeDisplay) {
        self.sourceLabel.text = S("WARM");
        return;
    }

    _hasStableReading = YES;
    NSInteger displayMHz = [self snapToPState:llround(_smoothedMHz)];
    if (displayMHz <= 0) {
        displayMHz = (NSInteger)llround(_smoothedMHz);
    }

    _lastDisplayedMHz = displayMHz;
    self.frequencyLabel.text = [NSString stringWithFormat:S("%ld"), (long)displayMHz];
    self.sourceLabel.text = S("REAL");
}

// ============================================================================
#pragma mark - P-State 匹配
// ============================================================================

/// 将测量值吸附到最近的已知 P-State 频率
- (NSInteger)snapToPState:(NSInteger)mhz {
    if (mhz <= 0) return 0;

    NSInteger bestState = 0;
    NSInteger bestDelta = NSIntegerMax;

    // 先尝试 P-core 频率表（高频段）
    for (NSInteger i = 0; i < kPCPUFreqCount; i++) {
        NSInteger state = kPCPUFreqs[i];
        NSInteger delta = labs(mhz - state);
        NSInteger tolerance = MAX(60, (NSInteger)llround((double)state * 0.06));
        if (delta <= tolerance && delta < bestDelta) {
            bestDelta = delta;
            bestState = state;
        }
    }

    // 再尝试 E-core 频率表（低频段）
    for (NSInteger i = 0; i < kECPUFreqCount; i++) {
        NSInteger state = kECPUFreqs[i];
        NSInteger delta = labs(mhz - state);
        NSInteger tolerance = MAX(60, (NSInteger)llround((double)state * 0.06));
        if (delta <= tolerance && delta < bestDelta) {
            bestDelta = delta;
            bestState = state;
        }
    }

    return bestState;
}

// ============================================================================
#pragma mark - 核心频率读取（三层策略）
// ============================================================================

- (double)readCurrentFrequencyMHz {
    // 第1层：IOReport P-State 驻留计算（最准确）
    double ioReportFreq = [self ioReportPStateFrequencyMHz];
    if (ioReportFreq >= kValidMinMHz && ioReportFreq <= kValidMaxMHz) {
        return ioReportFreq;
    }

    // 第2层：AppleCLPC IOKit 直读（次选，越狱环境有效）
    double clpcFreq = [self clpcFrequencyFromIOKit];
    if (clpcFreq >= kValidMinMHz && clpcFreq <= kValidMaxMHz) {
        return clpcFreq;
    }

    // 第3层：sysctl（兜底，一般只返回固定最大值）
    double sysctlFreq = [self sysctlFrequencyMHz];
    if (sysctlFreq >= kValidMinMHz && sysctlFreq <= kValidMaxMHz) {
        return sysctlFreq;
    }

    return 0.0;
}

// ============================================================================
#pragma mark - 第1层：IOReport P-State 驻留时间加权频率
// ============================================================================

- (BOOL)setupIOReport {
    if (_stateSubscription && _stateChannels) return YES;

    if (!_ioReportHandle) {
        _ioReportHandle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW | RTLD_GLOBAL);
        if (!_ioReportHandle) return NO;
    }

    // 解析符号（一次）
    if (!_ioReportCopyChannelsInGroup) {
        _ioReportCopyChannelsInGroup = (IOReportCopyChannelsInGroupFn)dlsym(_ioReportHandle, "IOReportCopyChannelsInGroup");
        _ioReportCreateSubscription = (IOReportCreateSubscriptionFn)dlsym(_ioReportHandle, "IOReportCreateSubscription");
        _ioReportCreateSamples = (IOReportCreateSamplesFn)dlsym(_ioReportHandle, "IOReportCreateSamples");
        _ioReportCreateSamplesDelta = (IOReportCreateSamplesDeltaFn)dlsym(_ioReportHandle, "IOReportCreateSamplesDelta");
        _ioReportIterate = (IOReportIterateFn)dlsym(_ioReportHandle, "IOReportIterate");
        _ioReportSimpleGetIntegerValue = (IOReportSimpleGetIntegerValueFn)dlsym(_ioReportHandle, "IOReportSimpleGetIntegerValue");
        _ioReportChannelGetChannelName = (IOReportChannelGetChannelNameFn)dlsym(_ioReportHandle, "IOReportChannelGetChannelName");
        _ioReportChannelGetUnitLabel = (IOReportChannelGetUnitLabelFn)dlsym(_ioReportHandle, "IOReportChannelGetUnitLabel");
        _ioReportStateGetCount = (IOReportStateGetCountFn)dlsym(_ioReportHandle, "IOReportStateGetCount");
        _ioReportStateGetNameForIndex = (IOReportStateGetNameForIndexFn)dlsym(_ioReportHandle, "IOReportStateGetNameForIndex");
        _ioReportStateGetResidency = (IOReportStateGetResidencyFn)dlsym(_ioReportHandle, "IOReportStateGetResidency");
    }

    if (!_ioReportCopyChannelsInGroup || !_ioReportCreateSubscription || !_ioReportCreateSamples ||
        !_ioReportCreateSamplesDelta || !_ioReportIterate || !_ioReportStateGetCount ||
        !_ioReportStateGetNameForIndex || !_ioReportStateGetResidency) {
        return NO;
    }

    if (!_stateSubscription) {
        [self subscribeToCPUPerformanceStates];
    }

    return (_stateSubscription != NULL && _stateChannels != NULL);
}

- (void)subscribeToCPUPerformanceStates {
    // 订阅 "CPU Stats" / "CPU Core Performance States"
    CFDictionaryRef rawChannels = _ioReportCopyChannelsInGroup(CFSTR("CPU Stats"),
                                                                CFSTR("CPU Core Performance States"),
                                                                0, 0, 0);
    if (!rawChannels) {
        // 尝试备用渠道名
        rawChannels = _ioReportCopyChannelsInGroup(CFSTR("CPU Stats"),
                                                   CFSTR("CPU Performance States"),
                                                   0, 0, 0);
    }
    if (!rawChannels) return;

    CFMutableDictionaryRef mutableChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, rawChannels);
    CFRelease(rawChannels);
    if (!mutableChannels) return;

    CFMutableDictionaryRef subscribedChannels = NULL;
    IOReportSubscriptionRef subscription = _ioReportCreateSubscription(kCFAllocatorDefault,
                                                                        mutableChannels,
                                                                        &subscribedChannels,
                                                                        0, NULL);
    CFRelease(mutableChannels);

    if (subscription && subscribedChannels) {
        _stateSubscription = subscription;
        _stateChannels = subscribedChannels;
    } else {
        if (subscription) CFRelease(subscription);
        if (subscribedChannels) CFRelease(subscribedChannels);
    }
}

/// 通过 IOReport P-State 驻留时间计算有效频率
/// 原理: 每个核心的驻留时间分布在各个 P-State 上
///       effective_freq = Σ(residency_i * freq_i) / Σ(residency_i)
///       其中 freq_i 是 P-State i 对应的频率
- (double)ioReportPStateFrequencyMHz {
    if (![self setupIOReport]) return 0.0;

    CFDictionaryRef currentSamples = _ioReportCreateSamples(_stateSubscription, _stateChannels, NULL);
    if (!currentSamples) {
        return 0.0;
    }

    // 首次调用：只存储，不计算
    if (!_lastStateSamples) {
        _lastStateSamples = currentSamples;
        return 0.0;
    }

    // 计算 delta
    CFDictionaryRef delta = _ioReportCreateSamplesDelta(_lastStateSamples, currentSamples, NULL);
    CFRelease(_lastStateSamples);
    _lastStateSamples = currentSamples;

    if (!delta) return 0.0;

    // 从 delta 中解析每个核心每个 P-State 的驻留时间
    __block double totalWeightedFreq = 0.0;
    __block double totalResidency = 0.0;

    _ioReportIterate(delta, ^int(CFDictionaryRef sample) {
        NSString *name = (__bridge NSString *)_ioReportChannelGetChannelName(sample);
        if (!name) return 0;

        // 只处理 PCPU 和 ECPU 核心状态
        BOOL isPCPU = [name hasPrefix:S("PCPU")];
        BOOL isECPU = [name hasPrefix:S("ECPU")];
        if (!isPCPU && !isECPU) return 0;

        // 跳过 PM 管理通道（PCPM / ECPM）
        if ([name isEqualToString:S("PCPM")] || [name isEqualToString:S("ECPM")]) return 0;

        int stateCount = _ioReportStateGetCount(sample);
        if (stateCount <= 0 || stateCount > 256) return 0;

        // 确定该核心的 P-State 频率表
        const NSInteger *freqTable = isPCPU ? kPCPUFreqs : kECPUFreqs;
        NSInteger freqCount = isPCPU ? kPCPUFreqCount : kECPUFreqCount;

        // 遍历每个 P-State 索引
        for (int idx = 0; idx < stateCount; idx++) {
            NSString *stateName = (__bridge NSString *)_ioReportStateGetNameForIndex(sample, idx);
            int64_t residency = _ioReportStateGetResidency(sample, idx);

            if (residency <= 0) continue;

            // 跳过空闲/关闭状态
            BOOL isIdle = NO;
            if (stateName) {
                NSString *upper = [stateName uppercaseString];
                isIdle = [upper isEqualToString:S("IDLE")] ||
                         [upper isEqualToString:S("DOWN")] ||
                         [upper isEqualToString:S("OFF")] ||
                         [upper hasPrefix:S("SLEEP")];
            } else {
                // 无名状态且索引为 0 通常是 IDLE
                isIdle = (idx == 0);
            }

            if (isIdle) continue;

            // State 索引对应 P-State 频率表中的索引
            // 限制索引范围
            double stateFreq = 0.0;
            if (idx >= 0 && idx < freqCount) {
                stateFreq = (double)freqTable[idx];
            } else {
                // 索引超出频率表范围，使用最后已知频率
                stateFreq = (double)freqTable[freqCount - 1];
            }

            totalWeightedFreq += (double)residency * stateFreq;
            totalResidency += (double)residency;
        }

        return 0;
    });

    CFRelease(delta);

    if (totalResidency <= 0.0) return 0.0;

    return totalWeightedFreq / totalResidency;
}

// ============================================================================
#pragma mark - 第2层：AppleCLPC IOKit 直读（越狱环境）
// ============================================================================

- (double)clpcFrequencyFromIOKit {
    // 尝试多个可能的 IOKit 服务名
    NSArray *serviceNames = @[
        S("AppleCLPC"),
        S("clpc"),
        S("ApplePPM"),
        S("ppm"),
        S("pmu")
    ];

    NSArray *freqKeys = @[
        S("CPUFrequency"),
        S("CPU Frequency"),
        S("current-frequency"),
        S("current-cpu-frequency"),
        S("cpu-current-frequency"),
        S("cpu-frequency"),
        S("frequency"),
        S("freq"),
        S("AETS p-limited mhz"),
        S("AETS e-limited mhz")
    ];

    for (NSString *serviceName in serviceNames) {
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                           IOServiceNameMatching([serviceName UTF8String]));
        if (!service) continue;

        for (NSString *key in freqKeys) {
            CFTypeRef value = IORegistryEntryCreateCFProperty(service,
                                                               (__bridge CFStringRef)key,
                                                               kCFAllocatorDefault, 0);
            if (!value) continue;

            double mhz = [self extractMHzFromIOObject:(__bridge id)value];
            CFRelease(value);
            if (mhz >= kValidMinMHz && mhz <= kValidMaxMHz) {
                IOObjectRelease(service);
                return mhz;
            }
        }
        IOObjectRelease(service);
    }

    return 0.0;
}

- (double)extractMHzFromIOObject:(id)object {
    if (!object) return 0.0;

    if ([object isKindOfClass:[NSNumber class]]) {
        return [self rawValueToMHz:[(NSNumber *)object longLongValue]];
    }

    if ([object isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)object;
        if (data.length >= 8) {
            uint64_t val64 = 0;
            [data getBytes:&val64 length:8];
            double mhz = [self rawValueToMHz:(int64_t)val64];
            if (mhz >= kValidMinMHz) return mhz;
        }
        if (data.length >= 4) {
            uint32_t val32 = 0;
            [data getBytes:&val32 length:4];
            return [self rawValueToMHz:val32];
        }
    }

    if ([object isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)object) {
            double mhz = [self extractMHzFromIOObject:item];
            if (mhz >= kValidMinMHz) return mhz;
        }
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        for (id value in [(NSDictionary *)object allValues]) {
            double mhz = [self extractMHzFromIOObject:value];
            if (mhz >= kValidMinMHz) return mhz;
        }
    }

    return 0.0;
}

- (double)rawValueToMHz:(int64_t)value {
    if (value <= 0) return 0.0;
    double mhz = (double)value;
    if (mhz >= 1000000000.0) mhz /= 1000000.0;
    else if (mhz >= 1000000.0) mhz /= 1000.0;
    if (mhz < kValidMinMHz || mhz > kValidMaxMHz) return 0.0;
    return mhz;
}

// ============================================================================
#pragma mark - 第3层：sysctl 兜底
// ============================================================================

- (double)sysctlFrequencyMHz {
    int64_t value = 0;
    size_t size = sizeof(value);

    if (sysctlbyname("hw.cpufrequency", &value, &size, NULL, 0) == 0) {
        double mhz = [self rawValueToMHz:value];
        if (mhz >= kValidMinMHz) return mhz;
    }

    if (sysctlbyname("hw.cpufrequency_max", &value, &size, NULL, 0) == 0) {
        double mhz = [self rawValueToMHz:value];
        if (mhz >= kValidMinMHz) return mhz;
    }

    // 备用: 从 timebase 频率估算
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    if (tb.denom > 0 && tb.numer > 0) {
        // timebase freq ~ 24 MHz on A-series
        // tb_freq = 1e9 * tb.denom / tb.numer
        // 这个值不是 CPU 频率，但可以用来帮助判断设备类型
        double tbFreq = 1000000000.0 * (double)tb.denom / (double)tb.numer;
        if (tbFreq > 20000000.0 && tbFreq < 30000000.0) {
            // A15 典型 timebase ~24MHz, 不是 CPU 频率
            return 0.0;
        }
    }

    return 0.0;
}

// ============================================================================
#pragma mark - 清理
// ============================================================================

- (void)cleanupIOReport {
    if (_lastStateSamples) {
        CFRelease(_lastStateSamples);
        _lastStateSamples = NULL;
    }
    if (_stateChannels) {
        CFRelease(_stateChannels);
        _stateChannels = NULL;
    }
    if (_stateSubscription) {
        CFRelease(_stateSubscription);
        _stateSubscription = NULL;
    }
    if (_ioReportHandle) {
        dlclose(_ioReportHandle);
        _ioReportHandle = NULL;
    }
}

// ============================================================================
#pragma mark - CCUIContentModuleContentViewController
// ============================================================================

- (CGFloat)preferredExpandedContentHeight {
    return 64.0;
}

- (CGFloat)preferredExpandedContentWidth {
    return 64.0;
}

- (BOOL)providesOwnPlatter {
    return YES;
}

- (BOOL)shouldBeginTransitionToExpandedContentModule {
    return NO;
}

- (BOOL)_toggleModuleExpanded {
    return NO;
}

- (void)buttonTapped:(id)arg forEvent:(id)event {
    [self refreshFrequency];

    // 点击时可选择重置采样积累（重新 warm up）
    // 如果已经稳定显示，不重置
    if (!_hasStableReading) {
        _sampleCount = 0;
        _smoothedMHz = 0.0;
    }
}

@end
