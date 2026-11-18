import Darwin
import Foundation
import OpenSSL

/// A blocking Android Debug Bridge client connection, enough to run one-shot commands.
///
/// Android 11+ wireless debugging answers CNXN with STLS and continues over TLS 1.3, where the
/// client certificate's key must be one the device has approved. The classic TCP port (5555,
/// opened with `adb tcpip`) uses the AUTH exchange instead, and is where a new key gets approved:
/// the device shows "Allow debugging?" for an unknown key. Every call blocks, so use it off the
/// main thread; socket timeouts bound each step.
final class TVAdbConnection: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case unreachable(String)
        case timedOut
        case closedByDevice
        case notApproved
        case tls(String)
        case unexpected(String)
    }

    enum Authorization {
        /// Fail with `notApproved` when the device does not know the key.
        case knownKeyOnly
        /// Send the public key so the device asks its user, then wait this long for the answer.
        case requestApproval(wait: TimeInterval)
    }

    private let socket: Int32
    private var context: OpaquePointer?
    private var tls: OpaquePointer?
    private var nextLocalID: UInt32 = 1
    private let timeout: TimeInterval

    private init(socket: Int32, timeout: TimeInterval) {
        self.socket = socket
        self.timeout = timeout
    }

    deinit {
        if let tls { SSL_free(tls) }
        if let context { SSL_CTX_free(context) }
        Darwin.close(socket)
    }

    /// Connects and completes the handshake; on return, commands can run.
    static func open(host: String, port: UInt16, key: TVAdbKey, authorization: Authorization,
                     timeout: TimeInterval = 4) throws -> TVAdbConnection {
        let connection = TVAdbConnection(socket: try connectSocket(host: host, port: port, timeout: timeout),
                                         timeout: timeout)
        try connection.handshake(key: key, authorization: authorization)
        return connection
    }

    /// Runs `command` on the device (`exec:`, no terminal) and returns everything it printed.
    func run(_ command: String) throws -> String {
        let localID = nextLocalID
        nextLocalID += 1
        try send(TVAdbMessage(command: .open, arg0: localID, arg1: 0, payload: TVAdbMessage.cString("exec:" + command)))
        var remoteID: UInt32?
        var output = Data()
        while true {
            let message = try receive()
            guard message.arg1 == localID else { continue }
            switch message.command {
            case .okay:
                remoteID = message.arg0
            case .write:
                output.append(message.payload)
                try send(TVAdbMessage(command: .okay, arg0: localID, arg1: message.arg0))
            case .close:
                if remoteID != nil { try? send(TVAdbMessage(command: .close, arg0: localID, arg1: message.arg0)) }
                return String(decoding: output, as: UTF8.self)
            default:
                throw Failure.unexpected("command answered with \(message.command)")
            }
        }
    }

    // MARK: - Handshake

    private func handshake(key: TVAdbKey, authorization: Authorization) throws {
        try send(TVAdbMessage(command: .connect, arg0: TVAdbMessage.version, arg1: TVAdbMessage.maxPayload,
                              payload: TVAdbMessage.cString("host::")))
        var signed = false
        while true {
            let message = try receive()
            switch (message.command, message.arg0) {
            case (.connect, _):
                return
            case (.startTLS, _):
                try send(TVAdbMessage(command: .startTLS, arg0: TVAdbMessage.tlsVersion, arg1: 0))
                try startTLS(key: key)
                // TLS 1.3 checks the client certificate after the client's side of the handshake is
                // done: an unknown key shows up as the device hanging up before its CNXN.
                do {
                    let answer = try receive()
                    guard answer.command == .connect else {
                        throw Failure.unexpected("TLS handshake answered with \(answer.command)")
                    }
                    return
                } catch Failure.closedByDevice {
                    throw Failure.notApproved
                }
            case (.auth, TVAdbMessage.AuthType.token.rawValue) where !signed:
                signed = true
                try send(TVAdbMessage(command: .auth, arg0: TVAdbMessage.AuthType.signature.rawValue, arg1: 0,
                                      payload: try key.signToken(message.payload)))
            case (.auth, TVAdbMessage.AuthType.token.rawValue):
                guard case .requestApproval(let wait) = authorization else { throw Failure.notApproved }
                let publicKey = try key.androidPublicKey(name: "OpenNOW@AppleTV")
                try send(TVAdbMessage(command: .auth, arg0: TVAdbMessage.AuthType.publicKey.rawValue, arg1: 0,
                                      payload: TVAdbMessage.cString(publicKey)))
                setReceiveTimeout(wait)
                defer { setReceiveTimeout(timeout) }
                let answer = try receive()
                guard answer.command == .connect else { throw Failure.notApproved }
                return
            default:
                throw Failure.unexpected("handshake answered with \(message.command)")
            }
        }
    }

    private func startTLS(key: TVAdbKey) throws {
        guard let context = SSL_CTX_new(TLS_client_method()) else { throw Failure.tls("no context") }
        self.context = context
        let certificate = try key.makeCertificate()
        defer { X509_free(certificate) }
        // SSL_CTX_set_min_proto_version is a macro over SSL_CTX_ctrl, which Swift does not import.
        guard SSL_CTX_ctrl(context, SSL_CTRL_SET_MIN_PROTO_VERSION, Int(TLS1_3_VERSION), nil) == 1,
              SSL_CTX_use_certificate(context, certificate) == 1,
              SSL_CTX_use_PrivateKey(context, key.key) == 1 else { throw Failure.tls("context setup") }
        // The device presents a self-signed certificate; trust rests on the key it has approved.
        SSL_CTX_set_verify(context, SSL_VERIFY_NONE, nil)
        guard let tls = SSL_new(context) else { throw Failure.tls("no session") }
        self.tls = tls
        guard SSL_set_fd(tls, socket) == 1 else { throw Failure.tls("socket") }
        let result = SSL_connect(tls)
        guard result == 1 else {
            let reason = ERR_reason_error_string(ERR_get_error()).map { String(cString: $0) }
            ERR_clear_error()
            // An unapproved key fails here: adbd rejects the client certificate.
            throw Failure.tls(reason ?? "handshake error \(SSL_get_error(tls, result))")
        }
    }

    // MARK: - Messages

    private func send(_ message: TVAdbMessage) throws {
        let data = message.encoded()
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let pointer = raw.baseAddress! + offset
                let sent: Int
                if let tls {
                    sent = Int(SSL_write(tls, pointer, Int32(raw.count - offset)))
                } else {
                    sent = Darwin.send(socket, pointer, raw.count - offset, 0)
                }
                guard sent > 0 else { throw readOrWriteFailure() }
                offset += sent
            }
        }
    }

    private func receive() throws -> TVAdbMessage {
        let header = try TVAdbMessage.decodeHeader(try read(TVAdbMessage.headerSize))
        let payload = header.length > 0 ? try read(Int(header.length)) : Data()
        guard let command = TVAdbMessage.Command(rawValue: header.command) else {
            throw Failure.unexpected(String(format: "unknown command %08x", header.command))
        }
        return TVAdbMessage(command: command, arg0: header.arg0, arg1: header.arg1, payload: payload)
    }

    private func read(_ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let received = buffer.withUnsafeMutableBytes { raw -> Int in
                let pointer = raw.baseAddress! + offset
                if let tls { return Int(SSL_read(tls, pointer, Int32(count - offset))) }
                return Darwin.recv(socket, pointer, count - offset, 0)
            }
            if received == 0 { throw Failure.closedByDevice }
            guard received > 0 else { throw readOrWriteFailure() }
            offset += received
        }
        return Data(buffer)
    }

    private func readOrWriteFailure() -> Failure {
        let code = errno
        ERR_clear_error()
        if code == EAGAIN || code == EWOULDBLOCK { return .timedOut }
        return .closedByDevice
    }

    private func setReceiveTimeout(_ seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    // MARK: - Socket

    private static func connectSocket(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(ai_flags: AI_NUMERICSERV, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else {
            throw Failure.unreachable("cannot resolve \(host)")
        }
        defer { freeaddrinfo(list) }
        var lastError = "no address"
        var entries: [addrinfo] = []
        var entry: UnsafeMutablePointer<addrinfo>? = list
        while let info = entry?.pointee {
            entries.append(info)
            entry = info.ai_next
        }
        // A `.local` name also resolves to IPv6 link-local addresses, which may not answer; try IPv4 first.
        for info in entries.filter({ $0.ai_family == AF_INET }) + entries.filter({ $0.ai_family != AF_INET }) {
            let fd = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var connected = Darwin.connect(fd, info.ai_addr, info.ai_addrlen) == 0
            if !connected, errno == EINPROGRESS {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&poller, 1, Int32(timeout * 1000)) == 1 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    connected = error == 0
                    if error != 0 { lastError = String(cString: strerror(error)) }
                } else {
                    lastError = "timed out"
                }
            } else if !connected {
                lastError = String(cString: strerror(errno))
            }
            guard connected else { Darwin.close(fd); continue }
            _ = fcntl(fd, F_SETFL, flags)
            var value = timeval(tv_sec: Int(timeout), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        throw Failure.unreachable("\(host):\(port): \(lastError)")
    }
}
