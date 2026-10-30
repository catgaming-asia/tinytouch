import CommonCrypto
import CryptoKit
import Foundation

/// Host side of the authenticated touch protocol (firmware protocol 2).
///
/// On a fingerprint match the device sends
/// `EV2 <nonce> <counter> <slot> <score> <keyId>:<mac> …` with one MAC per paired host,
/// where `mac = HMAC(pairingKey, "EV2|keyId|nonce|counter|slot|score")`.
/// The host answers `PW2 <keyId> <nonce> <iv> <ciphertext> <mac>`: the password
/// encrypted with AES-256-CTR under `HMAC(pairingKey, "SESSION|nonce")`, and
/// `mac = HMAC(pairingKey, "PW2|keyId|nonce|iv|ciphertext")`. The device then types it.
/// The single-key `EV`/`PW` variant is also accepted.
public enum PairingCrypto {
    public static let maxPasswordBytes = 160

    public struct TouchEvent: Equatable {
        public let version: Int
        public let nonce: String
        public let counter: UInt64
        public let slot: Int
        public let score: Int
        public let keyID: String?
    }

    public static func newPairingKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes)
    }

    /// First 8 bytes of SHA-256(key), hex-encoded; matches the firmware's host id.
    public static func keyID(_ key: Data) -> String {
        Data(SHA256.hash(data: key)).prefix(8).hex
    }

    public static func hmacHex(_ key: Data, _ message: String) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))).hex
    }

    public static func parseEvent(_ line: String, pairingKey: Data) -> TouchEvent? {
        let parts = line.split(separator: " ").map(String.init)
        guard let kind = parts.first, kind == "EV" || kind == "EV2" else { return nil }
        let version = kind == "EV" ? 1 : 2
        guard version == 1 ? parts.count == 6 : (6...13).contains(parts.count) else { return nil }
        let nonce = parts[1].lowercased()
        guard nonce.count == 32, Data(hex: nonce) != nil,
              let counter = UInt64(parts[2]), let slot = Int(parts[3]), let score = Int(parts[4]),
              (1...40).contains(slot) else { return nil }

        let material: String
        let received: String
        var keyID: String?
        if version == 1 {
            received = parts[5].lowercased()
            material = "EV|\(parts[1])|\(parts[2])|\(parts[3])|\(parts[4])"
        } else {
            let id = Self.keyID(pairingKey)
            keyID = id
            guard let match = parts[5...].first(where: { $0.lowercased().hasPrefix(id + ":") }) else { return nil }
            received = String(match.dropFirst(id.count + 1)).lowercased()
            material = "EV2|\(id)|\(parts[1])|\(parts[2])|\(parts[3])|\(parts[4])"
        }
        guard received.count == 64, constantTimeEqual(received, hmacHex(pairingKey, material)) else { return nil }
        return TouchEvent(version: version, nonce: parts[1], counter: counter, slot: slot, score: score, keyID: keyID)
    }

    /// Builds the encrypted reply line (without trailing newline).
    public static func reply(to event: TouchEvent, password: Data, pairingKey: Data, iv: Data? = nil) throws -> String {
        guard !password.isEmpty, password.count <= maxPasswordBytes else {
            throw CryptoError.passwordLength
        }
        let iv = iv ?? newIV()
        let sessionKey = Data(HMAC<SHA256>.authenticationCode(for: Data("SESSION|\(event.nonce)".utf8),
                                                              using: SymmetricKey(data: pairingKey)))
        let ciphertext = try aesCTR(key: sessionKey, iv: iv, data: password)
        if let keyID = event.keyID {
            let body = "\(keyID) \(event.nonce) \(iv.hex) \(ciphertext.hex)"
            let mac = hmacHex(pairingKey, "PW2|\(keyID)|\(event.nonce)|\(iv.hex)|\(ciphertext.hex)")
            return "PW2 \(body) \(mac)"
        }
        let mac = hmacHex(pairingKey, "PW|\(event.nonce)|\(iv.hex)|\(ciphertext.hex)")
        return "PW \(event.nonce) \(iv.hex) \(ciphertext.hex) \(mac)"
    }

    public enum CryptoError: LocalizedError {
        case passwordLength
        case cipher(Int32)
        public var errorDescription: String? {
            switch self {
            case .passwordLength: return "Mật khẩu phải dài 1–\(PairingCrypto.maxPasswordBytes) byte."
            case let .cipher(status): return "Lỗi mã hóa AES (\(status))."
            }
        }
    }

    static func newIV() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    static func aesCTR(key: Data, iv: Data, data: Data) throws -> Data {
        var cryptor: CCCryptorRef?
        var status = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), ivPtr.baseAddress, keyPtr.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { throw CryptoError.cipher(status) }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: data.count)
        var moved = 0
        status = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, data.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == data.count else { throw CryptoError.cipher(status) }
        return output
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
