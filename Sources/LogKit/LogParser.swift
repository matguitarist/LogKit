import Foundation

/// Turns a log's text into entries. Each app writes one for the log it shows
/// (SMAPI, the Script Extender, an emulator), or uses one of the built-in ones.
public protocol LogParser: Sendable {
    func parse(_ text: String) -> LogDocument
}

/// What a line-based parser finds on a line that starts an entry.
public struct ParsedLine: Sendable, Equatable {
    public var time: String?
    public var level: LogLevel
    public var code: String?
    public var source: String
    public var message: String

    public init(time: String? = nil, level: LogLevel, code: String? = nil, source: String = "", message: String) {
        self.time = time
        self.level = level
        self.code = code
        self.source = source
        self.message = message
    }
}

/// The parser most logs need: `parseLine` reads a line that starts an entry
/// and returns nil for one that continues the previous entry (stack traces,
/// multi-line messages). `finish` adds metadata and insights at the end.
public struct LineLogParser: LogParser {
    private let parseLine: @Sendable (Substring) -> ParsedLine?
    private let finish: @Sendable (inout LogDocument) -> Void

    public init(parseLine: @escaping @Sendable (Substring) -> ParsedLine?,
                finish: @escaping @Sendable (inout LogDocument) -> Void = { _ in }) {
        self.parseLine = parseLine
        self.finish = finish
    }

    public func parse(_ text: String) -> LogDocument {
        var entries: [LogEntry] = []
        entries.reserveCapacity(text.utf8.count / 80)
        LogLines.forEach(in: text) { line in
            if let parsed = parseLine(line) {
                entries.append(LogEntry(id: entries.count, time: parsed.time, level: parsed.level, code: parsed.code,
                                        source: parsed.source, message: parsed.message))
            } else if !line.isEmpty {
                if entries.isEmpty {
                    // Text before the first entry (a banner): kept as a plain message.
                    entries.append(LogEntry(id: 0, level: .info, source: "", message: String(line)))
                } else {
                    entries[entries.count - 1].message += "\n" + String(line)
                }
            }
        }
        var document = LogDocument(entries: entries)
        finish(&document)
        return document
    }
}

/// Splits text into lines without a Regex per line (seconds on a 50,000-line
/// log) and with CRLF endings (Swift treats "\r\n" as one Character, so
/// splitting on "\n" misses them).
public enum LogLines {
    public static func forEach(in text: String, _ body: (Substring) -> Void) {
        let utf8 = text.utf8
        var start = utf8.startIndex
        var index = start
        func emit(upTo end: String.Index) {
            var end = end
            if end > start, utf8[utf8.index(before: end)] == 0x0D { end = utf8.index(before: end) }
            body(text[start..<end])
        }
        while index != utf8.endIndex {
            if utf8[index] == 0x0A {
                emit(upTo: index)
                start = utf8.index(after: index)
            }
            index = utf8.index(after: index)
        }
        if start != utf8.endIndex { emit(upTo: utf8.endIndex) }
    }
}

/// "[14:05:09 WARN Source] message", the format SMAPI and many game tools
/// use. The level word can be padded ("[14:05:09 INFO  game]").
public struct BracketLogParser: LogParser {
    private let finish: @Sendable (inout LogDocument) -> Void

    public init(finish: @escaping @Sendable (inout LogDocument) -> Void = { _ in }) {
        self.finish = finish
    }

    public func parse(_ text: String) -> LogDocument {
        LineLogParser(parseLine: Self.parseLine, finish: finish).parse(text)
    }

    public static func parseLine(_ line: Substring) -> ParsedLine? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let inside = line[line.index(after: line.startIndex)..<close]
        let parts = inside.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let time = parts[0]
        guard time.first?.isNumber == true, time.contains(":"),
              time.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." }),
              let level = LogLevel(code: parts[1])
        else { return nil }
        var message = line[line.index(after: close)...]
        if message.first == " " { message = message.dropFirst() }
        return ParsedLine(time: String(time), level: level, code: String(parts[1]),
                          source: parts[2].trimmingCharacters(in: .whitespaces), message: String(message))
    }
}

/// The format `LogStore` writes: "2026-11-06T22:14:05-05:00 WARN [Source] message".
/// Times are local with their offset, so the viewer shows "22:14:05" as is.
public enum LogKitFormat {
    public static let parser = LineLogParser(parseLine: parseLine)

    public static func parseLine(_ line: Substring) -> ParsedLine? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count >= 19, parts[0].dropFirst(10).first == "T",
              let level = LogLevel(code: parts[1])
        else { return nil }
        let time = String(parts[0].dropFirst(11).prefix(8))
        var rest = parts[2]
        var source = ""
        if rest.first == "[", let close = rest.firstIndex(of: "]") {
            source = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return ParsedLine(time: time, level: level, code: String(parts[1]), source: source, message: String(rest))
    }

    /// One line (or more, for a multi-line message) in this format.
    public static func line(date: Date, level: LogLevel, source: String, message: String, timeZone: TimeZone = .current) -> String {
        let source = source.isEmpty ? "" : "[\(source)] "
        return "\(timestamp(date, timeZone: timeZone)) \(level.code) \(source)\(message)"
    }

    /// "2026-11-06T22:14:05-05:00", built by hand: DateFormatter isn't Sendable.
    public static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 3600, minutes = abs(offset) % 3600 / 60
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
                      sign, hours, minutes)
    }
}
