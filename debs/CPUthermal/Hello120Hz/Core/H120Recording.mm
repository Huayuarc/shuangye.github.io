#import "H120Recording.h"
#import "H120Runtime.h"
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <dlfcn.h>
#include <pthread.h>
#include <cstring>
#include <cstdint>

#if __has_feature(objc_arc)
#error Compile H120Recording.mm with -fno-objc-arc
#endif

namespace {
constexpr int32_t kRecordingFPS = 120;
pthread_key_t captureContextKey;
pthread_key_t writerContextKey;
char systemRecordingMarker;
uint32_t installedHooks;
IMP originalCaptureFactory;
IMP originalWriterInputInit;
IMP originalStartSession;
IMP originalMovieWriterSetup;

const char *Unqualified(const char *type) {
    if (!type) return "";
    while (*type && std::strchr("rnNoORV", *type)) ++type;
    return type;
}
bool ExactType(const char *type, const char *expected) {
    return std::strcmp(Unqualified(type), expected) == 0;
}
bool ObjectType(const char *type) {
    type = Unqualified(type);
    return type[0] == '@' && (type[1] == '\0' || type[1] == '"');
}
bool BlockType(const char *type) {
    return ExactType(type, "@?");
}
bool BooleanType(const char *type) {
    return ExactType(type, "B") || ExactType(type, "c");
}
bool TimeType(const char *type) {

    return ExactType(type, "{?=qiIq}") || ExactType(type, "{CMTime=qiIq}");
}
NSMethodSignature *Signature(Class cls, SEL selector, bool classMethod) {
    if (!cls) return nil;
    Method method = classMethod ? class_getClassMethod(cls, selector)
                                : class_getInstanceMethod(cls, selector);
    const char *types = method ? method_getTypeEncoding(method) : nullptr;
    return types ? [NSMethodSignature signatureWithObjCTypes:types] : nil;
}
bool HasArguments(NSMethodSignature *signature, NSUInteger count) {
    return signature && signature.numberOfArguments == count;
}
bool ActiveRecordingContext(pthread_key_t key) {
    return H120FeatureEnabled() && pthread_getspecific(key);
}
void *SetRecordingContext(pthread_key_t key, bool systemRecording) {
    void *previous = pthread_getspecific(key);
    pthread_setspecific(key,
        systemRecording && H120FeatureEnabled() ? &systemRecordingMarker : nullptr);
    return previous;
}

id CaptureFactory(id receiver, SEL selector, CGSize size, CMTime interval) {
    if (ActiveRecordingContext(captureContextKey)) {
        interval = CMTimeMake(1, kRecordingFPS);
        auto exportedKey = reinterpret_cast<CFStringRef *>(
            dlsym(RTLD_DEFAULT, "kFigVirtualDisplaySinkOption_VSyncRate"));
        SEL optionSelector = sel_registerName("setFigVirtualDisplayOption:forKey:");
        NSMethodSignature *signature = Signature((Class)receiver, optionSelector, true);
        if (exportedKey && *exportedKey && HasArguments(signature, 4) &&
            ExactType(signature.methodReturnType, "v") &&
            ObjectType([signature getArgumentTypeAtIndex:2]) &&
            ObjectType([signature getArgumentTypeAtIndex:3])) {
            using SetOption = void (*)(id, SEL, id, id);
            reinterpret_cast<SetOption>(objc_msgSend)(
                receiver, optionSelector, @(kRecordingFPS), (id)*exportedKey);
        }
    }
    using Factory = id (*)(id, SEL, CGSize, CMTime);
    return reinterpret_cast<Factory>(originalCaptureFactory)(receiver, selector, size, interval);
}

id WriterInputInit(id receiver, SEL selector, NSString *mediaType, NSDictionary *settings) {
    NSDictionary *effective = settings;
    NSMutableDictionary *adjusted = nil;
    if (ActiveRecordingContext(writerContextKey) && [mediaType isEqualToString:AVMediaTypeVideo] &&
        [settings isKindOfClass:[NSDictionary class]]) {
        adjusted = [settings mutableCopy];
        id existing = [settings objectForKey:AVVideoCompressionPropertiesKey];
        NSMutableDictionary *compression = [existing isKindOfClass:[NSDictionary class]]
            ? [existing mutableCopy] : [[NSMutableDictionary alloc] init];
        id oldFPS = [compression objectForKey:AVVideoExpectedSourceFrameRateKey];
        id oldRate = [compression objectForKey:AVVideoAverageBitRateKey];

        if ((!oldFPS || [oldFPS respondsToSelector:@selector(doubleValue)]) &&
            [oldFPS doubleValue] < kRecordingFPS &&
            [oldRate respondsToSelector:@selector(longLongValue)]) {
            int64_t rate = [oldRate longLongValue];
            if (rate > 0 && rate < (INT64_C(1) << 62)) {
                [compression setObject:@(rate * 2) forKey:AVVideoAverageBitRateKey];
            }
        }
        [compression setObject:@(kRecordingFPS) forKey:AVVideoExpectedSourceFrameRateKey];
        [compression setObject:@(kRecordingFPS) forKey:AVVideoMaxKeyFrameIntervalKey];
        [adjusted setObject:compression forKey:AVVideoCompressionPropertiesKey];
        [compression release];
        effective = adjusted;
    }
    using Init = id (*)(id, SEL, NSString *, NSDictionary *);
    id result;
    @try {
        result = reinterpret_cast<Init>(originalWriterInputInit)(receiver, selector, mediaType, effective);
    } @finally {
        [adjusted release];
    }
    return result;
}

void StartSession(id receiver, SEL selector, int pid, CGSize size, bool systemRecording,
                  id contextIDs, id outputHandler, id didStartHandler) {
    void *previous = SetRecordingContext(captureContextKey, systemRecording);
    @try {
        using Start = void (*)(id, SEL, int, CGSize, bool, id, id, id);
        reinterpret_cast<Start>(originalStartSession)(receiver, selector, pid, size,
            systemRecording, contextIDs, outputHandler, didStartHandler);
    } @finally {
        pthread_setspecific(captureContextKey, previous);
    }
}

void MovieWriterSetup(id receiver, SEL selector, id handler) {
    bool systemRecording = false;
    SEL flagSelector = sel_registerName("systemRecording");
    NSMethodSignature *signature = Signature(object_getClass(receiver), flagSelector, false);
    if (HasArguments(signature, 2) && BooleanType(signature.methodReturnType)) {
        using ReadFlag = bool (*)(id, SEL);
        systemRecording = reinterpret_cast<ReadFlag>(objc_msgSend)(receiver, flagSelector);
    }
    void *previous = SetRecordingContext(writerContextKey, systemRecording);
    @try {
        using Setup = void (*)(id, SEL, id);
        reinterpret_cast<Setup>(originalMovieWriterSetup)(receiver, selector, handler);
    } @finally {
        pthread_setspecific(writerContextKey, previous);
    }
}
}

uint32_t H120InstallRecordingHooks(void) {
    @synchronized ([NSMethodSignature class]) {
        static bool keyReady;
        if (!keyReady) {
            if (pthread_key_create(&captureContextKey, nullptr) != 0) return installedHooks;
            if (pthread_key_create(&writerContextKey, nullptr) != 0) {
                pthread_key_delete(captureContextKey);
                return installedHooks;
            }
            keyReady = true;
        }
        Class capture = NSClassFromString(@"FigScreenCaptureController");
        SEL factory = sel_registerName("screenCaptureControllerWithSize:minIntervalBetweenFrames:");
        NSMethodSignature *signature = Signature(capture, factory, true);
        if (!(installedHooks & H120RecordingCaptureFactory) && HasArguments(signature, 4) &&
            ObjectType(signature.methodReturnType) &&
            ExactType([signature getArgumentTypeAtIndex:2], "{CGSize=dd}") &&
            TimeType([signature getArgumentTypeAtIndex:3])) {
            MSHookMessageEx(object_getClass(capture), factory, (IMP)CaptureFactory, &originalCaptureFactory);
            installedHooks |= H120RecordingCaptureFactory;
        }
        Class writer = NSClassFromString(@"AVAssetWriterInput");
        SEL initializer = sel_registerName("initWithMediaType:outputSettings:");
        signature = Signature(writer, initializer, false);
        if (!(installedHooks & H120RecordingAssetWriterInput) && HasArguments(signature, 4) &&
            ObjectType(signature.methodReturnType) &&
            ObjectType([signature getArgumentTypeAtIndex:2]) &&
            ObjectType([signature getArgumentTypeAtIndex:3])) {
            MSHookMessageEx(writer, initializer, (IMP)WriterInputInit, &originalWriterInputInit);
            installedHooks |= H120RecordingAssetWriterInput;
        }
        Class manager = NSClassFromString(@"RPScreenCaptureManagerIOS");
        SEL start = sel_registerName("startSessionWithPID:windowSize:systemRecording:contextIDs:outputHandler:didStartHandler:");
        signature = Signature(manager, start, false);
        if (!(installedHooks & H120RecordingStartSession) && HasArguments(signature, 8) &&
            ExactType(signature.methodReturnType, "v") &&
            ExactType([signature getArgumentTypeAtIndex:2], "i") &&
            ExactType([signature getArgumentTypeAtIndex:3], "{CGSize=dd}") &&
            BooleanType([signature getArgumentTypeAtIndex:4]) &&
            ObjectType([signature getArgumentTypeAtIndex:5]) &&
            BlockType([signature getArgumentTypeAtIndex:6]) &&
            BlockType([signature getArgumentTypeAtIndex:7])) {
            MSHookMessageEx(manager, start, (IMP)StartSession, &originalStartSession);
            installedHooks |= H120RecordingStartSession;
        }

        Class movieWriter = NSClassFromString(@"RPMovieWriter");
        SEL setup = sel_registerName("setUpAssetWriterWithHandler:");
        signature = Signature(movieWriter, setup, false);
        NSMethodSignature *flag = Signature(movieWriter, sel_registerName("systemRecording"), false);
        if (!(installedHooks & H120RecordingMovieWriterSetup) && HasArguments(signature, 3) &&
            ExactType(signature.methodReturnType, "v") && BlockType([signature getArgumentTypeAtIndex:2]) &&
            HasArguments(flag, 2) && BooleanType(flag.methodReturnType)) {
            MSHookMessageEx(movieWriter, setup, (IMP)MovieWriterSetup, &originalMovieWriterSetup);
            installedHooks |= H120RecordingMovieWriterSetup;
        }
        return installedHooks;
    }
}
