import Foundation

/// What the viewer shows: levels, one source, a search, repeats folded.
public struct LogFilter: Hashable, Sendable {
    public var levels: Set<LogLevel>
    public var source: String?
    public var query: String
    /// Folds the same message logged again and again into one line, "×12".
    public var collapseRepeats: Bool

    public init(levels: Set<LogLevel> = Set(LogLevel.allCases).subtracting([.trace]),
                source: String? = nil, query: String = "", collapseRepeats: Bool = false) {
        self.levels = levels
        self.source = source
        self.query = query
        self.collapseRepeats = collapseRepeats
    }

    public func apply(to entries: [LogEntry]) -> [LogEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let shown = entries.filter { entry in
            levels.contains(entry.level)
                && (source == nil || entry.source == source)
                && (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query)
                    || entry.source.localizedCaseInsensitiveContains(query))
        }
        return collapseRepeats ? Self.collapsingRepeats(shown) : shown
    }

    /// Whether this filter hides messages `base` shows, by level, source or
    /// search. Hide Repeats doesn't count: it hides no message, it folds them.
    public func narrows(_ base: LogFilter) -> Bool {
        source != nil || !query.trimmingCharacters(in: .whitespaces).isEmpty || !base.levels.isSubset(of: levels)
    }

    /// `base`'s levels, any source, no search; Hide Repeats stays as it is.
    public func reset(to base: LogFilter) -> LogFilter {
        var filter = base
        filter.source = nil
        filter.query = ""
        filter.collapseRepeats = collapseRepeats
        return filter
    }

    /// Consecutive entries with the same level, source and message become one.
    public static func collapsingRepeats(_ entries: [LogEntry]) -> [LogEntry] {
        var result: [LogEntry] = []
        result.reserveCapacity(entries.count)
        for entry in entries {
            if let last = result.last, last.level == entry.level, last.source == entry.source, last.message == entry.message {
                result[result.count - 1].repeats += entry.repeats
            } else {
                result.append(entry)
            }
        }
        return result
    }
}

/// Counts and problems for the viewer's header, computed once per change of the log.
public struct LogSummary: Sendable {
    public struct Problem: Hashable, Sendable {
        public var source: String
        public var worst: LogLevel
        public var count: Int
    }

    public var counts: [LogLevel: Int]
    /// Warnings and worse grouped by source, worst and most frequent first.
    public var problems: [Problem]
    /// Every source, most messages first.
    public var sources: [String]

    public init(entries: [LogEntry]) {
        var counts: [LogLevel: Int] = [:]
        var problems: [String: (worst: LogLevel, count: Int)] = [:]
        var sources: [String: Int] = [:]
        for entry in entries {
            counts[entry.level, default: 0] += entry.repeats
            sources[entry.source, default: 0] += entry.repeats
            if entry.isProblem {
                let current = problems[entry.source] ?? (entry.level, 0)
                problems[entry.source] = (max(current.worst, entry.level), current.count + entry.repeats)
            }
        }
        self.counts = counts
        self.problems = problems
            .map { Problem(source: $0.key.isEmpty ? "—" : $0.key, worst: $0.value.worst, count: $0.value.count) }
            .sorted { ($0.worst, $0.count, $1.source) > ($1.worst, $1.count, $0.source) }
        self.sources = sources.filter { !$0.key.isEmpty }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }
}

/// "Clear": hides what was logged so far without touching the file. It
/// applies to the same file and session only, so a new session shows in full.
public struct ClearMark: Hashable, Sendable {
    public var file: URL?
    public var session: String?
    /// Entries hidden from a file's log.
    public var entryCount: Int
    /// For a `LogStore`: entries up to this id are hidden.
    public var lastID: Int?
    public var date: Date

    public init(file: URL? = nil, session: String? = nil, entryCount: Int = 0, lastID: Int? = nil, date: Date = .now) {
        self.file = file
        self.session = session
        self.entryCount = entryCount
        self.lastID = lastID
        self.date = date
    }

    /// The log without what the mark hides, or nil when the mark doesn't apply to it.
    public func apply(to document: LogDocument, file: URL?) -> LogDocument? {
        if let lastID {
            var cleared = document
            cleared.entries = document.entries.filter { $0.id > lastID }
            return cleared
        }
        guard self.file == file, session == document.sessionKey, entryCount <= document.entries.count else { return nil }
        var cleared = document
        cleared.entries = Array(document.entries.dropFirst(entryCount))
        return cleared
    }
}
