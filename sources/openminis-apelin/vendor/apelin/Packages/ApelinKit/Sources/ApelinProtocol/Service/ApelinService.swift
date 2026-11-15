import ApelinCore
import Foundation

/// Carries one request and its reply. The app's is `DaemonClient` (XPC to
/// apelind); a worker's is `ChannelTransport` (its socketpair to the session
/// host). Descriptors go out beside the request and come back beside the
/// reply, in the order their `DescriptorSlot`s name.
public protocol ApelinTransport: Sendable {
    func call(_ request: WireRequest, descriptors: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor])
}

/// Everything Apelin can do, one typed async method per `AppOperation`.
/// The console, the agent's tools and the UI all call this and nothing
/// lower; the methods themselves live beside their types in
/// `Operations/<Domain>.swift`.
public struct ApelinService: Sendable {
    public let transport: any ApelinTransport

    public init(transport: any ApelinTransport) {
        self.transport = transport
    }

    /// Sends a request and decodes its reply. Throws `ApelinError`.
    public func send<R: OperationRequest>(
        _ request: R,
        descriptors: [OwnedDescriptor] = [],
    ) async throws -> R.Response {
        try await sendReturningDescriptors(request, descriptors: descriptors).0
    }

    /// Sends a request; the reply's descriptors come back owned by the caller.
    public func sendReturningDescriptors<R: OperationRequest>(
        _ request: R,
        descriptors: [OwnedDescriptor] = [],
    ) async throws -> (R.Response, [OwnedDescriptor]) {
        let wire = try WireRequest(request)
        let (reply, returned) = try await transport.call(wire, descriptors: descriptors)
        switch reply.result {
        case let .failure(error):
            throw error
        case let .success(payload):
            do {
                return try (JSONCoding.decode(R.Response.self, from: payload), returned)
            } catch {
                throw ApelinError(.internal, "\(R.operation.rawValue) reply does not decode: \(error)")
            }
        }
    }

    /// Sends a request whose type is only known at run time (the console):
    /// JSON in, JSON out.
    public func sendUntyped(
        _ operation: AppOperation,
        request: JSONValue,
        descriptors: [OwnedDescriptor] = [],
    ) async throws -> (JSONValue, [OwnedDescriptor]) {
        try await sendUntyped(operation.requestType, request: request, descriptors: descriptors)
    }

    private func sendUntyped<R: OperationRequest>(
        _: R.Type,
        request: JSONValue,
        descriptors: [OwnedDescriptor],
    ) async throws -> (JSONValue, [OwnedDescriptor]) {
        let typed: R
        do {
            typed = try request.decode(R.self)
        } catch {
            throw ApelinError(.badRequest, "\(R.operation.rawValue) request: \(error)")
        }
        let (response, returned) = try await sendReturningDescriptors(typed, descriptors: descriptors)
        return try (JSONValue(encoding: response), returned)
    }

    /// One attach: the events after `afterSeq`, waiting up to the request's
    /// bound for the first one.
    public func attach(
        _ handle: TaskHandle,
        afterSeq: EventSeq,
        waitMilliseconds: Int = 20000,
    ) async throws -> TaskEventBatch {
        guard let type = handle.attachOperation.requestType as? any TaskAttachRequest.Type else {
            throw ApelinError(.badRequest, "\(handle.attachOperation.rawValue) is not an attach")
        }
        return try await attach(type, taskID: handle.taskID, afterSeq: afterSeq, waitMilliseconds: waitMilliseconds)
    }

    private func attach<R: TaskAttachRequest>(
        _: R.Type,
        taskID: TaskID,
        afterSeq: EventSeq,
        waitMilliseconds: Int,
    ) async throws -> TaskEventBatch {
        try await send(R(taskID: taskID, afterSeq: afterSeq, waitMilliseconds: waitMilliseconds))
    }

    /// Every event of a task after `afterSeq`, in order, attaching again and
    /// again until it finishes. Reattaching after a dropped connection is the
    /// same call with the last `seq` seen: nothing is lost or repeated.
    public func events(of handle: TaskHandle, afterSeq: EventSeq = .start) -> AsyncThrowingStream<TaskEvent, Error> {
        AsyncThrowingStream { continuation in
            let poller = Task {
                var cursor = afterSeq
                do {
                    while !Task.isCancelled {
                        let batch = try await attach(handle, afterSeq: cursor)
                        for event in batch.events where event.seq > cursor {
                            continuation.yield(event)
                            cursor = event.seq
                        }
                        if batch.finished {
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in poller.cancel() }
        }
    }
}
