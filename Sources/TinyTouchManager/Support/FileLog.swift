import Foundation

/// Appends activity (never secrets: commands are redacted, raw TX/RX is skipped) to
/// ~/Library/Logs/TinyTouchManager.log, rotating at 1 MB.
final class FileLog {
    static let shared = FileLog()
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TinyTouchManager.log")

    private let queue = DispatchQueue(label: "tinytouch.filelog")
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    func write(_ entry: LogEntry) {
        let line = "\(formatter.string(from: entry.date)) [\(entry.kind)] \(entry.message)\n"
        queue.async {
            let url = Self.url
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("1"))
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
