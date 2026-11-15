import ApelinToolCore

/// Why a call, or `start()`, produced no result.
public struct ToolCallFailure: Error, Hashable, Sendable, CustomStringConvertible {
    public var code: ToolErrorCode
    public var message: String

    public init(_ code: ToolErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String {
        "\(code.rawValue): \(message)"
    }
}

public enum ToolResultItem: Sendable {
    case text(String)
    /// A file the extension sent, already mapped to a descriptor this
    /// process owns.
    case file(ToolReceivedAttachment)
}

public struct ToolCallResult: Sendable {
    public var content: [ToolResultItem]

    /// The text blocks joined, for a caller that wants only those.
    public var text: String {
        content.compactMap {
            if case let .text(text) = $0 {
                text
            } else {
                nil
            }
        }.joined(separator: "\n")
    }
}

/// A call ends in one of these, never by throwing: a crash, a timeout and a
/// bad frame are all failures the agent can be shown.
public enum ToolCallOutcome: Sendable {
    case success(ToolCallResult)
    case failure(ToolCallFailure)

    public var failure: ToolCallFailure? {
        if case let .failure(failure) = self {
            return failure
        }
        return nil
    }

    public var result: ToolCallResult? {
        if case let .success(result) = self {
            return result
        }
        return nil
    }
}

/// What the extension said in `hello`.
public struct ToolExtensionHello: Hashable, Sendable {
    public var protocolVersion: Int
    public var peer: ToolPeer
    public var tools: [String]
    /// The concurrency both sides agreed on.
    public var maxConcurrentCalls: Int
}
