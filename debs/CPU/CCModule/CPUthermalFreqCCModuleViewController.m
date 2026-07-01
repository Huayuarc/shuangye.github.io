#import "CPUthermalFreqCCModuleViewController.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <float.h>
#import <sys/sysctl.h>
#import <stdlib.h>
#import <mach/mach_time.h>
#import <CPUthermalPaths.h>

// ============================================================================
// 基准 P-State 频率表 (MHz)
// ============================================================================
static const NSInteger kBasePCPUFreqs[] = { 600, 972, 1332, 1692, 2052, 2412, 2772, 3000, 3132, 3456, 3780 };
static const NSInteger kBaseECPUFreqs[] = { 600, 972, 1332, 1692, 2016 };
static const NSInteger kBasePCPUFreqCount = 11;
static const NSInteger kBaseECPUFreqCount = 5;
static const NSInteger kLowPowerCeilingMHz = 2016;

// 显示策略：控制中心展示 P-Core（大核）频率，不再展示所有核心驻留平均值。
static const double kValidMinMHz = 100.0;
static const double kValidMaxMHz = 4200.0;
static const CGFloat kCompactFrequencyFontScale = 0.90;
static const NSInteger kTransientLowJumpThresholdMHz = 1200;
static const NSInteger kTransientHighReferenceMHz = 1800;
static const NSInteger kTransientLowJumpConfirmSamples = 3;

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
    NSInteger _sampleCount;
    NSInteger _deviceMaxPCoreMHz;
    NSInteger _pendingDisplayedMHz;
    NSInteger _pendingDisplayRepeatCount;
    NSArray<NSNumber *> *_pCoreFrequencies;
    NSArray<NSNumber *> *_eCoreFrequencies;
    BOOL _hasStableReading;
}
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UILabel *frequencyLabel;
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

    if ([self respondsToSelector:@selector(setUseTrailingCheckmarkLayout:)]) {
        [self setUseTrailingCheckmarkLayout:NO];
    }
    if ([self respondsToSelector:@selector(setUseTallLayout:)]) {
        [self setUseTallLayout:NO];
    }
    if ([self respondsToSelector:@selector(setHideGlyphInHeader:)]) {
        [self setHideGlyphInHeader:NO];
    }
    if ([self respondsToSelector:@selector(setShouldProvideOwnPlatter:)]) {
        [self setShouldProvideOwnPlatter:NO];
    }

	    _sampleCount = 0;
	    _hasStableReading = NO;
	    _lastDisplayedMHz = 0;
	    _pendingDisplayedMHz = 0;
	    _pendingDisplayRepeatCount = 0;
	    _deviceMaxPCoreMHz = [self deviceMaxPCoreMHz];
	    [self setupViews];
	    [self refreshFrequency];
	}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateCompactLayout];
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
    self.contentView = contentView;
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    contentView.backgroundColor = [UIColor clearColor];
    contentView.layer.cornerCurve = kCACornerCurveContinuous;
    contentView.clipsToBounds = YES;
    [self.view addSubview:contentView];

    self.frequencyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.frequencyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.frequencyLabel.textAlignment = NSTextAlignmentCenter;
    self.frequencyLabel.font = [UIFont monospacedDigitSystemFontOfSize:22.5 weight:UIFontWeightHeavy];
    self.frequencyLabel.textColor = [UIColor colorWithRed:1.0 green:0.49 blue:0.12 alpha:1.0];
    self.frequencyLabel.adjustsFontSizeToFitWidth = YES;
    self.frequencyLabel.minimumScaleFactor = 0.70;
    self.frequencyLabel.text = S("0");
    [contentView addSubview:self.frequencyLabel];

    [NSLayoutConstraint activateConstraints:@[
        [contentView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [contentView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [contentView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [contentView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.frequencyLabel.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor constant:4.0],
        [self.frequencyLabel.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor constant:-4.0],
        [self.frequencyLabel.centerYAnchor constraintEqualToAnchor:contentView.centerYAnchor]
    ]];

    [self updateCompactLayout];
}

- (void)updateCompactLayout {
    CGFloat side = MIN(CGRectGetWidth(self.view.bounds), CGRectGetHeight(self.view.bounds));
    if (side <= 0.0) {
        return;
    }

    self.contentView.layer.cornerRadius = MIN(22.0, MAX(16.0, side * 0.3125));

    CGFloat frequencySize = MAX(13.5, MIN(22.5, side * 0.36 * kCompactFrequencyFontScale));

    self.frequencyLabel.font = [UIFont monospacedDigitSystemFontOfSize:frequencySize weight:UIFontWeightHeavy];
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
#pragma mark - 设备频率表
// ============================================================================

- (NSString *)hardwareIdentifier {
    return CPUthermalHardwareIdentifier();
}

- (BOOL)isTargetDevice {
    return CPUthermalNativeMaxPCoreFrequencyMHzForHardware([self hardwareIdentifier]) > 0;
}

- (NSInteger)sysctlMaxFrequencyMHz {
    int64_t value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname("hw.cpufrequency_max", &value, &size, NULL, 0) != 0) {
        return 0;
    }

    NSInteger mhz = (NSInteger)llround([self rawValueToMHz:value]);
    if (mhz < kValidMinMHz || mhz > kValidMaxMHz) {
        return 0;
    }
    return mhz;
}

- (NSInteger)deviceMaxPCoreMHz {
    if (_deviceMaxPCoreMHz > 0) {
        return _deviceMaxPCoreMHz;
    }

    NSInteger nativeMax = CPUthermalNativeMaxPCoreFrequencyMHzForHardware([self hardwareIdentifier]);
    if (nativeMax > 0) {
        _deviceMaxPCoreMHz = nativeMax;
    } else {
        NSInteger sysctlMax = [self sysctlMaxFrequencyMHz];
        _deviceMaxPCoreMHz = (sysctlMax > 0) ? sysctlMax : kCPUthermalDefaultMaxPCoreFrequencyMHz;
    }

    return _deviceMaxPCoreMHz;
}

- (NSArray<NSNumber *> *)pCoreFrequencies {
    if (_pCoreFrequencies) {
        return _pCoreFrequencies;
    }

    NSInteger maxPCoreMHz = [self deviceMaxPCoreMHz];
    NSMutableArray<NSNumber *> *frequencies = [NSMutableArray arrayWithCapacity:kBasePCPUFreqCount];
    for (NSInteger i = 0; i < kBasePCPUFreqCount; i++) {
        NSInteger frequency = kBasePCPUFreqs[i];
        if (i == kBasePCPUFreqCount - 1) {
            frequency = maxPCoreMHz;
        }
        [frequencies addObject:@(frequency)];
    }
    _pCoreFrequencies = [frequencies copy];
    return _pCoreFrequencies;
}

- (NSArray<NSNumber *> *)eCoreFrequencies {
    if (_eCoreFrequencies) {
        return _eCoreFrequencies;
    }

    NSMutableArray<NSNumber *> *frequencies = [NSMutableArray arrayWithCapacity:kBaseECPUFreqCount];
    for (NSInteger i = 0; i < kBaseECPUFreqCount; i++) {
        [frequencies addObject:@(kBaseECPUFreqs[i])];
    }
    _eCoreFrequencies = [frequencies copy];
    return _eCoreFrequencies;
}

- (BOOL)isLowPowerModeActive {
    NSDictionary *prefs = CPUthermalReadPrefs();
    NSString *mode = prefs[S("powerMode")];
    return [mode isKindOfClass:[NSString class]] && [mode isEqualToString:S("lowPower")];
}

- (NSInteger)stableDisplayMHzForReading:(NSInteger)displayMHz {
    if (displayMHz <= 0) {
        return 0;
    }

    NSInteger maxPCoreMHz = [self deviceMaxPCoreMHz];
    if (maxPCoreMHz > 0 && displayMHz > maxPCoreMHz) {
        displayMHz = maxPCoreMHz;
    }

    if ([self isLowPowerModeActive] && displayMHz > kLowPowerCeilingMHz) {
        displayMHz = kLowPowerCeilingMHz;
    }

    if (_lastDisplayedMHz <= 0 || displayMHz >= kLowPowerCeilingMHz) {
        _pendingDisplayedMHz = 0;
        _pendingDisplayRepeatCount = 0;
        return displayMHz;
    }

    BOOL isTransientLowJump = (displayMHz <= kTransientLowJumpThresholdMHz &&
                               _lastDisplayedMHz >= kTransientHighReferenceMHz);
    if (!isTransientLowJump) {
        _pendingDisplayedMHz = 0;
        _pendingDisplayRepeatCount = 0;
        return displayMHz;
    }

    if (_pendingDisplayedMHz == displayMHz) {
        _pendingDisplayRepeatCount++;
    } else {
        _pendingDisplayedMHz = displayMHz;
        _pendingDisplayRepeatCount = 1;
    }

    if (_pendingDisplayRepeatCount < kTransientLowJumpConfirmSamples) {
        return _lastDisplayedMHz;
    }

    _pendingDisplayedMHz = 0;
    _pendingDisplayRepeatCount = 0;
    return displayMHz;
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
        }
        return;
    }

    _sampleCount++;
    _hasStableReading = YES;
	    NSInteger displayMHz = [self snapToPState:llround(mhz)];
	    if (displayMHz <= 0) {
	        displayMHz = (NSInteger)llround(mhz);
	    }
	    displayMHz = [self stableDisplayMHzForReading:displayMHz];
	    if (displayMHz <= 0) {
	        return;
	    }

	    _lastDisplayedMHz = displayMHz;
	    self.frequencyLabel.text = [NSString stringWithFormat:S("%ld"), (long)displayMHz];
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
    for (NSNumber *stateNumber in [self pCoreFrequencies]) {
        NSInteger state = [stateNumber integerValue];
        NSInteger delta = labs(mhz - state);
        NSInteger tolerance = MAX(60, (NSInteger)llround((double)state * 0.06));
        if (delta <= tolerance && delta < bestDelta) {
            bestDelta = delta;
            bestState = state;
        }
    }

    // 再尝试 E-core 频率表（低频段）
    for (NSNumber *stateNumber in [self eCoreFrequencies]) {
        NSInteger state = [stateNumber integerValue];
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
    // 第1层：IOReport P-Core 最高有效 P-State（大核当前档位）
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
#pragma mark - 第1层：IOReport P-Core P-State 频率
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

/// 通过 IOReport 读取 P-Core（大核）P-State。
/// 控制中心要显示大核档位，不能把 E-Core 和空闲驻留一起做平均，
/// 否则轻负载/桌面状态会被小核与低频驻留拖成 1000MHz 左右的动态值。
- (double)frequencyMHzForPStateIndex:(int)idx stateName:(NSString *)stateName {
    if (stateName.length > 0) {
        NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
        NSScanner *scanner = [NSScanner scannerWithString:stateName];
        while (!scanner.isAtEnd) {
            [scanner scanUpToCharactersFromSet:digits intoString:NULL];
            NSInteger value = 0;
            if ([scanner scanInteger:&value] && value >= kValidMinMHz && value <= kValidMaxMHz) {
                return (double)value;
            }
        }
    }

    NSArray<NSNumber *> *pCoreFrequencies = [self pCoreFrequencies];
    if (idx >= 0 && idx < (int)pCoreFrequencies.count) {
        return (double)[pCoreFrequencies[(NSUInteger)idx] integerValue];
    }
    return (double)[[pCoreFrequencies lastObject] integerValue];
}

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

    __block double bestPCoreFreq = 0.0;
    __block int64_t bestPCoreResidency = 0;

    _ioReportIterate(delta, ^int(CFDictionaryRef sample) {
        NSString *name = (__bridge NSString *)_ioReportChannelGetChannelName(sample);
        if (!name) return 0;

        // 只处理 PCPU 大核心；ECPU 小核心会导致控制中心显示偏低。
        BOOL isPCPU = [name hasPrefix:S("PCPU")];
        if (!isPCPU) return 0;

        // 跳过 PM 管理通道。
        if ([name isEqualToString:S("PCPM")]) return 0;

        int stateCount = _ioReportStateGetCount(sample);
        if (stateCount <= 0 || stateCount > 256) return 0;

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

            double stateFreq = [self frequencyMHzForPStateIndex:idx stateName:stateName];

            if (stateFreq > bestPCoreFreq ||
                (fabs(stateFreq - bestPCoreFreq) < DBL_EPSILON && residency > bestPCoreResidency)) {
                bestPCoreFreq = stateFreq;
                bestPCoreResidency = residency;
            }
        }

        return 0;
    });

    CFRelease(delta);

    return bestPCoreFreq;
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
    return 214.0;
}

- (CGFloat)preferredExpandedContentWidth {
    return 280.0;
}

- (BOOL)providesOwnPlatter {
    return NO;
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
    }
}

@end
