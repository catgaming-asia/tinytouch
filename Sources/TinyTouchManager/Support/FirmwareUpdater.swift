import CryptoKit
import Foundation
import TinyTouchCore

/// Firmware update with the same steps as the MrOld web controller:
/// fingerprint → `BOOTLOADER` → read chip MAC → pick the per-device (or generic) image
/// from the manifest → verify SHA-256 → write at the app offset with the built-in ROM flasher.
@MainActor
final class FirmwareUpdater: ObservableObject {
    static let baseURL = URL(string: "https://touch.mrold.xyz/controller/firmware/")!

    struct Manifest: Decodable {
        struct Image: Decodable {
            let file: String
            let sha256: String?
            let serial: String?
            let encrypted: Bool?
        }
        let version: String
        let releaseDate: String?
        let appOffset: String?
        let generic: Image?
        let devices: [String: Image]?
    }

    struct Backup: Equatable {
        let version: String
        let file: URL
    }

    /// Where the image comes from: MrOld's website (with offline cache) or a file the user picks.
    enum Source: Equatable {
        case web
        case local(URL)
    }

    enum Phase: Equatable {
        case idle, preparing, waitingForBootloader, flashing, done, failed(String)
    }

    @Published private(set) var manifest: Manifest?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var lines: [String] = []
    @Published private(set) var usingCachedManifest = false
    @Published private(set) var backup: Backup?
    @Published private(set) var backupError: String?

    /// ~/Library/Application Support/TinyTouchManager/firmware — offline copy for when the website is down.
    static var cacheDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TinyTouchManager/firmware", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var isRunning: Bool { [.preparing, .waitingForBootloader, .flashing].contains(phase) }

    /// Fetches the manifest online and caches it; falls back to the cached copy when offline.
    func loadManifest() async {
        let cached = Self.cacheDirectory.appendingPathComponent("manifest.json")
        do {
            var request = URLRequest(url: Self.baseURL.appendingPathComponent("manifest.json"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, _) = try await URLSession.shared.data(for: request)
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
            try? data.write(to: cached, options: .atomic)
            usingCachedManifest = false
        } catch {
            if let data = try? Data(contentsOf: cached), let saved = try? JSONDecoder().decode(Manifest.self, from: data) {
                manifest = saved
                usingCachedManifest = true
                model.log(.warning, "Web MrOld không truy cập được – dùng manifest đã lưu (v\(saved.version))")
            } else {
                model.log(.warning, "Không tải được manifest: \(error.localizedDescription)")
            }
        }
        refreshBackupState()
    }

    /// Saves this device's firmware package (and the generic one) for offline recovery.
    func backupDevicePackage() async {
        backupError = nil
        if manifest == nil { await loadManifest() }
        guard let manifest else { backupError = "Chưa có manifest."; return }
        guard let mac = DeviceStatus.chipMAC(fromSerial: model.port?.serialNumber) else {
            backupError = "Không xác định được MAC chip từ số serial USB."
            return
        }
        do {
            if let device = manifest.devices?[mac] {
                _ = try await imageData(device, version: manifest.version)
            } else {
                backupError = "Manifest không có gói riêng cho \(mac)."
            }
            if let generic = manifest.generic { _ = try? await imageData(generic, version: manifest.version) }
            refreshBackupState()
            if let backup { model.log(.success, "Đã sao lưu gói firmware v\(backup.version) cho thiết bị \(mac)") }
        } catch {
            backupError = error.localizedDescription
        }
    }

    func refreshBackupState() {
        guard let manifest, let mac = DeviceStatus.chipMAC(fromSerial: model.port?.serialNumber),
              let device = manifest.devices?[mac] else {
            backup = nil
            return
        }
        let file = cachedFile(device, version: manifest.version)
        backup = Self.verified(file, sha256: device.sha256) ? Backup(version: manifest.version, file: file) : nil
    }

    private func cachedFile(_ image: Manifest.Image, version: String) -> URL {
        Self.cacheDirectory.appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent((image.file as NSString).lastPathComponent)
    }

    /// Returns the image bytes from the offline cache, or downloads, verifies and caches them.
    private func imageData(_ image: Manifest.Image, version: String) async throws -> Data {
        let file = cachedFile(image, version: version)
        if Self.verified(file, sha256: image.sha256), let data = try? Data(contentsOf: file) {
            return data
        }
        let (data, response) = try await URLSession.shared.data(from: Self.baseURL.appendingPathComponent(image.file))
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("Không tải được gói cập nhật (HTTP \(http.statusCode)).")
        }
        if let expected = image.sha256, expected.lowercased() != Self.sha256(data) {
            throw UpdateError("Kiểm tra toàn vẹn gói cập nhật thất bại (SHA-256 không khớp).")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verified(_ file: URL, sha256 expected: String?) -> Bool {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return false }
        return expected.map { $0.lowercased() == sha256(data) } ?? true
    }

    func isNewer(than current: String?) -> Bool {
        guard let latest = manifest?.version, let current else { return false }
        return latest.compare(current, options: .numeric) == .orderedDescending
    }

    /// - Parameter recovery: the device is already in ROM download mode (no working firmware),
    ///   so skip the fingerprint/BOOTLOADER step.
    func start(recovery: Bool = false, source: Source = .web) {
        guard !isRunning else { return }
        lines.removeAll()
        progress = 0
        Task {
            do {
                try await run(recovery: recovery, source: source)
                phase = .done
                note("✓ Cập nhật hoàn tất. Hãy rút cáp USB và cắm lại tinyTouch.")
            } catch {
                phase = .failed(error.localizedDescription)
                note("❌ \(error.localizedDescription)")
            }
            model.resumeAfterFirmwareUpdate()
        }
    }

    private func run(recovery: Bool, source: Source) async throws {
        if manifest == nil { await loadManifest() }
        if case .web = source, manifest == nil { throw UpdateError("Không có thông tin phiên bản firmware.") }
        var localData: Data?
        if case let .local(url) = source {
            localData = try Data(contentsOf: url)
            note("File đã chọn: \(url.lastPathComponent) (\(localData!.count) byte, SHA-256 \(Self.sha256(localData!).prefix(16))…)")
        }

        phase = .preparing
        if recovery {
            model.pauseForFirmwareUpdate()
            note("Chế độ cứu hộ: tìm thiết bị đang ở chế độ nạp…")
        } else {
            note("Chạm vân tay để xác nhận quyền nâng cấp…")
            try await model.enterBootloader()
            note("✓ Thiết bị đã vào chế độ nạp.")
        }

        phase = .waitingForBootloader
        let port = try await waitForBootloaderPort()
        note("Cổng nạp: \(port)")

        let flasher = ESPFlasher(path: port)
        flasher.log = { [weak self] line in Task { @MainActor in self?.note(line) } }
        defer { flasher.close() }
        let (mac, security) = try await Task.detached { () throws -> (String, ESPFlasher.SecurityInfo?) in
            try flasher.open()
            try flasher.connect()
            return (try flasher.readMAC(), try? flasher.securityInfo())
        }.value
        note("✓ Đã kết nối bootloader. MAC chip: \(mac)")
        if let security {
            note("Bảo mật chip: mã hóa flash \(security.flashEncrypted ? "BẬT" : "tắt"), Secure Boot \(security.secureBoot ? "BẬT" : "tắt"), Secure Download \(security.secureDownloadMode ? "BẬT" : "tắt").")
        }
        let encrypted = security?.flashEncrypted == true || manifest?.devices?[mac]?.encrypted == true

        let data: Data
        if case let .local(url) = source, let localData {
            try validateLocal(localData, name: url.deletingPathExtension().lastPathComponent, mac: mac, encrypted: encrypted)
            data = localData
        } else {
            data = try await webImage(mac: mac, encrypted: encrypted)
        }
        let offsetText = manifest?.appOffset ?? "0x10000"
        guard let offset = UInt32(offsetText.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            throw UpdateError("Địa chỉ nạp không hợp lệ: \(offsetText)")
        }

        phase = .flashing
        note("⚡ Đang nạp \(data.count) byte tại \(offsetText)… KHÔNG rút cáp USB!")
        try await Task.detached {
            try flasher.flash(data, offset: offset) { value in
                Task { @MainActor in self.progress = value }
            }
            flasher.hardReset()
        }.value
        progress = 1
    }

    /// Read-only check: enters the bootloader, reads MAC and security fuses, then reboots the device.
    func inspectChip() {
        guard !isRunning else { return }
        lines.removeAll()
        progress = 0
        Task {
            do {
                phase = .preparing
                note("Chạm vân tay để xác nhận…")
                try await model.enterBootloader()
                phase = .waitingForBootloader
                let port = try await waitForBootloaderPort()
                note("Cổng nạp: \(port)")
                let flasher = ESPFlasher(path: port)
                defer { flasher.close() }
                let (mac, security) = try await Task.detached { () throws -> (String, ESPFlasher.SecurityInfo) in
                    try flasher.open()
                    try flasher.connect()
                    let result = (try flasher.readMAC(), try flasher.securityInfo())
                    flasher.hardReset()
                    return result
                }.value
                chipReport = ChipReport(mac: mac, security: security)
                note("MAC chip: \(mac) · chip id \(security.chipID.map(String.init) ?? "?")")
                note("Mã hóa flash: \(security.flashEncrypted ? "BẬT" : "tắt") (FLASH_CRYPT_CNT=\(security.flashCryptCount)) · Secure Boot: \(security.secureBoot ? "BẬT" : "tắt") · Secure Download: \(security.secureDownloadMode ? "BẬT" : "tắt")")
                note("✓ Đã khởi động lại thiết bị. Nếu chưa tự kết nối lại, hãy rút cáp và cắm lại.")
                phase = .done
            } catch {
                phase = .failed(error.localizedDescription)
                note("❌ \(error.localizedDescription)")
            }
            model.resumeAfterFirmwareUpdate()
        }
    }

    struct ChipReport: Equatable {
        let mac: String
        let security: ESPFlasher.SecurityInfo
    }

    @Published private(set) var chipReport: ChipReport?

    /// Picks this chip's package from the manifest (cache first, then the website).
    private func webImage(mac: String, encrypted: Bool) async throws -> Data {
        guard let manifest else { throw UpdateError("Không có manifest.") }
        let image: Manifest.Image
        if let device = manifest.devices?[mac] {
            image = device
            note("✓ Đã nhận diện phần cứng chính hãng (\(device.serial ?? mac)).")
        } else {
            if encrypted {
                throw UpdateError("Thiết bị mã hóa (MAC \(mac)) chưa có gói cập nhật. Gửi mã MAC này cho shop để được cấp gói.")
            }
            guard let generic = manifest.generic else { throw UpdateError("Manifest không có gói chung.") }
            image = generic
            note("Thiết bị chưa đăng ký riêng – dùng gói chung.")
        }

        note("Đang lấy firmware v\(manifest.version) (ưu tiên bản đã lưu trên máy)…")
        let data = try await imageData(image, version: manifest.version)
        note("✓ Gói cập nhật hợp lệ (\(data.count) byte).")
        return data
    }

    /// Refuses local images that cannot run on this chip (wrong per-device package, or plain image on an encrypted chip).
    private func validateLocal(_ data: Data, name: String, mac: String, encrypted: Bool) throws {
        let digest = Self.sha256(data)
        let upperName = name.uppercased()
        if upperName.count >= 8, upperName.allSatisfy(\.isHexDigit), upperName != mac {
            throw UpdateError("File \(name).bin là gói riêng của chip khác (chip này: \(mac)). Nạp sẽ làm thiết bị không khởi động.")
        }
        if let device = manifest?.devices?[mac], device.sha256?.lowercased() == digest {
            note("✓ File khớp gói chính hãng của thiết bị này trong manifest.")
            return
        }
        if let generic = manifest?.generic, generic.sha256?.lowercased() == digest {
            if encrypted { throw UpdateError("Đây là gói chung không mã hóa; chip này đã mã hóa nên sẽ không khởi động được.") }
            note("✓ File khớp gói chung trong manifest.")
            return
        }
        if let other = manifest?.devices?.first(where: { $0.value.sha256?.lowercased() == digest }) {
            throw UpdateError("File này là gói của thiết bị \(other.key), không phải chip \(mac).")
        }
        note("⚠️ File không có trong manifest – không kiểm tra được tính toàn vẹn. Tiếp tục theo lựa chọn của bạn.")
    }

    private func waitForBootloaderPort() async throws -> String {
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 500_000_000)
            // The ROM loader enumerates as "USB JTAG/serial debug unit", not as tinyTouch.
            if let port = DeviceDiscovery.ports().first(where: { $0.vendorID == DeviceDiscovery.espressifVendorID && $0.isROMBootloader }) {
                return port.path
            }
        }
        throw UpdateError("Không thấy cổng nạp của thiết bị. Thử rút ra cắm lại khi giữ nút BOOT.")
    }

    private func note(_ line: String) {
        lines.append(line)
        model.log(.info, "Firmware: \(line)")
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
