import Foundation

/// Minimal ESP32-S3 ROM bootloader client (the protocol esptool / esptool-js speak), so firmware
/// can be flashed without installing anything. Uses the ROM loader directly (no stub): SLIP frames,
/// SYNC, READ_REG, GET_SECURITY_INFO, SPI_ATTACH, FLASH_BEGIN / FLASH_DATA / FLASH_END.
public final class ESPFlasher {
    public struct SecurityInfo: Equatable {
        public let flags: UInt32
        public let flashCryptCount: UInt8
        public let chipID: UInt32?

        public var flashEncrypted: Bool { flashCryptCount.nonzeroBitCount % 2 == 1 }
        public var secureBoot: Bool { flags & 1 != 0 }
        public var secureDownloadMode: Bool { flags & (1 << 2) != 0 }
    }

    public enum FlasherError: LocalizedError {
        case open(String)
        case noSync
        case timeout(String)
        case command(String, UInt8, UInt8)
        case wrongChip(UInt32)

        public var errorDescription: String? {
            switch self {
            case let .open(message): return message
            case .noSync: return "Không đồng bộ được với bootloader. Rút cáp, giữ nút BOOT rồi cắm lại."
            case let .timeout(command): return "Bootloader không phản hồi lệnh \(command)."
            case let .command(command, status, code): return "Bootloader báo lỗi ở \(command) (status \(status), mã \(code))."
            case let .wrongChip(id): return "Chip không phải ESP32-S3 (chip id \(id))."
            }
        }
    }

    static let esp32s3ChipID: UInt32 = 9
    static let flashWriteSize = 0x400
    static let macEfuseRegister: UInt32 = 0x6000_7044

    private enum Op: UInt8 {
        case flashBegin = 0x02, flashData = 0x03, flashEnd = 0x04, sync = 0x08, readReg = 0x0A
        case spiAttach = 0x0D, securityInfo = 0x14
    }

    private let path: String
    private var fd: Int32 = -1
    private var pending = [UInt8]()
    public var log: ((String) -> Void)?

    public init(path: String) {
        self.path = path
    }

    deinit { close() }

    // MARK: Connection

    public func open() throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw FlasherError.open("Không mở được \(path): \(String(cString: strerror(errno)))") }
        var settings = termios()
        tcgetattr(fd, &settings)
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(B115200))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &settings)
        tcflush(fd, TCIOFLUSH)
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Syncs with the ROM loader, resetting into download mode first if needed (USB-Serial/JTAG sequence).
    public func connect() throws {
        if (try? sync(attempts: 3)) == true { return }
        log?("Đang đặt lại chip vào chế độ nạp…")
        resetIntoBootloader()
        guard (try? sync(attempts: 7)) == true else { throw FlasherError.noSync }
    }

    private func sync(attempts: Int) throws -> Bool {
        let payload: [UInt8] = [0x07, 0x07, 0x12, 0x20] + [UInt8](repeating: 0x55, count: 32)
        for _ in 0..<attempts {
            pending.removeAll()
            tcflush(fd, TCIFLUSH)
            if (try? command(.sync, payload, timeout: 0.2)) != nil {
                // The ROM answers SYNC several times; drain the extra replies.
                while (try? readPacket(timeout: 0.1)) != nil {}
                return true
            }
        }
        return false
    }

    private func setLines(dtr: Bool, rts: Bool) {
        var bits: Int32 = 0
        _ = ioctl(fd, TIOCMGET, &bits)
        bits = dtr ? bits | TIOCM_DTR : bits & ~TIOCM_DTR
        bits = rts ? bits | TIOCM_RTS : bits & ~TIOCM_RTS
        _ = ioctl(fd, TIOCMSET, &bits)
    }

    private func resetIntoBootloader() {
        setLines(dtr: false, rts: false)
        usleep(100_000)
        setLines(dtr: true, rts: false)
        usleep(100_000)
        setLines(dtr: false, rts: true)
        usleep(100_000)
        setLines(dtr: false, rts: false)
        usleep(500_000)
    }

    /// Pulses EN via RTS so the chip boots the new firmware.
    public func hardReset() {
        setLines(dtr: false, rts: true)
        usleep(200_000)
        setLines(dtr: false, rts: false)
    }

    // MARK: Queries

    public func readRegister(_ address: UInt32) throws -> UInt32 {
        try command(.readReg, le32(address)).value
    }

    /// Chip MAC as 12 uppercase hex digits (the key used by the MrOld manifest).
    public func readMAC() throws -> String {
        let mac0 = try readRegister(Self.macEfuseRegister)
        let mac1 = try readRegister(Self.macEfuseRegister + 4)
        let bytes = [UInt8((mac1 >> 8) & 0xFF), UInt8(mac1 & 0xFF),
                     UInt8(mac0 >> 24), UInt8((mac0 >> 16) & 0xFF), UInt8((mac0 >> 8) & 0xFF), UInt8(mac0 & 0xFF)]
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    public func securityInfo() throws -> SecurityInfo {
        let data = try command(.securityInfo, []).data
        guard data.count >= 12 else { throw FlasherError.timeout("GET_SECURITY_INFO") }
        let flags = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        var chipID: UInt32?
        if data.count >= 16 {
            chipID = UInt32(data[12]) | UInt32(data[13]) << 8 | UInt32(data[14]) << 16 | UInt32(data[15]) << 24
        }
        return SecurityInfo(flags: flags, flashCryptCount: data[4], chipID: chipID)
    }

    // MARK: Flashing

    /// Erases and writes `image` at `offset`, reporting progress 0…1. The image is written as-is
    /// (MrOld per-device packages are already encrypted for the chip).
    public func flash(_ image: Data, offset: UInt32, progress: (Double) -> Void) throws {
        if let info = try? securityInfo(), let chip = info.chipID, chip != Self.esp32s3ChipID {
            throw FlasherError.wrongChip(chip)
        }
        _ = try command(.spiAttach, le32(0) + le32(0))

        let blockSize = Self.flashWriteSize
        let blocks = (image.count + blockSize - 1) / blockSize
        let eraseTimeout = max(10, Double(image.count) / 1_000_000 * 30)
        log?("Đang xóa vùng flash…")
        _ = try command(.flashBegin, le32(UInt32(image.count)) + le32(UInt32(blocks)) + le32(UInt32(blockSize))
                        + le32(offset) + le32(0), timeout: eraseTimeout)

        let bytes = [UInt8](image)
        for index in 0..<blocks {
            var block = Array(bytes[(index * blockSize)..<min(bytes.count, (index + 1) * blockSize)])
            block += [UInt8](repeating: 0xFF, count: blockSize - block.count)
            let header = le32(UInt32(block.count)) + le32(UInt32(index)) + le32(0) + le32(0)
            _ = try command(.flashData, header + block, checksum: Self.checksum(block), timeout: 5)
            progress(Double(index + 1) / Double(blocks))
        }
        // Stay in the loader; the caller resets the chip.
        _ = try? command(.flashEnd, le32(1), timeout: 2)
    }

    // MARK: Packets

    private struct Response {
        let value: UInt32
        let data: [UInt8]
    }

    @discardableResult
    private func command(_ op: Op, _ data: [UInt8], checksum: UInt32 = 0, timeout: TimeInterval = 3) throws -> Response {
        var packet: [UInt8] = [0x00, op.rawValue]
        packet += le16(UInt16(data.count)) + le32(checksum) + data
        try write(Self.slipEncode(packet))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let reply = try readPacket(timeout: deadline.timeIntervalSinceNow) else { break }
            guard reply.count >= 8, reply[0] == 0x01, reply[1] == op.rawValue else { continue }
            let value = UInt32(reply[4]) | UInt32(reply[5]) << 8 | UInt32(reply[6]) << 16 | UInt32(reply[7]) << 24
            let body = Array(reply[8...])
            // ROM loader appends 4 status bytes; the first two are status and error code.
            let statusLength = body.count >= 4 ? 4 : 2
            guard body.count >= statusLength else { throw FlasherError.timeout("\(op)") }
            let status = body[body.count - statusLength]
            let code = body[body.count - statusLength + 1]
            if status != 0 { throw FlasherError.command("\(op)", status, code) }
            return Response(value: value, data: Array(body.dropLast(statusLength)))
        }
        throw FlasherError.timeout("\(op)")
    }

    private func readPacket(timeout: TimeInterval) throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var frame: [UInt8]?
        while true {
            while !pending.isEmpty {
                let byte = pending.removeFirst()
                if byte == 0xC0 {
                    if let current = frame, !current.isEmpty { return Self.slipDecode(current) }
                    frame = []
                } else if frame != nil {
                    frame!.append(byte)
                }
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining, 1) * 1000))
            if ready > 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 { pending += buffer[0..<count] }
                else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    throw FlasherError.open("Mất kết nối cổng nạp.")
                }
            }
        }
    }

    private func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if written > 0 { offset += written }
            else if errno == EAGAIN || errno == EINTR { usleep(1000) }
            else { throw FlasherError.open("Lỗi ghi cổng nạp: \(String(cString: strerror(errno)))") }
        }
    }

    // MARK: Encoding helpers

    static func slipEncode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0xC0]
        for byte in bytes {
            switch byte {
            case 0xC0: out += [0xDB, 0xDC]
            case 0xDB: out += [0xDB, 0xDD]
            default: out.append(byte)
            }
        }
        out.append(0xC0)
        return out
    }

    static func slipDecode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var escape = false
        for byte in bytes {
            if escape {
                out.append(byte == 0xDC ? 0xC0 : byte == 0xDD ? 0xDB : byte)
                escape = false
            } else if byte == 0xDB {
                escape = true
            } else {
                out.append(byte)
            }
        }
        return out
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        UInt32(bytes.reduce(UInt8(0xEF)) { $0 ^ $1 })
    }

    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }
}
