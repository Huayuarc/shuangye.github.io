import Foundation

/// Every bound the protocol enforces, in one place so both ends agree on what
/// the defaults are. The host's values win: it announces `maxFrameBytes` and
/// `maxConcurrentCalls` in `hello`, and the extension may lower the latter.
public struct ToolProtocolLimits: Hashable, Sendable {
    /// The longest line either side accepts, newline excluded.
    public var maxFrameBytes: Int
    /// Calls in flight at once. The host queues the rest; the extension
    /// answers `busy` past its own limit.
    public var maxConcurrentCalls: Int
    /// How long `hello` may take to come back.
    public var helloTimeout: TimeInterval
    /// A call's timeout when neither the caller nor the manifest names one.
    public var defaultCallTimeout: TimeInterval
    /// The longest timeout a manifest or caller may ask for.
    public var maxCallTimeout: TimeInterval
    /// After a cancel or timeout, how long the extension has to end the call
    /// before the host stops the process: a tool that ignores cancellation
    /// would otherwise hold its slot forever.
    public var cancelGrace: TimeInterval
    /// The largest file one attachment may be.
    public var maxAttachmentBytes: Int
    /// Attachments one frame may reference.
    public var maxAttachmentsPerFrame: Int
    /// Descriptors received but not yet claimed by a frame.
    public var maxPendingAttachments: Int
    /// How long a frame waits for an attachment it names to arrive.
    public var attachmentWait: TimeInterval
    /// stderr lines longer than this are cut.
    public var maxLogLineBytes: Int
    /// stderr lines kept for a crash report.
    public var logTailLines: Int

    public init(
        maxFrameBytes: Int = 1 << 20,
        maxConcurrentCalls: Int = 4,
        helloTimeout: TimeInterval = 5,
        defaultCallTimeout: TimeInterval = 30,
        maxCallTimeout: TimeInterval = 300,
        cancelGrace: TimeInterval = 2,
        maxAttachmentBytes: Int = 32 << 20,
        maxAttachmentsPerFrame: Int = 8,
        maxPendingAttachments: Int = 32,
        attachmentWait: TimeInterval = 2,
        maxLogLineBytes: Int = 4096,
        logTailLines: Int = 40,
    ) {
        self.maxFrameBytes = maxFrameBytes
        self.maxConcurrentCalls = maxConcurrentCalls
        self.helloTimeout = helloTimeout
        self.defaultCallTimeout = defaultCallTimeout
        self.maxCallTimeout = maxCallTimeout
        self.cancelGrace = cancelGrace
        self.maxAttachmentBytes = maxAttachmentBytes
        self.maxAttachmentsPerFrame = maxAttachmentsPerFrame
        self.maxPendingAttachments = maxPendingAttachments
        self.attachmentWait = attachmentWait
        self.maxLogLineBytes = maxLogLineBytes
        self.logTailLines = logTailLines
    }
}
