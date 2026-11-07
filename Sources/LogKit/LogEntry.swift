import Foundation

/// How serious a line is. Every log format maps its own words onto these six.
public enum LogLevel: Int, CaseIterable, Comparable, Sendable, Codable {
    case trace, debug, info, warning, error, critical

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The word LogKit writes for this level, and shows when a log has none of its own.
    public var code: String {
        switch self {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        case .critical: "ALERT"
        }
    }

    /// Reads the words logs commonly use: TRACE, DEBUG, INFO, NOTICE, WARN,
    /// WARNING, ERROR, ERR, FATAL, CRITICAL, ALERT, and a few more.
    public init?(code: some StringProtocol) {
        switch code.uppercased() {
        case "TRACE", "VERBOSE", "VERB": self = .trace
        case "DEBUG", "DBG": self = .debug
        case "INFO", "NOTICE", "LOG", "DEFAULT": self = .info
        case "WARN", "WARNING": self = .warning
        case "ERROR", "ERR": self = .error
        case "ALERT", "CRITICAL", "CRIT", "FATAL", "FAULT", "EMERGENCY": self = .critical
        default: return nil
        }
    }

    /// Warnings and worse: what the problem chips and highlights count.
    public var isProblem: Bool { self >= .warning }
}

/// One message. Continuation lines (stack traces) are part of `message`.
public struct LogEntry: Identifiable, Hashable, Sendable {
    /// Position in the log; for a `LogStore`, grows for the whole session.
    public var id: Int
    /// As the log shows it ("14:05:09"), or nil when the log has no times.
    public var time: String?
    public var level: LogLevel
    /// The log's own word for the level ("WARN", "E"), shown as is.
    public var code: String?
    /// What wrote it: the app, a part of it, a mod, an emulator.
    public var source: String
    public var message: String
    /// The same message again right after: shown once, "×12".
    public var repeats: Int
    /// What's behind the message (the exact command, value or output): not in
    /// the row, but searched, copied, and shown by the app's entry inspector.
    public var detail: String?

    public init(id: Int, time: String? = nil, level: LogLevel, code: String? = nil,
                source: String, message: String, repeats: Int = 1, detail: String? = nil) {
        self.id = id
        self.time = time
        self.level = level
        self.code = code
        self.source = source
        self.message = message
        self.repeats = repeats
        self.detail = detail
    }

    public var isProblem: Bool { level.isProblem }
    public var displayCode: String { code ?? level.code }
}

/// A fact about the session for the viewer's header: "SMAPI 4.1.10", "macOS 26.1".
public struct LogMetadata: Hashable, Sendable {
    public var label: String
    /// An SF Symbol name.
    public var symbol: String

    public init(_ label: String, symbol: String) {
        self.label = label
        self.symbol = symbol
    }
}

/// A finding in plain words, shown above the messages: "Dolphin crashed
/// while starting", "3 mod updates available". The app adds its actions.
public struct LogInsight: Identifiable, Hashable, Sendable {
    public var id: String
    public var level: LogLevel
    public var title: String
    public var detail: String
    /// The source it's about; the viewer offers "Show Messages" for it.
    public var source: String?

    public init(id: String, level: LogLevel, title: String, detail: String = "", source: String? = nil) {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
        self.source = source
    }
}

/// A parsed log.
public struct LogDocument: Sendable {
    public var entries: [LogEntry]
    public var metadata: [LogMetadata]
    public var insights: [LogInsight]
    /// True when only the end of a big file was read.
    public var truncated: Bool

    public init(entries: [LogEntry] = [], metadata: [LogMetadata] = [], insights: [LogInsight] = [], truncated: Bool = false) {
        self.entries = entries
        self.metadata = metadata
        self.insights = insights
        self.truncated = truncated
    }

    /// Identifies one session: apps that start a fresh log on every launch
    /// change its first line, so a Clear made in an earlier session no longer applies.
    public var sessionKey: String? {
        entries.first.map { "\($0.time ?? "") \($0.message)" }
    }

    /// The whole log as text, the way it would be pasted into a bug report.
    public static func text(of entries: [LogEntry]) -> String {
        entries.map { entry in
            var line = ""
            if let time = entry.time { line += time + " " }
            line += entry.displayCode
            if !entry.source.isEmpty { line += " [\(entry.source)]" }
            line += " " + entry.message
            if entry.repeats > 1 { line += " (×\(entry.repeats))" }
            if let detail = entry.detail, !detail.isEmpty {
                line += "\n" + detail.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
            }
            return line
        }
        .joined(separator: "\n")
    }
}
