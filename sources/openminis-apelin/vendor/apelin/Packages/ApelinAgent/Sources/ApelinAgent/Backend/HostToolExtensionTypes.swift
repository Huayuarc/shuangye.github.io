import class ApelinProtocol.OwnedDescriptor
import Foundation
import KWWKAI

// MARK: - agent tool extensions

/// One call of a tool an extension declares, in the tool session the host
/// opened for it (`openToolExtension`).
public struct ToolExtensionCallRequest: Sendable, Hashable {
    public var sessionID: String
    public var tool: String
    public var arguments: JSONValue
    /// The manifest's bound; the host caps it.
    public var timeoutSeconds: Double?

    public init(sessionID: String, tool: String, arguments: JSONValue, timeoutSeconds: Double?) {
        self.sessionID = sessionID
        self.tool = tool
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct ToolExtensionCallResponse: Sendable {
    /// The result's text parts, joined.
    public var text: String
    /// The files the tool returned, in its order.
    public var files: [ToolExtensionFile]
    /// What the extension answered instead of a result.
    public var failure: ToolExtensionFailure?

    public init(text: String, files: [ToolExtensionFile] = [], failure: ToolExtensionFailure? = nil) {
        self.text = text
        self.files = files
        self.failure = failure
    }
}

/// A file a tool returned: a read-only descriptor to the host's copy.
public struct ToolExtensionFile: Sendable {
    /// For the user to see; never opened.
    public var name: String?
    public var mimeType: String?
    public var descriptor: OwnedDescriptor

    public init(name: String?, mimeType: String?, descriptor: OwnedDescriptor) {
        self.name = name
        self.mimeType = mimeType
        self.descriptor = descriptor
    }
}

/// The extension's error answer, or the host's for a call it could not
/// finish: a code of the tool protocol's (`invalidArguments`,
/// `extensionCrashed`, …) and its message.
public struct ToolExtensionFailure: Sendable, Hashable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
