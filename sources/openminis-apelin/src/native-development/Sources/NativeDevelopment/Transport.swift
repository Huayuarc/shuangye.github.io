import Foundation
import Darwin

final class FramedSocket {
    private let fd: Int32
    private let closeLock = NSLock()
    private var closed = false
    init(_ fd: Int32) throws {
        self.fd = fd
        var value: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0 else {
            throw NativeError.protocolViolation
        }
        var timeout = timeval(tv_sec: 120, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            throw NativeError.protocolViolation
        }
    }
    deinit { close(); Darwin.close(fd) }
    func close() {
        closeLock.lock(); defer { closeLock.unlock() }
        if !closed { closed = true; shutdown(fd, SHUT_RDWR) }
        // Leave descriptor allocated until deinit: no close/reuse race with blocked I/O.
    }
    func dispose() { close() }
    func requireLive() throws {
        var byte: UInt8 = 0
        let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if result == 0 { throw NativeError.disconnected }
        if result < 0 && errno != EAGAIN && errno != EWOULDBLOCK { throw NativeError.disconnected }
    }
    private func read(_ count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < count {
                let n = recv(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw NativeError.disconnected }
                offset += n
            }
        }
        return result
    }
    func receive<T: Decodable>(_ type: T.Type) throws -> T {
        let prefix = try read(4)
        let count = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0 && count <= 1_048_576 else { throw NativeError.protocolViolation }
        return try JSONDecoder().decode(type, from: read(Int(count)))
    }
    func send<T: Encodable>(_ value: T) throws {
        let body = try canonical(value)
        guard body.count <= 1_048_576 else { throw NativeError.protocolViolation }
        var size = UInt32(body.count).bigEndian
        var data = withUnsafeBytes(of: &size) { Data($0) }
        data.append(body)
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw NativeError.disconnected }
                offset += n
            }
        }
    }
}

final class AuthenticatedChannel {
    let socket: FramedSocket
    private let bootstrap: Bootstrap
    private let outbound: String
    private let inbound: String
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    init(socket: FramedSocket, bootstrap: Bootstrap, host: Bool) {
        self.socket = socket; self.bootstrap = bootstrap
        outbound = host ? "host.v1" : "service.v1"
        inbound = host ? "service.v1" : "host.v1"
    }
    func send<T: Encodable>(_ value: T) throws {
        guard sent < UInt64.max else { throw NativeError.protocolViolation }
        let body = PacketBody(domain: outbound, connection: bootstrap.connection, sequence: sent, payload: try canonical(value))
        try socket.send(Packet(body: body, tag: authenticate(body, key: bootstrap.transportKey)))
        sent += 1
    }
    func receive<T: Decodable>(_ type: T.Type) throws -> T {
        let packet = try socket.receive(Packet.self)
        guard received < UInt64.max, packet.body.domain == inbound,
              packet.body.connection == bootstrap.connection, packet.body.sequence == received,
              try verify(packet.tag, value: packet.body, key: bootstrap.transportKey) else {
            throw NativeError.protocolViolation
        }
        received += 1
        let decoded = try JSONDecoder().decode(type, from: packet.body.payload)
        if let request = decoded as? Request {
            // Codable otherwise silently ignores unknown keys (including model risk flags).
            let actual = try JSONSerialization.jsonObject(with: packet.body.payload) as? NSDictionary
            let allowed = try JSONSerialization.jsonObject(with: canonical(request)) as? NSDictionary
            guard let actual = actual, let allowed = allowed, actual.isEqual(allowed) else {
                throw NativeError.protocolViolation
            }
        }
        return decoded
    }
}
