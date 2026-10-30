import Foundation
import TinyTouchCore

/// `tinytouch` — command-line control, same commands as the MrOld quick-start sheet.
/// Talks through TinyTouch Manager when it is running, otherwise opens the device directly.

let usage = """
Cách dùng: tinytouch <lệnh> [tham số]

  status                         Xem chế độ, số vân tay, cảm biến, firmware
  mode hid|piv                   Chuyển chế độ hoạt động
  set-password <1-5>             Gán mật khẩu trên chip cho ngón 1–5 (hỏi mật khẩu)
  clear-password <1-5>           Xóa mật khẩu trên chip của ngón
  post-key <chuỗi>               Phím sau khi điền, vd: enter | enter,space | tab,enter | none
  post-key-delay <ms>            Thời gian chờ giữa các phím kết thúc
  wake-delay <ms>                Thời gian chờ khi đánh thức máy
  enroll <1-5> [2|6]             Đăng ký vân tay (mặc định 6 lần chạm)
  passkeys                       Liệt kê Passkeys FIDO2 (cần chạm vân tay)
  hosts                          Liệt kê máy đã ghép đôi
  ports                          Liệt kê cổng serial
  raw <LỆNH…>                    Gửi lệnh thô tới thiết bị

Mỗi thay đổi cấu hình cần chạm vân tay chủ sở hữu.
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("tinytouch: \(message)\n".utf8))
    exit(1)
}

func readSecret(_ prompt: String) -> String {
    var buffer = [CChar](repeating: 0, count: 512)
    guard let result = readpassphrase(prompt, &buffer, buffer.count, 0) else { fail("không đọc được mật khẩu") }
    return String(cString: result)
}

func makeChannel() throws -> (CommandChannel, DeviceClient?) {
    if let socket = ControlSocketClient() { return (socket, nil) }
    guard let port = DeviceDiscovery.tinyTouchPort() else {
        throw DeviceClientError.rejected("không tìm thấy tinyTouch. Hãy cắm thiết bị.")
    }
    let client = DeviceClient(port: port)
    try client.open()
    return (client, client)
}

func printPrompt(_ line: String) {
    guard let prompt = TouchPrompt.parse(line) else { return }
    let step = prompt.total.map { " (\(prompt.step)/\($0))" } ?? ""
    print(prompt.kind == .lift ? "↑ Nhấc ngón tay ra\(step)" : "👆 Chạm ngón tay vào cảm biến\(step)")
}

func run(_ args: [String]) async throws {
    guard let command = args.first else { print(usage); return }
    if command == "help" || command == "-h" || command == "--help" { print(usage); return }
    if command == "ports" {
        for port in DeviceDiscovery.ports() {
            print("\(port.path)\t\(port.productName ?? "?")\t\(port.serialNumber ?? "")")
        }
        return
    }

    let (channel, direct) = try makeChannel()
    defer { direct?.close() }
    let service = DeviceService(channel: channel)
    let status = try await service.status()
    let fingers = status.fingerprints

    func slotArgument() throws -> Int {
        guard args.count >= 2, let slot = Int(args[1]), (1...5).contains(slot) else {
            throw DeviceClientError.rejected("cần số ngón từ 1 đến 5")
        }
        return slot
    }
    func intArgument() throws -> Int {
        guard args.count >= 2, let value = Int(args[1]), value >= 0 else { throw DeviceClientError.rejected("cần một số ms") }
        return value
    }
    if fingers > 0, !["status", "hosts", "raw"].contains(command) {
        print("Chạm vân tay chủ sở hữu để xác nhận…")
    }

    switch command {
    case "status":
        let snapshot = try await service.snapshot()
        let s = snapshot.status
        print("Chế độ:            \(s.mode?.title ?? "?")")
        print("Vân tay đã lưu:    \(s.fingerprints)")
        print("Cảm biến:          \(s.sensor)")
        print("Firmware:          \(s.firmware) v\(s.firmwareVersion) (protocol \(s.protocolVersion))")
        print("Phím sau khi điền: \(s.postKey)  (chờ \(s.postKeyDelay) ms, đánh thức \(s.wakeDelay) ms)")
        print("Máy đã ghép đôi:   \(s.hidHosts)")
        for slot in snapshot.slots {
            print("  Ngón \(slot.id) \(slot.name.padding(toLength: 11, withPad: " ", startingAt: 0)) vân tay: \(slot.enrolled ? "✓" : "–")  mật khẩu chip: \(slot.hasChipPassword ? "✓" : "–")")
        }
        if snapshot.passkeysLocked { print("Passkeys:          🔒 (dùng `tinytouch passkeys`)") }
        else if let list = snapshot.passkeys { print("Passkeys:          \(list.count)") }
    case "mode":
        guard args.count >= 2, let mode = DeviceMode(rawValue: args[1].lowercased()) else {
            throw DeviceClientError.rejected("dùng: tinytouch mode hid|piv")
        }
        try await service.setMode(mode, fingerprints: fingers, onPrompt: printPrompt)
        print("✓ Đã chuyển sang \(mode.rawValue.uppercased())")
    case "set-password":
        let slot = try slotArgument()
        let first = readSecret("Mật khẩu cho ngón \(slot): ")
        guard !first.isEmpty, readSecret("Nhập lại: ") == first else { throw DeviceClientError.rejected("mật khẩu trống hoặc không khớp") }
        if fingers > 0 { print("Chạm vân tay chủ sở hữu để xác nhận…") }
        try await service.setChipPassword(slot: slot, password: first, fingerprints: fingers, onPrompt: printPrompt)
        print("✓ Đã lưu mật khẩu ngón \(slot) vào chip")
    case "clear-password":
        let slot = try slotArgument()
        try await service.clearChipPassword(slot: slot, fingerprints: fingers, onPrompt: printPrompt)
        print("✓ Đã xóa mật khẩu ngón \(slot)")
    case "post-key":
        guard args.count >= 2 else { throw DeviceClientError.rejected("dùng: tinytouch post-key enter,space") }
        let sequence = args[1...].joined(separator: ",")
        try await service.setPostKey(sequence, fingerprints: fingers, onPrompt: printPrompt)
        print("✓ Phím sau khi điền: \(PostKey.normalize(sequence) ?? sequence)")
    case "post-key-delay":
        let ms = try intArgument()
        try await service.setPostKeyDelay(ms, fingerprints: fingers, onPrompt: printPrompt)
        print("✓ Chờ giữa các phím: \(ms) ms")
    case "wake-delay":
        let ms = try intArgument()
        try await service.setWakeDelay(ms, fingerprints: fingers, onPrompt: printPrompt)
        print("✓ Chờ khi đánh thức: \(ms) ms")
    case "enroll":
        let slot = try slotArgument()
        let touches = args.count >= 3 ? (Int(args[2]) ?? 6) : 6
        guard touches == 2 || touches == 6 else { throw DeviceClientError.rejected("số lần chạm là 2 hoặc 6") }
        try await service.enroll(slot: slot, touches: touches, fingerprints: fingers, onPrompt: printPrompt)
        print("✓ Đã đăng ký vân tay ngón \(slot)")
    case "passkeys":
        let list = try await service.unlockedPasskeys(fingerprints: fingers, onPrompt: printPrompt)
        if list.isEmpty { print("Chưa có Passkey nào.") }
        for item in list {
            print("\(item.rpId ?? "?")\t\(item.user ?? "?")\tdùng \(item.counter ?? 0) lần\t\(item.id)")
        }
    case "hosts":
        guard let ids = try await service.pairedHostIDs() else { throw DeviceClientError.rejected("firmware không hỗ trợ HID_KEY_IDS") }
        print(ids.isEmpty ? "Chưa có máy nào ghép đôi." : ids.joined(separator: "\n"))
    case "raw":
        guard args.count >= 2 else { throw DeviceClientError.rejected("dùng: tinytouch raw STATUS") }
        for line in try await service.run(args[1...].joined(separator: " "), timeout: 20) { print(line) }
    default:
        print(usage)
        exit(2)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let done = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        try await run(arguments)
    } catch {
        FileHandle.standardError.write(Data("tinytouch: \(error.localizedDescription)\n".utf8))
        exitCode = 1
    }
    done.signal()
}
done.wait()
exit(exitCode)
