import Foundation

public enum SerialError: LocalizedError {
    case open(String, Int32)
    case busy(String)
    case configure(Int32)
    case notOpen
    case write(Int32)

    public var errorDescription: String? {
        switch self {
        case let .open(path, code): return "Không mở được \(path): \(String(cString: strerror(code)))"
        case let .busy(path): return "Cổng \(path) đang được ứng dụng khác sử dụng (có thể là tinyTouch.app cũ). Hãy thoát ứng dụng đó."
        case let .configure(code): return "Không cấu hình được cổng serial: \(String(cString: strerror(code)))"
        case .notOpen: return "Cổng serial chưa mở."
        case let .write(code): return "Lỗi ghi serial: \(String(cString: strerror(code)))"
        }
    }
}

/// Raw POSIX serial port (115200 8N1) with exclusive access and callback-based reads.
public final class SerialPort {
    public let path: String
    public var onData: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue: DispatchQueue

    // <sys/ttycom.h>: _IO('t', 13) and _IO('t', 121)
    private static let TIOCEXCL: UInt = 0x2000_740D
    private static let TIOCSDTR: UInt = 0x2000_7479

    public init(path: String, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
    }

    public var isOpen: Bool { fd >= 0 }

    public func open() throws {
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            let code = errno
            throw code == EBUSY ? SerialError.busy(path) : SerialError.open(path, code)
        }
        if ioctl(handle, SerialPort.TIOCEXCL) == -1 {
            let code = errno
            Darwin.close(handle)
            throw code == EBUSY ? SerialError.busy(path) : SerialError.configure(code)
        }
        var settings = termios()
        if tcgetattr(handle, &settings) != 0 {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configure(code)
        }
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(B115200))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        if tcsetattr(handle, TCSANOW, &settings) != 0 {
            let code = errno
            Darwin.close(handle)
            throw SerialError.configure(code)
        }
        _ = ioctl(handle, SerialPort.TIOCSDTR)
        tcflush(handle, TCIOFLUSH)
        fd = handle

        let source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(handle) }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count > 0 {
            onData?(Data(buffer[0..<count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            let error: Error? = count == 0 ? nil : SerialError.open(path, errno)
            close()
            onClose?(error)
        }
    }

    public func write(_ data: Data) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        var offset = 0
        let deadline = Date().addingTimeInterval(2)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.write(fd, base + offset, data.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EINTR, Date() < deadline {
                    usleep(2000)
                } else {
                    throw SerialError.write(errno)
                }
            }
        }
    }

    public func close() {
        guard fd >= 0 else { return }
        fd = -1
        source?.cancel()
        source = nil
    }
}
