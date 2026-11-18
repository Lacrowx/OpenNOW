import Foundation
import OpenSSL

/// The RSA key an Android device knows this app by. Approved once on the TV ("Always allow"), it
/// signs the plain-port AUTH token and stands behind the client certificate of TLS connections.
final class TVAdbKey: @unchecked Sendable {
    enum KeyError: Error {
        case generationFailed
        case invalidKey
        case encodingFailed
        case signingFailed
        case certificateFailed
    }

    /// OpenSSL `EVP_PKEY`, owned.
    let key: OpaquePointer

    /// A new 2048-bit key, the size adb itself uses and Android's public-key format assumes.
    init() throws {
        guard let context = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, nil) else { throw KeyError.generationFailed }
        defer { EVP_PKEY_CTX_free(context) }
        var key: OpaquePointer?
        guard EVP_PKEY_keygen_init(context) == 1, EVP_PKEY_CTX_set_rsa_keygen_bits(context, 2048) == 1,
              EVP_PKEY_keygen(context, &key) == 1, let key else { throw KeyError.generationFailed }
        self.key = key
    }

    /// A key stored earlier with `derRepresentation`.
    init(der: Data) throws {
        let parsed: OpaquePointer? = der.withUnsafeBytes { raw in
            var cursor = raw.bindMemory(to: UInt8.self).baseAddress
            return d2i_AutoPrivateKey(nil, &cursor, raw.count)
        }
        guard let parsed else { throw KeyError.invalidKey }
        guard EVP_PKEY_get_bits(parsed) == 2048, EVP_PKEY_get_base_id(parsed) == EVP_PKEY_RSA else {
            EVP_PKEY_free(parsed)
            throw KeyError.invalidKey
        }
        key = parsed
    }

    deinit { EVP_PKEY_free(key) }

    /// The private key in DER, for the keychain.
    func derRepresentation() throws -> Data {
        let length = i2d_PrivateKey(key, nil)
        guard length > 0 else { throw KeyError.encodingFailed }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        let written = bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
            var cursor = buffer.baseAddress
            return i2d_PrivateKey(key, &cursor)
        }
        guard written == length else { throw KeyError.encodingFailed }
        return Data(bytes)
    }

    /// The public key as the AUTH RSAPUBLICKEY payload and `adbkey.pub` carry it: base64 of
    /// Android's mincrypt `RSAPublicKey` struct, a space and a name. The struct is the word count,
    /// -1/n mod 2^32, n, R^2 mod n (R = 2^2048), all little-endian 32-bit words, then the exponent.
    func androidPublicKey(name: String) throws -> String {
        let words = 64
        var modulus: OpaquePointer?, exponent: OpaquePointer?
        guard EVP_PKEY_get_bn_param(key, "n", &modulus) == 1, let modulus,
              EVP_PKEY_get_bn_param(key, "e", &exponent) == 1, let exponent else { throw KeyError.encodingFailed }
        defer { BN_free(modulus); BN_free(exponent) }
        guard let context = BN_CTX_new(), let r32 = BN_new(), let n0inv = BN_new(),
              let r = BN_new(), let rr = BN_new() else { throw KeyError.encodingFailed }
        defer { BN_CTX_free(context); BN_free(r32); BN_free(n0inv); BN_free(r); BN_free(rr) }
        guard BN_set_bit(r32, 32) == 1,
              BN_div(nil, n0inv, modulus, r32, context) == 1, // n mod 2^32
              BN_mod_inverse(n0inv, n0inv, r32, context) != nil,
              BN_sub(n0inv, r32, n0inv) == 1,
              BN_set_bit(r, Int32(words * 32 * 2)) == 1,
              BN_div(nil, rr, r, modulus, context) == 1 else { throw KeyError.encodingFailed }

        var data = Data()
        func append(_ word: UInt32) { withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ number: OpaquePointer) throws {
            var bytes = [UInt8](repeating: 0, count: words * 4)
            guard BN_bn2lebinpad(number, &bytes, Int32(bytes.count)) == Int32(bytes.count) else {
                throw KeyError.encodingFailed
            }
            data.append(contentsOf: bytes)
        }
        append(UInt32(words))
        append(UInt32(BN_get_word(n0inv)))
        try append(modulus)
        try append(rr)
        append(UInt32(BN_get_word(exponent)))
        return data.base64EncodedString() + " " + name
    }

    /// Signs the 20-byte AUTH token the way adb does, `RSA_sign(NID_sha1, token)`: the token is
    /// treated as an already computed SHA-1 digest.
    func signToken(_ token: Data) throws -> Data {
        guard let context = EVP_PKEY_CTX_new(key, nil) else { throw KeyError.signingFailed }
        defer { EVP_PKEY_CTX_free(context) }
        guard EVP_PKEY_sign_init(context) == 1,
              EVP_PKEY_CTX_set_rsa_padding(context, RSA_PKCS1_PADDING) == 1,
              EVP_PKEY_CTX_set_signature_md(context, EVP_sha1()) == 1 else { throw KeyError.signingFailed }
        var length = 0
        let tokenBytes = [UInt8](token)
        guard EVP_PKEY_sign(context, nil, &length, tokenBytes, tokenBytes.count) == 1 else { throw KeyError.signingFailed }
        var signature = [UInt8](repeating: 0, count: length)
        guard EVP_PKEY_sign(context, &signature, &length, tokenBytes, tokenBytes.count) == 1 else {
            throw KeyError.signingFailed
        }
        return Data(signature.prefix(length))
    }

    /// A self-signed certificate for TLS client authentication. The device checks only that the
    /// certificate's public key is one it has approved, so the other fields are nominal.
    /// Returns an owned `X509`.
    func makeCertificate() throws -> OpaquePointer {
        guard let certificate = X509_new() else { throw KeyError.certificateFailed }
        X509_set_version(certificate, 2)
        ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1)
        X509_gmtime_adj(X509_getm_notBefore(certificate), -60 * 60 * 24)
        X509_gmtime_adj(X509_getm_notAfter(certificate), 60 * 60 * 24 * 365 * 10)
        // MBSTRING_ASC; OpenSSL defines it as an expression Swift does not import.
        let asciiStringType: Int32 = 4097
        guard X509_set_pubkey(certificate, key) == 1, let name = X509_get_subject_name(certificate),
              X509_NAME_add_entry_by_txt(name, "CN", asciiStringType, Array("OpenNOW".utf8) + [0], -1, -1, 0) == 1,
              X509_set_issuer_name(certificate, name) == 1,
              X509_sign(certificate, key, EVP_sha256()) > 0 else {
            X509_free(certificate)
            throw KeyError.certificateFailed
        }
        return certificate
    }
}
