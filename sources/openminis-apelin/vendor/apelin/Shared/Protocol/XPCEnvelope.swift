import ApelinProtocol
import Foundation
import XPC

/// `WireRequest` and `WireReply` as XPC dictionaries:
///
///     request: op (string), protocolVersion (int64), requestID (string),
///              payload (data, JSON), fds (array of fd, optional)
///     reply:   requestID (string), ok (bool), payload (data, JSON) or
///              error (dictionary: code, message, reason optional), fds (array of fd, optional)
///
/// Descriptors are duplicated into the message; the caller keeps and closes
/// its own. Received descriptors come back owned by the receiver.
enum XPCEnvelope {
    static func message(for request: WireRequest, descriptors: [OwnedDescriptor]) -> xpc_object_t {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, Wire.operationKey, request.operation.rawValue)
        xpc_dictionary_set_int64(message, Wire.protocolVersionKey, request.protocolVersion)
        xpc_dictionary_set_string(message, Wire.requestIDKey, request.requestID)
        setData(request.payload, in: message)
        setDescriptors(descriptors, in: message)
        return message
    }

    /// Reads a request. The operation is checked against the closed list and
    /// the version against ours before anything else is read.
    static func request(from message: xpc_object_t) -> Result<(WireRequest, [OwnedDescriptor]), ApelinError> {
        guard xpc_get_type(message) == AppXPC.typeDictionary else {
            return .failure(ApelinError(.badRequest, "not a dictionary"))
        }
        let version = xpc_dictionary_get_int64(message, Wire.protocolVersionKey)
        guard version == Wire.protocolVersion else {
            NSLog("apelind: refused protocol version %lld; this build speaks %lld", version, Wire.protocolVersion)
            return .failure(ApelinError(.unsupportedVersion, ""))
        }
        guard let name = string(Wire.operationKey, in: message) else {
            return .failure(ApelinError(.badRequest, "no operation"))
        }
        guard let operation = AppOperation(rawValue: name) else {
            NSLog("apelind: refused unknown operation %@", name)
            return .failure(ApelinError(.unknownOperation, ""))
        }
        let request = WireRequest(
            operation: operation,
            protocolVersion: version,
            requestID: string(Wire.requestIDKey, in: message) ?? "",
            payload: data(in: message),
        )
        return .success((request, descriptors(in: message)))
    }

    /// Fills the dictionary `xpc_dictionary_create_reply` made.
    static func fill(_ reply: xpc_object_t, with wireReply: WireReply, descriptors: [OwnedDescriptor]) {
        xpc_dictionary_set_string(reply, Wire.requestIDKey, wireReply.requestID)
        switch wireReply.result {
        case let .success(payload):
            xpc_dictionary_set_bool(reply, Wire.okKey, true)
            setData(payload, in: reply)
            setDescriptors(descriptors, in: reply)
        case let .failure(error):
            xpc_dictionary_set_bool(reply, Wire.okKey, false)
            let detail = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(detail, Wire.errorCodeKey, error.code.rawValue)
            xpc_dictionary_set_string(detail, Wire.errorMessageKey, error.message)
            if let reason = error.reason {
                xpc_dictionary_set_string(detail, Wire.errorReasonKey, reason.rawValue)
            }
            xpc_dictionary_set_value(reply, Wire.errorKey, detail)
        }
    }

    static func reply(from message: xpc_object_t, requestID: String) -> (WireReply, [OwnedDescriptor]) {
        guard xpc_get_type(message) == AppXPC.typeDictionary else {
            return (
                .failure(
                    requestID,
                    ApelinError(
                        .unavailable,
                        String(localized: "The connection to Apelin’s background service closed. Try again."),
                    ),
                ),
                [],
            )
        }
        if xpc_dictionary_get_bool(message, Wire.okKey) {
            return (WireReply(requestID: requestID, result: .success(data(in: message))), descriptors(in: message))
        }
        guard let detail = xpc_dictionary_get_value(message, Wire.errorKey), xpc_get_type(detail) == AppXPC.typeDictionary else {
            return (
                .failure(
                    requestID,
                    ApelinError(
                        .internal,
                        String(localized: "Apelin’s background service returned an incomplete response. Try again."),
                    ),
                ),
                [],
            )
        }
        let code = string(Wire.errorCodeKey, in: detail).flatMap(ApelinError.Code.init(rawValue:)) ?? .internal
        let message = string(Wire.errorMessageKey, in: detail) ?? ""
        let reason = string(Wire.errorReasonKey, in: detail).map(ApelinError.Reason.init(rawValue:))
        return (.failure(requestID, ApelinError(code, message, reason: reason)), [])
    }

    private static func string(_ key: String, in dictionary: xpc_object_t) -> String? {
        xpc_dictionary_get_string(dictionary, key).map { String(cString: $0) }
    }

    private static func setData(_ data: Data, in dictionary: xpc_object_t) {
        data.withUnsafeBytes { bytes in
            xpc_dictionary_set_data(
                dictionary,
                Wire.payloadKey,
                bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!,
                bytes.count,
            )
        }
    }

    /// The payload, or an empty JSON object when the message carries none.
    private static func data(in dictionary: xpc_object_t) -> Data {
        var length = 0
        guard let bytes = xpc_dictionary_get_data(dictionary, Wire.payloadKey, &length) else { return Data("{}".utf8) }
        return Data(bytes: bytes, count: length)
    }

    /// All or none, both ways: a `DescriptorSlot` is an index, so a descriptor
    /// left out would hand every later slot its neighbour's file.
    private static func setDescriptors(_ descriptors: [OwnedDescriptor], in dictionary: xpc_object_t) {
        guard !descriptors.isEmpty else { return }
        let array = xpc_array_create(nil, 0)
        for descriptor in descriptors {
            guard let object = xpc_fd_create(descriptor.rawValue) else { return }
            xpc_array_append_value(array, object)
        }
        xpc_dictionary_set_value(dictionary, Wire.descriptorsKey, array)
    }

    private static func descriptors(in dictionary: xpc_object_t) -> [OwnedDescriptor] {
        guard let array = xpc_dictionary_get_value(dictionary, Wire.descriptorsKey), xpc_get_type(array) == AppXPC.typeArray else {
            return []
        }
        var result: [OwnedDescriptor] = []
        for index in 0 ..< xpc_array_get_count(array) {
            let object = xpc_array_get_value(array, index)
            guard xpc_get_type(object) == AppXPC.typeFD else { return [] }
            let descriptor = xpc_fd_dup(object)
            guard descriptor >= 0 else { return [] }
            result.append(OwnedDescriptor(adopting: descriptor))
        }
        return result
    }
}
