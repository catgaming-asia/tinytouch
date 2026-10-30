import Foundation

public enum DeviceMode: String, CaseIterable, Identifiable {
    case hid, piv
    public var id: String { rawValue }
    public var title: String { self == .hid ? "HID (bàn phím tự gõ)" : "PIV (SmartCard)" }
}

public struct DeviceStatus: Equatable {
    public var fields: [String: String]

    /// MrOld units report USB serial `TT-<chip MAC>`; the firmware manifest is keyed by that MAC.
    public static func chipMAC(fromSerial serial: String?) -> String? {
        guard let serial, serial.hasPrefix("TT-") else { return nil }
        let mac = serial.dropFirst(3).uppercased()
        return mac.allSatisfy(\.isHexDigit) && !mac.isEmpty ? mac : nil
    }

    public init(line: String) {
        var fields: [String: String] = [:]
        for token in line.split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
        }
        self.fields = fields
    }

    public var mode: DeviceMode? { fields["mode"].flatMap(DeviceMode.init(rawValue:)) }
    public var postKey: String { (fields["post_key"] ?? "enter").lowercased() }
    public var postKeyDelay: Int { Int(fields["post_key_delay"] ?? "") ?? 100 }
    public var wakeDelay: Int { Int(fields["wake_delay"] ?? "") ?? 1000 }
    public var fingerprints: Int { Int(fields["fingerprints"] ?? fields["count"] ?? "") ?? 0 }
    public var sensor: String { fields["sensor"] ?? "unknown" }
    public var firmware: String { fields["firmware"] ?? "?" }
    public var firmwareVersion: String { fields["firmware_version"] ?? fields["version"] ?? "?" }
    public var protocolVersion: Int { Int(fields["protocol"] ?? "") ?? 0 }
    public var hidKeyConfigured: Bool { fields["hid_key"] == "configured" }
    public var hidHosts: Int { Int(fields["hid_hosts"] ?? "") ?? 0 }
}

public struct SlotInfo: Equatable, Identifiable {
    public let id: Int
    public var enrolled = false
    public var hasChipPassword = false

    public init(id: Int, enrolled: Bool = false, hasChipPassword: Bool = false) {
        self.id = id
        self.enrolled = enrolled
        self.hasChipPassword = hasChipPassword
    }

    public static let names = [1: "Ngón trỏ", 2: "Ngón giữa", 3: "Ngón áp út", 4: "Ngón cái", 5: "Ngón út"]
    public var name: String { Self.names[id] ?? "Ngón \(id)" }

    public static func parse(_ line: String, fingerprints: Int) -> [SlotInfo] {
        var slots = (1...5).map { SlotInfo(id: $0) }
        var sawEnrollment = false
        for token in line.split(separator: " ") {
            let pair = token.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].count == 2, let slot = Int(pair[0].dropFirst()), (1...5).contains(slot) else { continue }
            let on = pair[1] == "1"
            switch pair[0].first {
            case "p": slots[slot - 1].hasChipPassword = on
            case "e": slots[slot - 1].enrolled = on; sawEnrollment = true
            default: break
            }
        }
        if !sawEnrollment {
            for index in 0..<min(fingerprints, 5) { slots[index].enrolled = true }
        }
        return slots
    }
}

public struct Passkey: Decodable, Identifiable, Equatable {
    public let id: String
    public let rpId: String?
    public let user: String?
    public let counter: Int?

    public static func parseList(_ line: String) -> [Passkey]? {
        struct Wrapper: Decodable { let passkeys: [Passkey] }
        return (try? JSONDecoder().decode(Wrapper.self, from: Data(line.utf8)))?.passkeys
    }
}

public enum PostKey {
    public static let keys: [(value: String, title: String)] = [
        ("enter", "⏎ Enter"), ("space", "␣ Space"), ("tab", "⇥ Tab"),
        ("esc", "⎋ Esc"), ("down", "↓ Xuống"), ("up", "↑ Lên"), ("none", "⊘ Không"),
    ]

    public static let presets: [(value: String, title: String, detail: String)] = [
        ("enter", "Enter", "Nhấn Enter để đăng nhập/mở khóa ngay."),
        ("enter,space", "Enter → Space", "Nhấn Enter rồi Space."),
        ("tab,enter", "Tab → Enter", "Chuyển ô (2FA/OTP) rồi Enter."),
        ("enter,enter", "Enter ×2", "Cho form cần xác nhận hai lần."),
        ("none", "Không bấm", "Chỉ điền mật khẩu, tự bạn bấm đăng nhập."),
    ]

    /// Normalises user input such as "Enter, Space" to "enter,space"; nil if invalid.
    public static func normalize(_ text: String) -> String? {
        let parts = text.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let allowed = Set(keys.map(\.value))
        guard (1...3).contains(parts.count), parts.allSatisfy(allowed.contains) else { return nil }
        let meaningful = parts.filter { $0 != "none" }
        return meaningful.isEmpty ? "none" : meaningful.joined(separator: ",")
    }
}

/// Parsed fingerprint prompt emitted during `CONFIG_UNLOCK` and `ENROLL`.
public struct TouchPrompt: Equatable {
    public enum Kind { case touch, lift }
    public let kind: Kind
    public let step: Int
    public let total: Int?

    public static func parse(_ line: String) -> TouchPrompt? {
        let text = line.uppercased()
        guard text.hasPrefix("PROMPT") || text.hasPrefix("TOUCH") || text.hasPrefix("LIFT") else { return nil }
        let body = text.hasPrefix("PROMPT") ? String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces) : text
        let kind: Kind = body.hasPrefix("LIFT") ? .lift : .touch
        if body == "TOUCH_AGAIN" { return TouchPrompt(kind: .touch, step: 2, total: 2) }
        let numbers = body.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return TouchPrompt(kind: kind, step: numbers.first ?? 1, total: numbers.count > 1 ? numbers[1] : nil)
    }
}

public extension Array where Element == String {
    func first(prefix: String) -> String? { first { $0.hasPrefix(prefix) } }
    var isOK: Bool { contains { $0.hasPrefix("OK") || $0.hasSuffix("_OK") } && !contains { $0.hasPrefix("ERR") || $0.hasSuffix("_FAIL") } }
    var summary: String { joined(separator: " | ") }
}
