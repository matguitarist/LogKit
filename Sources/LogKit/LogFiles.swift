import Foundation

/// Reading log files: only their end when they're big, and the sessions a folder holds.
public enum LogFiles {
    /// The last `maxBytes` of a file, without the partial first line a cut leaves.
    /// `truncated` tells the viewer to say that earlier lines were left out.
    public static func readTail(of url: URL, maxBytes: Int = 8 << 20) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try handle.seek(toOffset: start)
        var text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        // By bytes: "\r\n" is one Character, so firstIndex(of: "\n") misses it.
        if start > 0, let newline = text.utf8.firstIndex(of: 0x0A) {
            text = String(text[text.utf8.index(after: newline)...])
        }
        return (text, start > 0)
    }

    /// Reads and parses a log file, or its end when it's bigger than `maxBytes`.
    public static func load(_ url: URL, parser: any LogParser, maxBytes: Int = 8 << 20) throws -> LogDocument {
        let (text, truncated) = try readTail(of: url, maxBytes: maxBytes)
        var document = parser.parse(text)
        document.truncated = truncated
        return document
    }

    public static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    /// The log files in a folder, newest first: one per session for apps
    /// that start a new file on every launch.
    public static func sessions(in folder: URL, extensions: Set<String> = ["log", "txt"], prefix: String? = nil) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .filter { prefix == nil || $0.lastPathComponent.hasPrefix(prefix!) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}
