import Foundation

/// Decides whether to answer a fingerprint event and builds the encrypted password reply.
public final class TouchResponder {
    public enum Outcome: Equatable {
        case replied(slot: Int, line: String)
        case ignored(String)
    }

    private var seenNonces: [String] = []
    private let maxNonces = 256

    public init() {}

    /// - Parameters:
    ///   - pairingKey: this Mac's key, or nil if not paired.
    ///   - password: looks up the password for a finger slot (falls back to the default inside).
    ///   - allow: context gate (lock screen / password field / sudo); returns a refusal reason or nil.
    public func handle(line: String, pairingKey: Data?, password: (Int) -> Data?, allow: () -> String?) -> Outcome {
        guard let pairingKey else { return .ignored("Mac này chưa ghép đôi với thiết bị") }
        guard let event = PairingCrypto.parseEvent(line, pairingKey: pairingKey) else {
            return .ignored("sự kiện không dành cho Mac này hoặc chữ ký không hợp lệ")
        }
        let nonce = event.nonce.lowercased()
        guard !seenNonces.contains(nonce) else { return .ignored("sự kiện lặp lại (replay)") }
        if let reason = allow() { return .ignored(reason) }
        guard let secret = password(event.slot), !secret.isEmpty else {
            return .ignored("chưa lưu mật khẩu Mac cho ngón \(event.slot)")
        }
        do {
            let reply = try PairingCrypto.reply(to: event, password: secret, pairingKey: pairingKey)
            seenNonces.append(nonce)
            if seenNonces.count > maxNonces { seenNonces.removeFirst(seenNonces.count - maxNonces) }
            return .replied(slot: event.slot, line: reply)
        } catch {
            return .ignored(error.localizedDescription)
        }
    }
}
