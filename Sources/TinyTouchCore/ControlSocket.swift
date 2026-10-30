import Foundation

/// Local Unix socket that lets the `tinytouch` CLI reuse the app's serial connection.
///
/// Request: one line `<timeoutMs> <command>`. Response: every reply line, one per line,
/// then the connection closes. Errors come back as `ERR CLIENT <message>`.
public enum ControlSocket {
    public static var path: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TinyTouchManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("control.sock").path
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}

public final class ControlSocketServer {
    public typealias Handler = (_ command: String, _ timeout: TimeInterval, _ emit: @escaping (String) -> Void) async -> Void

    private let path: String
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "tinytouch.control")

    public init(path: String = ControlSocket.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = ControlSocket.makeAddress(path) else { throw SerialError.configure(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            throw SerialError.configure(code)
        }
        chmod(path, 0o600)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    public func stop() {
        source?.cancel()
        source = nil
        unlink(path)
    }

    private func acceptClient() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let handler = handler
        Thread.detachNewThread {
            guard let request = Self.readLine(client) else { close(client); return }
            let parts = request.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let ms = Double(parts[0]) else {
                Self.writeLine(client, "ERR CLIENT bad request")
                close(client)
                return
            }
            let done = DispatchSemaphore(value: 0)
            Task {
                await handler(parts[1], ms / 1000) { Self.writeLine(client, $0) }
                done.signal()
            }
            done.wait()
            close(client)
        }
    }

    static func readLine(_ fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return String(decoding: data, as: UTF8.self) }
            data.append(byte)
            if data.count > 4096 { return nil }
        }
        return nil
    }

    static func writeLine(_ fd: Int32, _ line: String) {
        let data = Array((line + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// CLI side: forwards each command to the running app.
public final class ControlSocketClient: CommandChannel {
    private let path: String

    public init?(path: String = ControlSocket.path) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        self.path = path
        guard (try? connect()).map({ close($0); return true }) == true else { return nil }
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = ControlSocket.makeAddress(path) else { throw SerialError.configure(errno) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw SerialError.open(path, code)
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    public func send(_ command: String, timeout: TimeInterval, onLine: ((String) -> Void)?) async throws -> [String] {
        let fd = try connect()
        defer { close(fd) }
        ControlSocketServer.writeLine(fd, "\(Int(timeout * 1000)) \(command)")
        var lines: [String] = []
        while let line = ControlSocketServer.readLine(fd) {
            if line.hasPrefix("ERR CLIENT ") { throw DeviceClientError.rejected(String(line.dropFirst(11))) }
            lines.append(line)
            onLine?(line)
        }
        if lines.isEmpty { throw DeviceClientError.timeout(DeviceClient.redact(command)) }
        return lines
    }
}
