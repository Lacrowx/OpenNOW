import Foundation

/// One Android Debug Bridge packet: a 24-byte little-endian header and an optional payload.
/// Wire format from AOSP `packages/modules/adb/protocol.txt`.
struct TVAdbMessage: Equatable {
    static let headerSize = 24
    /// Protocol version sent in CNXN (with checksums no longer required).
    static let version: UInt32 = 0x0100_0001
    /// Largest payload this client accepts, announced in CNXN.
    static let maxPayload: UInt32 = 256 * 1024
    /// Version sent in STLS, the request to continue the connection over TLS.
    static let tlsVersion: UInt32 = 0x0100_0000

    enum Command: UInt32 {
        case connect = 0x4e58_4e43 // CNXN
        case auth = 0x4854_5541 // AUTH
        case open = 0x4e45_504f // OPEN
        case okay = 0x5941_4b4f // OKAY
        case close = 0x4553_4c43 // CLSE
        case write = 0x4554_5257 // WRTE
        case startTLS = 0x534c_5453 // STLS
    }

    /// arg0 of an AUTH packet.
    enum AuthType: UInt32 {
        case token = 1
        case signature = 2
        case publicKey = 3
    }

    struct Header: Equatable {
        let command: UInt32
        let arg0: UInt32
        let arg1: UInt32
        let length: UInt32
    }

    enum DecodeError: Error, Equatable {
        case badMagic
        case payloadTooLarge(UInt32)
    }

    var command: Command
    var arg0: UInt32
    var arg1: UInt32
    var payload = Data()

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        for word in [command.rawValue, arg0, arg1, UInt32(payload.count),
                     payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }, command.rawValue ^ 0xffff_ffff] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    static func decodeHeader(_ bytes: Data) throws -> Header {
        precondition(bytes.count == headerSize)
        let words = (0..<6).map { index in
            bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)) }
        }
        guard words[5] == words[0] ^ 0xffff_ffff else { throw DecodeError.badMagic }
        guard words[3] <= maxPayload else { throw DecodeError.payloadTooLarge(words[3]) }
        return Header(command: words[0], arg0: words[1], arg1: words[2], length: words[3])
    }

    /// A NUL-terminated string payload, as CNXN and OPEN carry.
    static func cString(_ text: String) -> Data { Data(text.utf8) + [0] }
}
