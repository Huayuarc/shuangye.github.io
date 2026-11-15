#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One event off the live stream, already copied out of the stream's proxy.
/// `type` is the unified log's os_log_type_t (0x00 default, 0x01 info,
/// 0x02 debug, 0x10 error, 0x11 fault). Return NO to stop listening early.
typedef BOOL (^ApelinLogEventHandler)(
    NSDate *_Nullable date,
    NSString *process,
    int pid,
    NSString *subsystem,
    NSString *category,
    uint8_t type,
    NSString *message
);

/// Listens to the unified log's live stream (LoggingSupport's
/// `OSLogEventLiveStream`, the stream `log stream` reads from diagnosticd)
/// for at most `seconds`, calling `handler` serially for each event, and
/// returns once the time is up or the handler returned NO. No handler call
/// happens after this returns.
///
/// Returns NO and sets `failure` when the stream class is not present or
/// does not answer the selectors it is driven with. A stream that delivers
/// nothing — the caller lacks the entitlement diagnosticd checks — returns
/// YES with no handler calls: diagnosticd does not report the refusal.
BOOL ApelinLogLiveStreamRun(
    NSTimeInterval seconds,
    ApelinLogEventHandler handler,
    NSString *_Nullable *_Nullable failure
);

/// Opens the live stream and keeps it open: `handler` is called serially for
/// each event until `ApelinLogLiveStreamClose` or until it returns NO. The
/// returned object is the open stream; pass it to the close exactly once.
/// Returns nil and sets `failure` the way `ApelinLogLiveStreamRun` does.
id _Nullable ApelinLogLiveStreamOpen(ApelinLogEventHandler handler, NSString *_Nullable *_Nullable failure);

/// Closes a stream `ApelinLogLiveStreamOpen` answered. No handler call
/// happens after this returns.
void ApelinLogLiveStreamClose(id stream);

NS_ASSUME_NONNULL_END
