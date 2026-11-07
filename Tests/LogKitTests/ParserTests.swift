import Foundation
import Testing
@testable import LogKit

@Suite("Parsers")
struct ParserTests {
    @Test("Bracket lines: time, padded level, source, message; continuation lines join the entry")
    func bracketLines() {
        let text = """
        [14:05:09 INFO  SMAPI] SMAPI 4.1.10 with Stardew Valley 1.6.15 on macOS
        [14:05:10 WARN  Content Patcher] Missing token
        at Something.Run()
        [14:05:11 ERROR game] Crash
        """
        let entries = BracketLogParser().parse(text).entries
        #expect(entries.count == 3)
        #expect(entries[0] == LogEntry(id: 0, time: "14:05:09", level: .info, code: "INFO", source: "SMAPI",
                                       message: "SMAPI 4.1.10 with Stardew Valley 1.6.15 on macOS"))
        #expect(entries[1].source == "Content Patcher")
        #expect(entries[1].level == .warning)
        #expect(entries[1].message == "Missing token\nat Something.Run()")
        #expect(entries[2].level == .error)
    }

    @Test("CRLF endings are split like LF")
    func crlf() {
        let entries = BracketLogParser().parse("[01:02:03 INFO A] one\r\n[01:02:04 DEBUG B] two\r\n").entries
        #expect(entries.map(\.message) == ["one", "two"])
    }

    @Test("Text before the first entry is kept as a plain message")
    func banner() {
        let entries = BracketLogParser().parse("Log started\n[01:02:03 INFO A] one").entries
        #expect(entries.map(\.message) == ["Log started", "one"])
        #expect(entries[0].source == "")
    }

    @Test("Lines that only look like entries continue the previous one")
    func notEntries() {
        #expect(BracketLogParser.parseLine("[not a time INFO A] x") == nil)
        #expect(BracketLogParser.parseLine("[01:02:03 NOPE A] x") == nil)
        #expect(BracketLogParser.parseLine("plain text") == nil)
    }

    @Test("Common level words map onto the six levels")
    func levelWords() {
        #expect(LogLevel(code: "warning") == .warning)
        #expect(LogLevel(code: "ERR") == .error)
        #expect(LogLevel(code: "Fatal") == .critical)
        #expect(LogLevel(code: "NOTICE") == .info)
        #expect(LogLevel(code: "chatty") == nil)
    }

    @Test("LogKit's own format reads back what it writes")
    func ownFormatRoundTrip() throws {
        let zone = try #require(TimeZone(secondsFromGMT: -5 * 3600))
        let date = Date(timeIntervalSince1970: 1_793_934_845)   // 2026-11-06T03:14:05Z
        let line = LogKitFormat.line(date: date, level: .warning, source: "Install", message: "Patch failed", timeZone: zone)
        #expect(line == "2026-11-05T22:14:05-05:00 WARN [Install] Patch failed")
        let parsed = try #require(LogKitFormat.parseLine(Substring(line)))
        #expect(parsed == ParsedLine(time: "22:14:05", level: .warning, code: "WARN", source: "Install", message: "Patch failed"))
    }

    @Test("LogKit's format without a source")
    func ownFormatNoSource() throws {
        let parsed = try #require(LogKitFormat.parseLine("2026-11-05T22:14:05+01:00 INFO started"))
        #expect(parsed.source == "")
        #expect(parsed.message == "started")
    }

    @Test("A custom line parser and its finish step")
    func customParser() {
        let parser = LineLogParser(parseLine: { line in
            guard line.hasPrefix("E ") || line.hasPrefix("I ") else { return nil }
            return ParsedLine(level: line.hasPrefix("E") ? .error : .info, code: String(line.prefix(1)),
                              source: "VM", message: String(line.dropFirst(2)))
        }, finish: { document in
            document.metadata = [LogMetadata("\(document.entries.count) lines", symbol: "number")]
        })
        let document = parser.parse("I boot\nE oops\n")
        #expect(document.entries.map(\.displayCode) == ["I", "E"])
        #expect(document.metadata.first?.label == "2 lines")
    }
}
