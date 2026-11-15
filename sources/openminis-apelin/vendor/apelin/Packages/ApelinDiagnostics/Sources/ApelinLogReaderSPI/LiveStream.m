#import "ApelinLogReaderSPI.h"
#import <dlfcn.h>
#import <objc/message.h>

// The live stream is LoggingSupport's: a system framework, resolved at run
// time, so this target links Foundation and libobjc and nothing else. The
// shape — a forwarding proxy per event, read by selector — is the one icli's
// `icli_syslog_json` drives; nothing of icli is linked or copied beyond that.

static id ApelinEventObject(id event, NSString *name) {
    // Events are forwarding proxies: respondsToSelector: says NO for
    // properties the proxy nevertheless answers through forwarding, so the
    // message is sent unconditionally.
    return ((id (*)(id, SEL))objc_msgSend)(event, NSSelectorFromString(name));
}

static NSString *ApelinEventString(id event, NSString *name) {
    id value = ApelinEventObject(event, name);
    return [value isKindOfClass:NSString.class] ? value : @"";
}

/// One open stream and the gate in front of its handler: once `finished`,
/// an event still inside the stream's queue leaves the handler alone.
@interface ApelinLiveStream : NSObject
@property(nonatomic, strong) id stream;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic) BOOL finished;
/// Signalled once, when the handler asks to stop.
@property(nonatomic, strong) dispatch_semaphore_t stopped;
@end

@implementation ApelinLiveStream
@end

id ApelinLogLiveStreamOpen(ApelinLogEventHandler handler, NSString **failure) {
    dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW);
    Class streamClass = NSClassFromString(@"OSLogEventLiveStream");
    SEL setHandler = NSSelectorFromString(@"setEventHandler:");
    SEL activate = NSSelectorFromString(@"activate");
    SEL invalidate = NSSelectorFromString(@"invalidate");
    id stream = streamClass ? [[streamClass alloc] init] : nil;
    if (!stream || ![stream respondsToSelector:setHandler] || ![stream respondsToSelector:activate]
        || ![stream respondsToSelector:invalidate]) {
        if (failure) *failure = @"The unified log live stream is not available on this system.";
        return nil;
    }

    ApelinLiveStream *open = [ApelinLiveStream new];
    open.stream = stream;
    open.lock = [NSLock new];
    open.stopped = dispatch_semaphore_create(0);
    SEL typeSelector = NSSelectorFromString(@"logType");
    SEL pidSelector = NSSelectorFromString(@"processIdentifier");
    // Weak: the stream holds this block, and `open` holds the stream.
    __weak ApelinLiveStream *gate = open;

    void (^eventHandler)(id) = ^(id event) {
        @autoreleasepool {
            ApelinLiveStream *strong = gate;
            if (!strong) return;
            id message = ApelinEventObject(event, @"composedMessage");
            if (![message isKindOfClass:NSString.class]) return;
            // The property is a small integer; only the low byte is defined.
            uint8_t type = (uint8_t)(((unsigned long long (*)(id, SEL))objc_msgSend)(event, typeSelector) & 0xFF);
            int pid = ((int (*)(id, SEL))objc_msgSend)(event, pidSelector);
            id date = ApelinEventObject(event, @"date");
            NSString *process = ApelinEventString(event, @"process");
            NSString *subsystem = ApelinEventString(event, @"subsystem");
            NSString *category = ApelinEventString(event, @"category");
            [strong.lock lock];
            if (!strong.finished) {
                BOOL more = handler(
                    [date isKindOfClass:NSDate.class] ? date : nil,
                    process,
                    pid,
                    subsystem,
                    category,
                    type,
                    message
                );
                if (!more) {
                    strong.finished = YES;
                    dispatch_semaphore_signal(strong.stopped);
                }
            }
            [strong.lock unlock];
        }
    };

    ((void (*)(id, SEL, id))objc_msgSend)(stream, setHandler, eventHandler);
    ((void (*)(id, SEL))objc_msgSend)(stream, activate);
    return open;
}

void ApelinLogLiveStreamClose(id stream) {
    ApelinLiveStream *open = stream;
    // Closing the gate before invalidating: an event already inside the
    // stream's queue finds `finished` and leaves the handler alone.
    [open.lock lock];
    open.finished = YES;
    [open.lock unlock];
    ((void (*)(id, SEL))objc_msgSend)(open.stream, NSSelectorFromString(@"invalidate"));
}

BOOL ApelinLogLiveStreamRun(NSTimeInterval seconds, ApelinLogEventHandler handler, NSString **failure) {
    ApelinLiveStream *open = ApelinLogLiveStreamOpen(handler, failure);
    if (!open) return NO;
    dispatch_semaphore_wait(open.stopped, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
    ApelinLogLiveStreamClose(open);
    return YES;
}
