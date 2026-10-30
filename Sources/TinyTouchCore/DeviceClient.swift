import Foundation

public enum DeviceClientError: LocalizedError {
    case timeout(String)
    case closed
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case let .timeout(command): return "Thiết bị không phản hồi lệnh \(command) (hết thời gian chờ)."
        case .closed: return "Mất kết nối với thiết bị."
        case let .rejected(reply): return "Thiết bị từ chối: \(reply)"
        }
    }
}

/// Line-oriented command channel to the tinyTouch console.
///
/// Commands run one at a time. A command finishes at its first terminal line
/// (`OK …`, `ERR …`, JSON, `…_OK`, `…_FAIL`, `PONG`). Fingerprint events
/// (`EV …`, `EV2 …`) never count as replies and go to `onEvent`.
public final class DeviceClient {
    public let port: DevicePort
    public var onEvent: ((String) -> Void)?
    public var onUnsolicited: ((String) -> Void)?
    public var onTraffic: ((_ outgoing: Bool, _ line: String) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "tinytouch.device")
    private let serial: SerialPort
    private var buffer = Data()
    private var queued: [Pending] = []
    private var active: Pending?
    private var closed = false

    private final class Pending {
        let command: String
        let timeout: TimeInterval
        let onLine: ((String) -> Void)?
        let completion: (Result<[String], Error>) -> Void
        var lines: [String] = []
        var timer: DispatchWorkItem?

        init(command: String, timeout: TimeInterval, onLine: ((String) -> Void)?,
             completion: @escaping (Result<[String], Error>) -> Void) {
            self.command = command
            self.timeout = timeout
            self.onLine = onLine
            self.completion = completion
        }
    }

    public init(port: DevicePort) {
        self.port = port
        serial = SerialPort(path: port.path, queue: queue)
        serial.onData = { [weak self] in self?.receive($0) }
        serial.onClose = { [weak self] error in self?.handleClose(error) }
    }

    public func open() throws {
        try queue.sync { try serial.open() }
    }

    public func close() {
        queue.sync {
            serial.close()
            handleClose(nil)
        }
    }

    /// Sends a command and collects its reply lines.
    public func send(_ command: String, timeout: TimeInterval = 5, onLine: ((String) -> Void)? = nil) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let pending = Pending(command: command, timeout: timeout, onLine: onLine) {
                    continuation.resume(with: $0)
                }
                if self.closed {
                    pending.completion(.failure(DeviceClientError.closed))
                    return
                }
                self.queued.append(pending)
                self.startNext()
            }
        }
    }

    /// Writes a line that expects no reply (e.g. a `PW2` answer to a touch event).
    public func writeLine(_ line: String) {
        queue.async {
            try? self.serial.write(Data((line + "\n").utf8))
        }
    }

    private func startNext() {
        guard active == nil, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        active = next
        onTraffic?(true, Self.redact(next.command))
        do {
            try serial.write(Data((next.command + "\r\n").utf8))
        } catch {
            finish(.failure(error))
            return
        }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, let active = self.active, active === next else { return }
            if active.lines.isEmpty {
                self.finish(.failure(DeviceClientError.timeout(Self.redact(next.command))))
            } else {
                self.finish(.success(active.lines))
            }
        }
        next.timer = timer
        queue.asyncAfter(deadline: .now() + next.timeout, execute: timer)
    }

    private func finish(_ result: Result<[String], Error>) {
        guard let current = active else { return }
        current.timer?.cancel()
        active = nil
        current.completion(result)
        startNext()
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        if buffer.count > 16_384 { buffer.removeAll() }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { handle(line: line) }
        }
    }

    private func handle(line: String) {
        if line.hasPrefix("EV ") || line.hasPrefix("EV2 ") {
            onTraffic?(false, "EV… (sự kiện chạm vân tay)")
            onEvent?(line)
            return
        }
        onTraffic?(false, line)
        guard let current = active else {
            onUnsolicited?(line)
            return
        }
        current.lines.append(line)
        current.onLine?(line)
        if Self.isTerminal(line) { finish(.success(current.lines)) }
    }

    private func handleClose(_ error: Error?) {
        guard !closed else { return }
        closed = true
        let pending = (active.map { [$0] } ?? []) + queued
        active = nil
        queued.removeAll()
        for item in pending {
            item.timer?.cancel()
            item.completion(.failure(DeviceClientError.closed))
        }
        onClose?(error)
    }

    public static func isTerminal(_ line: String) -> Bool {
        line == "OK" || line == "ERR" || line.hasPrefix("OK ") || line.hasPrefix("ERR ")
            || line.hasPrefix("{") || line.hasSuffix("_OK") || line.hasSuffix("_FAIL")
            || line == "PONG" || line.hasPrefix("PONG ")
    }

    /// Hides secrets before a command reaches any log.
    public static func redact(_ command: String) -> String {
        let parts = command.split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "SET_SLOT_PASSWORD": return parts.prefix(2).joined(separator: " ") + " ••••••"
        case "HID_KEY_ADD": return parts.prefix(2).joined(separator: " ") + " ••••••"
        case "HID_KEY": return "HID_KEY ••••••"
        case "PW", "PW2": return "\(parts[0]) ••••••"
        default: return command
        }
    }
}
