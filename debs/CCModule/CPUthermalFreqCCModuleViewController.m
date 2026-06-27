#import "CPUthermalFreqCCModuleViewController.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <sys/sysctl.h>

#define S(str) [NSString stringWithUTF8String:(str)]

typedef void *CPUthermalIOReportSubscriptionRef;
typedef CFDictionaryRef (*CPUthermalIOReportCopyChannelsInGroupFn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef CPUthermalIOReportSubscriptionRef (*CPUthermalIOReportCreateSubscriptionFn)(CFAllocatorRef, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CPUthermalIOReportCreateSamplesFn)(CPUthermalIOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CPUthermalIOReportCreateSamplesDeltaFn)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef int (*CPUthermalIOReportIterateFn)(CFDictionaryRef, int (^)(CFDictionaryRef));
typedef int64_t (*CPUthermalIOReportSimpleGetIntegerValueFn)(CFDictionaryRef, int);
typedef CFStringRef (*CPUthermalIOReportChannelGetChannelNameFn)(CFDictionaryRef);
typedef CFStringRef (*CPUthermalIOReportChannelGetUnitLabelFn)(CFDictionaryRef);
typedef int (*CPUthermalIOReportStateGetCountFn)(CFDictionaryRef);
typedef CFStringRef (*CPUthermalIOReportStateGetNameForIndexFn)(CFDictionaryRef, int);
typedef int64_t (*CPUthermalIOReportStateGetResidencyFn)(CFDictionaryRef, int);

@interface CPUthermalFreqCCModuleViewController () {
    void *_ioReportHandle;
    CPUthermalIOReportCopyChannelsInGroupFn _ioReportCopyChannelsInGroup;
    CPUthermalIOReportCreateSubscriptionFn _ioReportCreateSubscription;
    CPUthermalIOReportCreateSamplesFn _ioReportCreateSamples;
    CPUthermalIOReportCreateSamplesDeltaFn _ioReportCreateSamplesDelta;
    CPUthermalIOReportIterateFn _ioReportIterate;
    CPUthermalIOReportSimpleGetIntegerValueFn _ioReportSimpleGetIntegerValue;
    CPUthermalIOReportChannelGetChannelNameFn _ioReportChannelGetChannelName;
    CPUthermalIOReportChannelGetUnitLabelFn _ioReportChannelGetUnitLabel;
    CPUthermalIOReportStateGetCountFn _ioReportStateGetCount;
    CPUthermalIOReportStateGetNameForIndexFn _ioReportStateGetNameForIndex;
    CPUthermalIOReportStateGetResidencyFn _ioReportStateGetResidency;

    CPUthermalIOReportSubscriptionRef _clpcSubscription;
    CFMutableDictionaryRef _clpcChannels;
    CFDictionaryRef _lastCLPCSamples;

    CPUthermalIOReportSubscriptionRef _stateSubscription;
    CFMutableDictionaryRef _stateChannels;
    CFDictionaryRef _lastStateSamples;

    NSInteger _lastValidMHz;
}
@property (nonatomic, strong) UILabel *frequencyLabel;
@property (nonatomic, strong) UILabel *unitLabel;
@property (nonatomic, strong) UILabel *sourceLabel;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation CPUthermalFreqCCModuleViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = S("CPU频率");
    self.view.backgroundColor = [UIColor clearColor];
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
    [self releaseIOReportState];
}

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
    self.sourceLabel.text = S("REAL");
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

- (void)refreshFrequency {
    NSInteger mhz = [self currentCPUFrequencyMHz];
    if (mhz > 0) {
        _lastValidMHz = mhz;
        self.frequencyLabel.text = [NSString stringWithFormat:S("%ld"), (long)mhz];
        self.sourceLabel.text = S("REAL");
        return;
    }

    if (_lastValidMHz > 0) {
        self.frequencyLabel.text = [NSString stringWithFormat:S("%ld"), (long)_lastValidMHz];
        self.sourceLabel.text = S("IDLE");
        return;
    }

    self.frequencyLabel.text = S("----");
    self.sourceLabel.text = S("WAIT");
}

- (NSInteger)currentCPUFrequencyMHz {
    NSInteger ioReportValue = [self ioReportFrequencyMHz];
    if (ioReportValue > 0) return ioReportValue;

    NSInteger directValue = [self dynamicFrequencyFromIORegistry];
    if (directValue > 0) return directValue;

    NSInteger sysctlValue = [self cpuFrequencyFromSysctl];
    if (sysctlValue > 0) return sysctlValue;

    return 0;
}

- (BOOL)setupIOReportIfNeeded {
    if (_clpcSubscription && _stateSubscription) return YES;

    if (!_ioReportHandle) {
        _ioReportHandle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    }
    if (!_ioReportHandle) return NO;

    if (!_ioReportCopyChannelsInGroup) {
        _ioReportCopyChannelsInGroup = (CPUthermalIOReportCopyChannelsInGroupFn)dlsym(_ioReportHandle, "IOReportCopyChannelsInGroup");
        _ioReportCreateSubscription = (CPUthermalIOReportCreateSubscriptionFn)dlsym(_ioReportHandle, "IOReportCreateSubscription");
        _ioReportCreateSamples = (CPUthermalIOReportCreateSamplesFn)dlsym(_ioReportHandle, "IOReportCreateSamples");
        _ioReportCreateSamplesDelta = (CPUthermalIOReportCreateSamplesDeltaFn)dlsym(_ioReportHandle, "IOReportCreateSamplesDelta");
        _ioReportIterate = (CPUthermalIOReportIterateFn)dlsym(_ioReportHandle, "IOReportIterate");
        _ioReportSimpleGetIntegerValue = (CPUthermalIOReportSimpleGetIntegerValueFn)dlsym(_ioReportHandle, "IOReportSimpleGetIntegerValue");
        _ioReportChannelGetChannelName = (CPUthermalIOReportChannelGetChannelNameFn)dlsym(_ioReportHandle, "IOReportChannelGetChannelName");
        _ioReportChannelGetUnitLabel = (CPUthermalIOReportChannelGetUnitLabelFn)dlsym(_ioReportHandle, "IOReportChannelGetUnitLabel");
        _ioReportStateGetCount = (CPUthermalIOReportStateGetCountFn)dlsym(_ioReportHandle, "IOReportStateGetCount");
        _ioReportStateGetNameForIndex = (CPUthermalIOReportStateGetNameForIndexFn)dlsym(_ioReportHandle, "IOReportStateGetNameForIndex");
        _ioReportStateGetResidency = (CPUthermalIOReportStateGetResidencyFn)dlsym(_ioReportHandle, "IOReportStateGetResidency");
    }

    if (!_ioReportCopyChannelsInGroup || !_ioReportCreateSubscription || !_ioReportCreateSamples ||
        !_ioReportCreateSamplesDelta || !_ioReportIterate || !_ioReportSimpleGetIntegerValue ||
        !_ioReportChannelGetChannelName || !_ioReportChannelGetUnitLabel || !_ioReportStateGetCount ||
        !_ioReportStateGetNameForIndex || !_ioReportStateGetResidency) {
        return NO;
    }

    if (!_clpcSubscription) {
        [self createSubscriptionForGroup:S("CLPC Stats")
                                subgroup:S("Accumulators")
                            subscription:&_clpcSubscription
                                channels:&_clpcChannels];
    }
    if (!_stateSubscription) {
        [self createSubscriptionForGroup:S("CPU Stats")
                                subgroup:S("CPU Core Performance States")
                            subscription:&_stateSubscription
                                channels:&_stateChannels];
    }

    return _clpcSubscription && _clpcChannels && _stateSubscription && _stateChannels;
}

- (void)createSubscriptionForGroup:(NSString *)group
                          subgroup:(NSString *)subgroup
                      subscription:(CPUthermalIOReportSubscriptionRef *)subscription
                          channels:(CFMutableDictionaryRef *)channels {
    if (!subscription || !channels) return;

    CFDictionaryRef rawChannels = _ioReportCopyChannelsInGroup((__bridge CFStringRef)group,
                                                               (__bridge CFStringRef)subgroup,
                                                               0, 0, 0);
    if (!rawChannels) return;

    CFMutableDictionaryRef mutableChannels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, rawChannels);
    CFRelease(rawChannels);
    if (!mutableChannels) return;

    CFMutableDictionaryRef subscribedChannels = NULL;
    CPUthermalIOReportSubscriptionRef newSubscription = _ioReportCreateSubscription(kCFAllocatorDefault,
                                                                                    mutableChannels,
                                                                                    &subscribedChannels,
                                                                                    0,
                                                                                    NULL);
    CFRelease(mutableChannels);

    if (newSubscription && subscribedChannels) {
        *subscription = newSubscription;
        *channels = subscribedChannels;
        return;
    }

    if (newSubscription) CFRelease(newSubscription);
    if (subscribedChannels) CFRelease(subscribedChannels);
}

- (NSInteger)ioReportFrequencyMHz {
    if (![self setupIOReportIfNeeded]) return 0;

    CFDictionaryRef currentCLPCSamples = _ioReportCreateSamples(_clpcSubscription, _clpcChannels, NULL);
    CFDictionaryRef currentStateSamples = _ioReportCreateSamples(_stateSubscription, _stateChannels, NULL);
    if (!currentCLPCSamples || !currentStateSamples) {
        if (currentCLPCSamples) CFRelease(currentCLPCSamples);
        if (currentStateSamples) CFRelease(currentStateSamples);
        return 0;
    }

    if (!_lastCLPCSamples || !_lastStateSamples) {
        if (_lastCLPCSamples) CFRelease(_lastCLPCSamples);
        if (_lastStateSamples) CFRelease(_lastStateSamples);
        _lastCLPCSamples = currentCLPCSamples;
        _lastStateSamples = currentStateSamples;
        return 0;
    }

    CFDictionaryRef clpcDelta = _ioReportCreateSamplesDelta(_lastCLPCSamples, currentCLPCSamples, NULL);
    CFDictionaryRef stateDelta = _ioReportCreateSamplesDelta(_lastStateSamples, currentStateSamples, NULL);

    CFRelease(_lastCLPCSamples);
    CFRelease(_lastStateSamples);
    _lastCLPCSamples = currentCLPCSamples;
    _lastStateSamples = currentStateSamples;

    if (!clpcDelta || !stateDelta) {
        if (clpcDelta) CFRelease(clpcDelta);
        if (stateDelta) CFRelease(stateDelta);
        return 0;
    }

    double pCycles = 0.0;
    double eCycles = 0.0;
    [self extractCyclesFromCLPCDelta:clpcDelta pCycles:&pCycles eCycles:&eCycles];

    double pActiveSeconds = 0.0;
    double eActiveSeconds = 0.0;
    [self extractActiveSecondsFromStateDelta:stateDelta pSeconds:&pActiveSeconds eSeconds:&eActiveSeconds];

    CFRelease(clpcDelta);
    CFRelease(stateDelta);

    double pMHz = (pCycles > 0.0 && pActiveSeconds > 0.01) ? (pCycles / pActiveSeconds / 1000000.0) : 0.0;
    double eMHz = (eCycles > 0.0 && eActiveSeconds > 0.01) ? (eCycles / eActiveSeconds / 1000000.0) : 0.0;
    double bestMHz = MAX(pMHz, eMHz);

    if (bestMHz < 100.0 || bestMHz > 5000.0 || isnan(bestMHz) || isinf(bestMHz)) return 0;
    return (NSInteger)llround(bestMHz);
}

- (void)extractCyclesFromCLPCDelta:(CFDictionaryRef)delta pCycles:(double *)pCycles eCycles:(double *)eCycles {
    if (!delta) return;
    __block double pValue = 0.0;
    __block double eValue = 0.0;
    _ioReportIterate(delta, ^int(CFDictionaryRef sample) {
        NSString *name = (__bridge NSString *)_ioReportChannelGetChannelName(sample);
        int64_t value = _ioReportSimpleGetIntegerValue(sample, 0);
        if (value <= 0) return 0;
        if ([name isEqualToString:S("p-cyclecount")]) {
            pValue = (double)value;
        } else if ([name isEqualToString:S("e-cyclecount")]) {
            eValue = (double)value;
        }
        return 0;
    });
    if (pCycles) *pCycles = pValue;
    if (eCycles) *eCycles = eValue;
}

- (void)extractActiveSecondsFromStateDelta:(CFDictionaryRef)delta pSeconds:(double *)pSeconds eSeconds:(double *)eSeconds {
    if (!delta) return;
    __block double pValue = 0.0;
    __block double eValue = 0.0;
    _ioReportIterate(delta, ^int(CFDictionaryRef sample) {
        NSString *name = (__bridge NSString *)_ioReportChannelGetChannelName(sample);
        if (![name hasPrefix:S("PCPU")] && ![name hasPrefix:S("ECPU")]) return 0;
        if ([name isEqualToString:S("PCPM")] || [name isEqualToString:S("ECPM")]) return 0;

        double activeSeconds = [self activeSecondsFromStateSample:sample];

        if ([name hasPrefix:S("PCPU")]) {
            pValue += activeSeconds;
        } else if ([name hasPrefix:S("ECPU")]) {
            eValue += activeSeconds;
        }
        return 0;
    });
    if (pSeconds) *pSeconds = pValue;
    if (eSeconds) *eSeconds = eValue;
}

- (double)activeSecondsFromStateSample:(CFDictionaryRef)sample {
    int stateCount = _ioReportStateGetCount(sample);
    if (stateCount <= 0 || stateCount > 256) return 0.0;

    NSString *unitLabel = (__bridge NSString *)_ioReportChannelGetUnitLabel(sample);
    double divisor = [self residencySecondsDivisorForUnitLabel:unitLabel];
    if (divisor <= 0.0) return 0.0;

    double seconds = 0.0;
    for (int index = 0; index < stateCount; index++) {
        NSString *stateName = (__bridge NSString *)_ioReportStateGetNameForIndex(sample, index);
        if ([self shouldIgnoreResidencyStateName:stateName atIndex:index]) continue;

        int64_t residency = _ioReportStateGetResidency(sample, index);
        if (residency <= 0) continue;

        seconds += (double)residency / divisor;
    }

    return seconds;
}

- (BOOL)shouldIgnoreResidencyStateName:(NSString *)stateName atIndex:(int)index {
    if (stateName.length == 0) return index == 0;

    NSString *uppercaseName = [stateName uppercaseString];
    return [uppercaseName isEqualToString:S("IDLE")] ||
           [uppercaseName isEqualToString:S("DOWN")] ||
           [uppercaseName isEqualToString:S("OFF")];
}

- (double)residencySecondsDivisorForUnitLabel:(NSString *)unitLabel {
    NSString *trimmedUnit = [unitLabel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmedUnit isEqualToString:S("s")]) return 1.0;
    if ([trimmedUnit isEqualToString:S("ms")]) return 1000.0;
    if ([trimmedUnit isEqualToString:S("us")]) return 1000000.0;
    if ([trimmedUnit isEqualToString:S("ns")]) return 1000000000.0;
    if ([trimmedUnit isEqualToString:S("24Mticks")] || [trimmedUnit containsString:S("24M")]) return 24000000.0;
    return 1000000000.0;
}

- (NSInteger)dynamicFrequencyFromIORegistry {
    NSArray<NSString *> *serviceNames = @[
        S("clpc"),
        S("ppm"),
        S("AppleCLPC"),
        S("ApplePPM")
    ];
    NSArray<NSString *> *keys = @[
        S("CPUFrequency"),
        S("CPU Frequency"),
        S("current-frequency"),
        S("current-cpu-frequency"),
        S("cpu-current-frequency"),
        S("cpu-frequency"),
        S("freq"),
        S("frequency"),
        S("AETS p-limited mhz"),
        S("AETS e-limited mhz")
    ];

    for (NSString *serviceName in serviceNames) {
        io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceNameMatching([serviceName UTF8String]));
        if (!service) continue;
        NSInteger mhz = [self frequencyFromService:service keys:keys];
        IOObjectRelease(service);
        if (mhz > 0) return mhz;
    }

    return 0;
}

- (NSInteger)frequencyFromService:(io_service_t)service keys:(NSArray<NSString *> *)keys {
    for (NSString *key in keys) {
        CFTypeRef value = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
        NSInteger mhz = [self frequencyMHzFromObject:(__bridge id)value];
        if (value) CFRelease(value);
        if (mhz > 0) return mhz;
    }
    return 0;
}

- (NSInteger)frequencyMHzFromObject:(id)object {
    if (!object) return 0;

    if ([object isKindOfClass:[NSNumber class]]) {
        return [self normalizedMHzFromRawValue:[(NSNumber *)object longLongValue]];
    }

    if ([object isKindOfClass:[NSData class]]) {
        NSData *data = (NSData *)object;
        if (data.length >= sizeof(uint64_t)) {
            uint64_t value = 0;
            [data getBytes:&value length:sizeof(value)];
            NSInteger mhz = [self normalizedMHzFromRawValue:(int64_t)value];
            if (mhz > 0) return mhz;
        }
        if (data.length >= sizeof(uint32_t)) {
            uint32_t value = 0;
            [data getBytes:&value length:sizeof(value)];
            NSInteger mhz = [self normalizedMHzFromRawValue:value];
            if (mhz > 0) return mhz;
        }
    }

    if ([object isKindOfClass:[NSArray class]]) {
        NSInteger best = 0;
        for (id item in (NSArray *)object) {
            NSInteger mhz = [self frequencyMHzFromObject:item];
            if (mhz > best) best = mhz;
        }
        return best;
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSInteger best = 0;
        for (id value in [(NSDictionary *)object allValues]) {
            NSInteger mhz = [self frequencyMHzFromObject:value];
            if (mhz > best) best = mhz;
        }
        return best;
    }

    return 0;
}

- (NSInteger)normalizedMHzFromRawValue:(int64_t)value {
    if (value <= 0) return 0;
    int64_t mhz = value;
    if (mhz > 1000000000LL) mhz /= 1000000LL;
    else if (mhz > 1000000LL) mhz /= 1000LL;
    if (mhz < 100 || mhz > 5000) return 0;
    return (NSInteger)mhz;
}

- (NSInteger)cpuFrequencyFromSysctl {
    int64_t value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname("hw.cpufrequency", &value, &size, NULL, 0) == 0) {
        NSInteger mhz = [self normalizedMHzFromRawValue:value];
        if (mhz > 0) return mhz;
    }
    if (sysctlbyname("hw.cpufrequency_max", &value, &size, NULL, 0) == 0) {
        NSInteger mhz = [self normalizedMHzFromRawValue:value];
        if (mhz > 0) return mhz;
    }
    return 0;
}

- (void)releaseIOReportState {
    if (_lastCLPCSamples) {
        CFRelease(_lastCLPCSamples);
        _lastCLPCSamples = NULL;
    }
    if (_lastStateSamples) {
        CFRelease(_lastStateSamples);
        _lastStateSamples = NULL;
    }
    if (_clpcChannels) {
        CFRelease(_clpcChannels);
        _clpcChannels = NULL;
    }
    if (_stateChannels) {
        CFRelease(_stateChannels);
        _stateChannels = NULL;
    }
    if (_clpcSubscription) {
        CFRelease(_clpcSubscription);
        _clpcSubscription = NULL;
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
}

@end
