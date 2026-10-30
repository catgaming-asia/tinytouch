import Foundation

/// Anything that can run a console command: the serial client or the app's control socket.
public protocol CommandChannel: AnyObject {
    func send(_ command: String, timeout: TimeInterval, onLine: ((String) -> Void)?) async throws -> [String]
}

extension DeviceClient: CommandChannel {}

public struct DeviceSnapshot: Equatable {
    public var status: DeviceStatus
    public var slots: [SlotInfo]
    public var passkeys: [Passkey]?
    public var passkeysLocked: Bool
}

/// High-level operations shared by the app and the CLI. Mirrors the vendor web controller:
/// every configuration change is wrapped in CONFIG_UNLOCK (fingerprint) … CONFIG_LOCK.
public final class DeviceService {
    public let channel: CommandChannel

    public init(channel: CommandChannel) {
        self.channel = channel
    }

    @discardableResult
    public func run(_ command: String, timeout: TimeInterval = 5, onLine: ((String) -> Void)? = nil) async throws -> [String] {
        try await channel.send(command, timeout: timeout, onLine: onLine)
    }

    public func status() async throws -> DeviceStatus {
        let lines = try await run("STATUS", timeout: 4)
        guard let line = lines.first(prefix: "OK STATUS ") else {
            throw DeviceClientError.rejected(lines.summary)
        }
        return DeviceStatus(line: line)
    }

    public func snapshot() async throws -> DeviceSnapshot {
        let status = try await status()
        var slots = SlotInfo.parse("", fingerprints: status.fingerprints)
        if let lines = try? await run("GET_SLOT_STATUS", timeout: 3), let line = lines.first(prefix: "OK SLOT_STATUS") {
            slots = SlotInfo.parse(line, fingerprints: status.fingerprints)
        }
        var passkeys: [Passkey]?
        var locked = false
        if let lines = try? await run("PASSKEY_LIST", timeout: 3) {
            if let json = lines.first(where: { $0.hasPrefix("{") }) {
                passkeys = Passkey.parseList(json)
            } else if lines.contains(where: { $0.contains("CONFIG_LOCKED") }) {
                locked = true
            }
        }
        return DeviceSnapshot(status: status, slots: slots, passkeys: passkeys, passkeysLocked: locked)
    }

    /// Asks for an owner fingerprint, runs `body`, then always re-locks the console.
    public func withConfigUnlock<T>(fingerprints: Int, onPrompt: ((String) -> Void)? = nil,
                                    _ body: () async throws -> T) async throws -> T {
        let lines = try await run("CONFIG_UNLOCK", timeout: fingerprints > 0 ? 20 : 4, onLine: onPrompt)
        guard lines.contains(where: { $0.hasPrefix("OK CONFIG_UNLOCK") }) else {
            throw DeviceClientError.rejected(lines.contains(where: { $0.hasPrefix("ERR") })
                ? "vân tay không khớp hoặc không chạm kịp (\(lines.summary))"
                : "không nhận được xác nhận vân tay")
        }
        do {
            let result = try await body()
            _ = try? await run("CONFIG_LOCK", timeout: 2)
            return result
        } catch {
            _ = try? await run("CONFIG_LOCK", timeout: 2)
            throw error
        }
    }

    /// Runs one configuration command under fingerprint authorisation and checks its reply.
    @discardableResult
    public func configure(_ command: String, fingerprints: Int, timeout: TimeInterval = 5,
                          onPrompt: ((String) -> Void)? = nil) async throws -> [String] {
        try await withConfigUnlock(fingerprints: fingerprints, onPrompt: onPrompt) {
            let lines = try await run(command, timeout: timeout, onLine: onPrompt)
            guard lines.isOK else { throw DeviceClientError.rejected(lines.summary) }
            return lines
        }
    }

    public func setMode(_ mode: DeviceMode, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        try await configure("MODE \(mode.rawValue)", fingerprints: fingerprints, onPrompt: onPrompt)
    }

    public func enroll(slot: Int, touches: Int, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        let command = "ENROLL \(slot) \(touches)"
        let timeout: TimeInterval = touches >= 6 ? 90 : 45
        // With no enrolled finger yet, CONFIG_UNLOCK succeeds immediately (first setup).
        try await configure(command, fingerprints: fingerprints, timeout: timeout, onPrompt: onPrompt)
    }

    public func setChipPassword(slot: Int, password: String, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        guard !password.isEmpty, !password.contains("\n"), !password.contains("\r") else {
            throw DeviceClientError.rejected("mật khẩu không hợp lệ")
        }
        try await configure("SET_SLOT_PASSWORD \(slot) \(password)", fingerprints: fingerprints, onPrompt: onPrompt)
    }

    public func clearChipPassword(slot: Int, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        try await configure("CLEAR_SLOT_PASSWORD \(slot)", fingerprints: fingerprints, onPrompt: onPrompt)
    }

    public func setPostKey(_ sequence: String, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        guard let normalized = PostKey.normalize(sequence) else {
            throw DeviceClientError.rejected("chuỗi phím không hợp lệ: \(sequence)")
        }
        try await configure("POST_KEY \(normalized)", fingerprints: fingerprints, timeout: 3, onPrompt: onPrompt)
    }

    public func setPostKeyDelay(_ ms: Int, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        try await configure("POST_KEY_DELAY \(ms)", fingerprints: fingerprints, timeout: 3, onPrompt: onPrompt)
    }

    public func setWakeDelay(_ ms: Int, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        try await configure("WAKE_DELAY \(ms)", fingerprints: fingerprints, timeout: 3, onPrompt: onPrompt)
    }

    public func unlockedPasskeys(fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws -> [Passkey] {
        try await withConfigUnlock(fingerprints: fingerprints, onPrompt: onPrompt) {
            let lines = try await run("PASSKEY_LIST", timeout: 3)
            guard let json = lines.first(where: { $0.hasPrefix("{") }), let list = Passkey.parseList(json) else {
                throw DeviceClientError.rejected(lines.summary)
            }
            return list
        }
    }

    public func deletePasskey(id: String, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        try await configure("PASSKEY_DELETE \(id)", fingerprints: fingerprints, onPrompt: onPrompt)
    }

    public func clearPasskeys(fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        try await configure("PASSKEY_CLEAR", fingerprints: fingerprints, onPrompt: onPrompt)
    }

    public func factoryReset(fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        try await configure("FACTORY_RESET", fingerprints: fingerprints, timeout: 10, onPrompt: onPrompt)
    }

    /// Host key ids paired with the device, or nil if the firmware has no HID_KEY_IDS.
    public func pairedHostIDs() async throws -> [String]? {
        let lines = try await run("HID_KEY_IDS", timeout: 3)
        guard let line = lines.first(prefix: "OK HID_KEY_IDS") else { return nil }
        let ids = DeviceStatus(line: line).fields["ids"] ?? "none"
        return ids == "none" ? [] : ids.split(separator: ",").map(String.init)
    }

    /// Registers a new random pairing key on the device and returns it.
    public func pairNewHost(fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws -> Data {
        let key = PairingCrypto.newPairingKey()
        try await configure("HID_KEY_ADD \(PairingCrypto.keyID(key)) \(key.hex)", fingerprints: fingerprints, onPrompt: onPrompt)
        return key
    }

    public func removeHost(id: String, fingerprints: Int, onPrompt: ((String) -> Void)? = nil) async throws {
        try await configure("HID_KEY_REMOVE \(id)", fingerprints: fingerprints, onPrompt: onPrompt)
    }
}
