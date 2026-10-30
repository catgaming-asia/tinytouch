import AppKit
import Combine
import ServiceManagement
import SwiftUI
import TinyTouchCore

struct LogEntry: Identifiable {
    enum Kind { case info, success, warning, error, tx, rx }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let message: String
}

/// Fingerprint prompt shown while the device waits for a touch.
struct AuthPrompt: Equatable {
    var title: String
    var message: String
    var step: Int?
    var total: Int?
    var lift = false
}

enum ConnectionState: Equatable {
    case searching
    case connecting(String)
    case connected(String)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, fingers, mode, keys, passkeys, pairing, unlock, firmware, logs, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Tổng quan"
        case .fingers: return "Vân tay & Mật khẩu"
        case .mode: return "Chế độ hoạt động"
        case .keys: return "Phím sau khi điền"
        case .passkeys: return "Passkeys FIDO2"
        case .pairing: return "Ghép đôi Mac"
        case .unlock: return "Tự động mở khóa"
        case .firmware: return "Firmware"
        case .logs: return "Nhật ký"
        case .advanced: return "Nâng cao"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.33percent"
        case .fingers: return "touchid"
        case .mode: return "switch.2"
        case .keys: return "keyboard"
        case .passkeys: return "person.badge.key"
        case .pairing: return "link"
        case .unlock: return "lock.open"
        case .firmware: return "cpu"
        case .logs: return "list.bullet.rectangle"
        case .advanced: return "exclamationmark.triangle"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    // MARK: Device state
    @Published private(set) var connection: ConnectionState = .searching
    @Published private(set) var port: DevicePort?
    @Published private(set) var status: DeviceStatus?
    @Published private(set) var slots: [SlotInfo] = (1...5).map { SlotInfo(id: $0) }
    @Published private(set) var passkeys: [Passkey]?
    @Published private(set) var passkeysLocked = false
    @Published private(set) var hostIDs: [String]?
    @Published var authPrompt: AuthPrompt?
    @Published var busy = false
    @Published var alert: AlertMessage?
    @Published var selection: AppSection? = .overview

    // MARK: Mac-side state
    @Published private(set) var macPasswordSlots: Set<Int> = []
    @Published private(set) var isPaired = false
    @Published private(set) var accessibilityTrusted = SystemContext.isAccessibilityTrusted
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var logs: [LogEntry] = []

    @AppStorage("unlockEnabled") var unlockEnabled = true
    @AppStorage("guardEnabled") var guardEnabled = true
    @AppStorage("sudoEnabled") var sudoEnabled = true
    @AppStorage("promptLedEnabled") var promptLedEnabled = true
    @AppStorage("promptLedTimeoutMinutes") var promptLedTimeoutMinutes = 5

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var client: DeviceClient?
    private var service: DeviceService?
    private let responder = TouchResponder()
    private var pollTimer: Timer?
    private var controlServer: ControlSocketServer?
    private(set) lazy var promptLed = PromptLedMonitor(model: self)
    private(set) lazy var firmware = FirmwareUpdater(model: self)
    private var firmwareUpdating = false

    var fingerprints: Int { status?.fingerprints ?? 0 }
    var pairingAccount: String { port?.deviceID ?? "default" }

    private init() {}

    func start() {
        refreshMacState()
        startControlSocket()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        promptLed.start()
        log(.info, "TinyTouch Manager \(Self.appVersion) đã khởi động")
    }

    func shutdown() {
        promptLed.stop()
        controlServer?.stop()
        client?.close()
    }

    // MARK: Connection

    private func tick() {
        accessibilityTrusted = SystemContext.isAccessibilityTrusted
        if client == nil && !firmwareUpdating { connectIfPossible() }
    }

    private func connectIfPossible() {
        guard let found = DeviceDiscovery.tinyTouchPort() else {
            if case .failed = connection { return }
            connection = .searching
            return
        }
        if case let .failed(message) = connection, port == found, message.contains("đang được") {
            // Port held by another app; retry quietly on each tick.
        }
        port = found
        connection = .connecting(found.path)
        let client = DeviceClient(port: found)
        client.onEvent = { [weak self] line in Task { @MainActor in self?.handleTouchEvent(line) } }
        client.onUnsolicited = { [weak self] line in Task { @MainActor in self?.log(.rx, line) } }
        client.onTraffic = { [weak self] outgoing, line in
            Task { @MainActor in self?.log(outgoing ? .tx : .rx, line) }
        }
        client.onClose = { [weak self] error in
            Task { @MainActor in self?.handleDisconnect(error) }
        }
        do {
            try client.open()
        } catch {
            if case .failed = connection {} else { log(.error, error.localizedDescription) }
            connection = .failed(error.localizedDescription)
            return
        }
        self.client = client
        service = DeviceService(channel: client)
        Task {
            do {
                try await refresh()
                connection = .connected(found.path)
                log(.success, "Đã kết nối \(found.path) (\(found.serialNumber ?? "không rõ serial"))")
                refreshMacState()
                promptLed.resync()
                await firmware.backupDevicePackage()
            } catch {
                log(.error, "Thiết bị không phản hồi STATUS: \(error.localizedDescription)")
                client.close()
            }
        }
    }

    private func handleDisconnect(_ error: Error?) {
        guard client != nil else { return }
        client = nil
        service = nil
        status = nil
        connection = .searching
        authPrompt = nil
        log(.warning, "Đã ngắt kết nối thiết bị" + (error.map { ": \($0.localizedDescription)" } ?? ""))
    }

    func reconnect() {
        client?.close()
        client = nil
        connection = .searching
        tick()
    }

    // MARK: Refresh

    func refresh() async throws {
        guard let service else { throw DeviceClientError.closed }
        let snapshot = try await service.snapshot()
        status = snapshot.status
        slots = snapshot.slots
        if snapshot.passkeys != nil || snapshot.passkeysLocked {
            passkeys = snapshot.passkeys
            passkeysLocked = snapshot.passkeysLocked
        }
        hostIDs = try? await service.pairedHostIDs()
        refreshMacState()
    }

    func refreshMacState() {
        macPasswordSlots = Set((0...5).filter {
            KeychainStore.exists(service: KeychainStore.passwordService, account: KeychainStore.passwordAccount(slot: $0))
        })
        isPaired = KeychainStore.exists(service: KeychainStore.pairingService, account: pairingAccount)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        accessibilityTrusted = SystemContext.isAccessibilityTrusted
    }

    // MARK: Generic action runner

    /// Runs a device action with a fingerprint sheet, logging and error alerts.
    func perform(_ title: String, prompt: String = "Chạm ngón tay đã đăng ký vào cảm biến tinyTouch để xác nhận.",
                 needsTouch: Bool = true, success: String? = nil,
                 _ body: @escaping (DeviceService, @escaping (String) -> Void) async throws -> Void) {
        guard let service, !busy else { return }
        busy = true
        if needsTouch {
            authPrompt = AuthPrompt(title: title, message: fingerprints > 0 ? prompt : "Đang gửi lệnh tới thiết bị…")
        }
        let onPrompt: (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.updatePrompt(with: line) }
        }
        Task {
            defer {
                busy = false
                authPrompt = nil
            }
            do {
                try await body(service, onPrompt)
                if let success { log(.success, success) }
                try? await refresh()
            } catch {
                log(.error, "\(title): \(error.localizedDescription)")
                alert = AlertMessage(title: title, message: error.localizedDescription)
            }
        }
    }

    private func updatePrompt(with line: String) {
        guard var prompt = authPrompt, let parsed = TouchPrompt.parse(line) else { return }
        prompt.step = parsed.step
        prompt.total = parsed.total ?? prompt.total
        prompt.lift = parsed.kind == .lift
        prompt.message = parsed.kind == .lift ? "Nhấc ngón tay ra khỏi cảm biến…" : "Đặt ngón tay lên cảm biến…"
        authPrompt = prompt
    }

    // MARK: Device actions (web controller parity)

    func setMode(_ mode: DeviceMode) {
        perform("Chuyển sang \(mode.rawValue.uppercased())", success: "Đã chuyển sang chế độ \(mode.rawValue.uppercased())") { service, onPrompt in
            try await service.setMode(mode, fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func enroll(slot: Int, touches: Int) {
        let title = "Đăng ký \(SlotInfo(id: slot).name) (\(touches) lần chạm)"
        perform(title, prompt: "Chạm ngón đã đăng ký để mở khóa, sau đó đặt ngón mới theo hướng dẫn.",
                success: "Đã đăng ký vân tay cho ngón \(slot)") { service, onPrompt in
            await MainActor.run { self.authPrompt?.total = touches }
            try await service.enroll(slot: slot, touches: touches, fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func setChipPassword(slot: Int, password: String) {
        perform("Lưu mật khẩu trên chip – ngón \(slot)", success: "Đã lưu mật khẩu ngón \(slot) vào chip") { service, onPrompt in
            try await service.setChipPassword(slot: slot, password: password, fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func clearChipPassword(slot: Int) {
        perform("Xóa mật khẩu trên chip – ngón \(slot)", success: "Đã xóa mật khẩu ngón \(slot) trên chip") { service, onPrompt in
            try await service.clearChipPassword(slot: slot, fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func setPostKey(_ sequence: String) {
        perform("Đổi phím sau khi điền", success: "Đã đổi phím sau khi điền: \(sequence)") { service, onPrompt in
            try await service.setPostKey(sequence, fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func setPostKeyDelay(_ ms: Int) {
        perform("Đổi thời gian chờ giữa các phím", success: "Thời gian chờ giữa các phím: \(ms) ms") { service, onPrompt in
            try await service.setPostKeyDelay(ms, fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func setWakeDelay(_ ms: Int) {
        perform("Đổi thời gian chờ khi đánh thức", success: "Thời gian chờ khi đánh thức: \(ms) ms") { service, onPrompt in
            try await service.setWakeDelay(ms, fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func unlockPasskeys() {
        perform("Xem Passkeys") { service, onPrompt in
            let list = try await service.unlockedPasskeys(fingerprints: self.fingerprints, onPrompt: onPrompt)
            await MainActor.run {
                self.passkeys = list
                self.passkeysLocked = false
            }
        }
    }

    func deletePasskey(_ passkey: Passkey) {
        perform("Xóa Passkey \(passkey.rpId ?? passkey.id)", success: "Đã xóa Passkey \(passkey.rpId ?? passkey.id)") { service, onPrompt in
            try await service.deletePasskey(id: passkey.id, fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func clearPasskeys() {
        perform("Xóa toàn bộ Passkeys", success: "Đã xóa toàn bộ Passkeys") { service, onPrompt in
            try await service.clearPasskeys(fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func factoryReset() {
        perform("Khôi phục cài đặt gốc", success: "Đã khôi phục cài đặt gốc – thiết bị đang khởi động lại") { service, onPrompt in
            try await service.factoryReset(fingerprints: self.fingerprints, onPrompt: onPrompt)
        }
    }

    func sendRaw(_ command: String) {
        guard let service, !command.isEmpty else { return }
        Task {
            do { _ = try await service.run(command, timeout: 20) } catch { log(.error, error.localizedDescription) }
        }
    }

    // MARK: Firmware update

    /// Authorises with a fingerprint, reboots the device into its ROM bootloader and releases the port.
    func enterBootloader() async throws {
        guard let service, let client else { throw DeviceClientError.closed }
        firmwareUpdating = true
        authPrompt = AuthPrompt(title: "Xác thực nâng cấp firmware",
                                message: "Chạm vân tay đã đăng ký vào cảm biến để xác nhận quyền nâng cấp.")
        defer { authPrompt = nil }
        do {
            let lines = try await service.run("CONFIG_UNLOCK", timeout: fingerprints > 0 ? 20 : 4)
            guard lines.contains(where: { $0.hasPrefix("OK CONFIG_UNLOCK") }) else {
                throw DeviceClientError.rejected("vân tay không khớp hoặc không chạm kịp")
            }
            _ = try? await service.run("BOOTLOADER", timeout: 2)
        } catch {
            firmwareUpdating = false
            throw error
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        client.close()
    }

    /// Stops auto-connecting so esptool can own a port that is already in download mode.
    func pauseForFirmwareUpdate() {
        firmwareUpdating = true
        client?.close()
    }

    func resumeAfterFirmwareUpdate() {
        firmwareUpdating = false
        tick()
    }

    // MARK: Pairing (this Mac ↔ device)

    func pairThisMac() {
        perform("Ghép đôi Mac này", success: "Đã ghép đôi Mac này với tinyTouch") { service, onPrompt in
            let account = await MainActor.run { self.pairingAccount }
            let key = try await service.pairNewHost(fingerprints: self.fingerprints, onPrompt: onPrompt)
            if let oldKey = try? KeychainStore.get(service: KeychainStore.pairingService, account: account),
               oldKey.count == 32 {
                // Re-pairing: drop the previous key of this Mac from the device.
                try? await service.removeHost(id: PairingCrypto.keyID(oldKey), fingerprints: self.fingerprints, onPrompt: onPrompt)
            }
            try KeychainStore.set(key, service: KeychainStore.pairingService, account: account)
        }
    }

    var thisMacHostID: String? {
        guard isPaired, let key = try? KeychainStore.get(service: KeychainStore.pairingService, account: pairingAccount),
              key.count == 32 else { return nil }
        return PairingCrypto.keyID(key)
    }

    func removeHost(_ id: String) {
        perform("Gỡ ghép đôi \(id)", success: "Đã gỡ máy \(id) khỏi thiết bị") { service, onPrompt in
            try await service.removeHost(id: id, fingerprints: self.fingerprints, onPrompt: onPrompt)
            let account = await MainActor.run { self.pairingAccount }
            if let key = try? KeychainStore.get(service: KeychainStore.pairingService, account: account),
               PairingCrypto.keyID(key) == id {
                try? KeychainStore.delete(service: KeychainStore.pairingService, account: account)
            }
        }
    }

    // MARK: Mac passwords (Keychain)

    func saveMacPassword(slot: Int, password: String) {
        do {
            guard !password.isEmpty, password.utf8.count <= PairingCrypto.maxPasswordBytes else {
                throw PairingCrypto.CryptoError.passwordLength
            }
            try KeychainStore.set(Data(password.utf8), service: KeychainStore.passwordService,
                                  account: KeychainStore.passwordAccount(slot: slot))
            log(.success, slot == 0 ? "Đã lưu mật khẩu Mac mặc định vào Keychain" : "Đã lưu mật khẩu Mac cho ngón \(slot)")
        } catch {
            alert = AlertMessage(title: "Không lưu được mật khẩu", message: error.localizedDescription)
        }
        refreshMacState()
    }

    func deleteMacPassword(slot: Int) {
        try? KeychainStore.delete(service: KeychainStore.passwordService, account: KeychainStore.passwordAccount(slot: slot))
        log(.info, slot == 0 ? "Đã xóa mật khẩu Mac mặc định" : "Đã xóa mật khẩu Mac của ngón \(slot)")
        refreshMacState()
    }

    // MARK: Touch events → password reply

    private func handleTouchEvent(_ line: String) {
        let key = try? KeychainStore.get(service: KeychainStore.pairingService, account: pairingAccount)
        let outcome = responder.handle(line: line, pairingKey: key, password: { slot in
            (try? KeychainStore.get(service: KeychainStore.passwordService, account: KeychainStore.passwordAccount(slot: slot)))
                ?? (try? KeychainStore.get(service: KeychainStore.passwordService, account: KeychainStore.passwordAccount(slot: 0)))
        }, allow: { self.typingRefusal() })
        switch outcome {
        case let .replied(slot, reply):
            client?.writeLine(reply)
            log(.success, "Vân tay ngón \(slot) khớp – đã gửi mật khẩu đã mã hóa cho thiết bị gõ")
            promptLed.touchHandled()
        case let .ignored(reason):
            log(.warning, "Bỏ qua lần chạm: \(reason)")
        }
    }

    /// Returns why typing is not allowed right now, or nil if it is.
    private func typingRefusal() -> String? {
        if SystemContext.isScreenLocked {
            return unlockEnabled ? nil : "màn hình đang khóa nhưng tính năng Mở khóa màn hình đang tắt"
        }
        let bundle = SystemContext.frontmostBundleID ?? ""
        if SystemContext.terminalBundleIDs.contains(bundle) {
            guard sudoEnabled else { return "Xác thực sudo đang tắt" }
            if guardEnabled && !SystemContext.isSecureInputActive && !SystemContext.isPasswordFieldFocused {
                return "Terminal không ở dấu nhắc mật khẩu"
            }
            return nil
        }
        guard guardEnabled else { return nil }
        if SystemContext.authPromptBundleIDs.contains(bundle) || SystemContext.isPasswordFieldFocused
            || SystemContext.isSecureInputActive {
            return nil
        }
        return accessibilityTrusted
            ? "con trỏ không ở ô mật khẩu (chế độ Bảo vệ)"
            : "chưa cấp quyền Trợ năng nên không kiểm tra được ô mật khẩu"
    }

    // MARK: Prompt LED (LED_PROMPT 1/0)

    func setDeviceLed(_ on: Bool) {
        guard let service, connection.isConnected else { return }
        Task { _ = try? await service.run("LED_PROMPT \(on ? 1 : 0)", timeout: 2) }
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            alert = AlertMessage(title: "Khởi động cùng macOS", message: error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: CLI bridge

    private func startControlSocket() {
        let server = ControlSocketServer { [weak self] command, timeout, emit in
            guard let self else { return }
            let channel = await MainActor.run { self.client }
            guard let channel else {
                emit("ERR CLIENT TinyTouch Manager chưa kết nối thiết bị")
                return
            }
            await MainActor.run { self.log(.info, "CLI: \(DeviceClient.redact(command))") }
            do {
                _ = try await channel.send(command, timeout: timeout, onLine: emit)
            } catch {
                emit("ERR CLIENT \(error.localizedDescription)")
            }
            if command.hasPrefix("ENROLL") || command.hasPrefix("MODE") || command.hasPrefix("SET_SLOT") {
                Task { @MainActor in try? await self.refresh() }
            }
        }
        do {
            try server.start()
            controlServer = server
        } catch {
            log(.warning, "Không mở được cổng điều khiển cho CLI: \(error.localizedDescription)")
        }
    }

    // MARK: Logging

    func log(_ kind: LogEntry.Kind, _ message: String) {
        logs.append(LogEntry(kind: kind, message: message))
        if logs.count > 1000 { logs.removeFirst(logs.count - 1000) }
    }

    func clearLogs() { logs.removeAll() }
}
