import Foundation
import Observation

/// The app's own log: what it did, and what the tools it runs printed.
/// Post from any thread; the viewer shows it live. Kept in memory for this
/// session (the newest `limit` entries) and written to a file that survives
/// a crash and can go along with a bug report.
///
///     static let log = LogStore(fileURL: LogStore.defaultFileURL(app: "Attic"))
///     Self.log.post(.error, "Dolphin quit with code 6", source: "Dolphin")
@Observable
@MainActor
public final class LogStore {
    public private(set) var entries: [LogEntry] = []
    /// Facts for the viewer's header ("nginx:1.27", "Up 3 hours").
    public var metadata: [LogMetadata] = []
    /// Findings in plain words, shown above the messages.
    public var insights: [LogInsight] = []
    public nonisolated let fileURL: URL?
    public nonisolated let limit: Int

    private var nextID = 0
    private nonisolated let writer: LogFileWriter?
    private nonisolated let inbox = LogInbox()

    /// - Parameters:
    ///   - fileURL: where lines are written, or nil for memory only. Once the
    ///     file passes `maxFileBytes` it becomes `<name>.previous.<ext>` and a new one starts.
    ///   - limit: entries kept in memory; older ones stay in the file only.
    public nonisolated init(fileURL: URL? = nil, maxFileBytes: Int = 5_000_000, limit: Int = 20_000) {
        self.fileURL = fileURL
        self.limit = limit
        writer = fileURL.map { LogFileWriter(url: $0, maxBytes: maxFileBytes) }
    }

    /// ~/Library/Logs/<app>/<app>.log, where Console.app also finds it.
    public nonisolated static func defaultFileURL(app: String) -> URL {
        URL.libraryDirectory.appending(path: "Logs/\(app)/\(app).log")
    }

    /// Logs from anywhere: the app's code, a background task, a tool's output handler.
    /// Lines arrive in the viewer in batches, so a tool printing hundreds of lines doesn't stall it.
    public nonisolated func post(_ level: LogLevel, _ message: String, source: String) {
        post(level, message, source: source, date: Date())
    }

    /// Logs a line that happened at `date`, for lines read from elsewhere with
    /// their own time (a container, a server). Lines from another day show
    /// their date too ("11-05 11:43:53"). `detail` is what's behind the
    /// message, shown by the entry inspector.
    public nonisolated func post(_ level: LogLevel, _ message: String, source: String, date: Date, detail: String? = nil) {
        writer?.write(date: date, level: level, source: source, message: message)
        if inbox.add(LogInbox.Item(date: date, level: level, source: source, message: message, detail: detail)) {
            Task { @MainActor in self.flush() }
        }
    }

    /// Empties the viewer's copy; the file keeps everything.
    public func clearMemory() {
        entries.removeAll()
    }

    public var document: LogDocument { LogDocument(entries: entries, metadata: metadata, insights: insights) }

    private func flush() {
        let items = inbox.take()
        guard !items.isEmpty else { return }
        var updated = entries
        for item in items {
            if let last = updated.last, last.level == item.level, last.source == item.source,
               last.message == item.message, last.detail == item.detail {
                updated[updated.count - 1].repeats += 1
            } else {
                nextID += 1
                updated.append(LogEntry(id: nextID, time: Self.clockTime(item.date), level: item.level,
                                        source: item.source, message: item.message, detail: item.detail))
            }
        }
        if updated.count > limit { updated.removeFirst(updated.count - limit + limit / 10) }
        entries = updated
    }

    /// "22:14:05", or "11-05 22:14:05" on another day: quick, and the same
    /// in every locale like the log file.
    nonisolated static func clockTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let c = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        let time = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        guard !calendar.isDate(date, inSameDayAs: now) else { return time }
        return String(format: "%02d-%02d ", c.month ?? 0, c.day ?? 0) + time
    }
}

/// Lines posted from any thread wait here until the main actor takes them.
final class LogInbox: @unchecked Sendable {
    struct Item: Sendable {
        let date: Date
        let level: LogLevel
        let source: String
        let message: String
        var detail: String? = nil
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var flushScheduled = false

    /// True when the caller must schedule a flush.
    func add(_ item: Item) -> Bool {
        lock.withLock {
            items.append(item)
            if flushScheduled { return false }
            flushScheduled = true
            return true
        }
    }

    func take() -> [Item] {
        lock.withLock {
            defer { items.removeAll(); flushScheduled = false }
            return items
        }
    }
}

/// Appends lines on its own queue and rotates the file when it grows too big.
/// The same line from the same source right after is written once.
final class LogFileWriter: @unchecked Sendable {
    private let url: URL
    private let previousURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "LogKit.LogFileWriter", qos: .utility)
    private var handle: FileHandle?
    private var size = 0
    private var lastLines: [String: String] = [:]

    init(url: URL, maxBytes: Int) {
        self.url = url
        self.maxBytes = maxBytes
        let name = url.deletingPathExtension().lastPathComponent
        previousURL = url.deletingLastPathComponent().appending(path: "\(name).previous.\(url.pathExtension.isEmpty ? "log" : url.pathExtension)")
    }

    func write(date: Date, level: LogLevel, source: String, message: String) {
        queue.async { [self] in
            guard lastLines[source] != message else { return }
            lastLines[source] = message
            let data = Data((LogKitFormat.line(date: date, level: level, source: source, message: message) + "\n").utf8)
            if handle == nil { open() }
            if size + data.count > maxBytes { rotate() }
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
                size += data.count
            } catch {
                self.handle = nil
            }
        }
    }

    /// Waits until every line posted so far is on disk (tests, and before quitting).
    func sync() { queue.sync {} }

    private func open() {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path(percentEncoded: false)) {
            manager.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let manager = FileManager.default
        try? manager.removeItem(at: previousURL)
        try? manager.moveItem(at: url, to: previousURL)
        open()
    }
}

extension LogStore {
    /// Waits until every line posted so far is in the file.
    public nonisolated func flushFile() { writer?.sync() }
}
