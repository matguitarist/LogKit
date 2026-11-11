import Foundation
import Testing
@testable import LogKit
import LogKitUI

private func entry(_ id: Int, _ level: LogLevel, _ source: String, _ message: String) -> LogEntry {
    LogEntry(id: id, time: "00:00:0\(id % 10)", level: level, source: source, message: message)
}

private let sample: [LogEntry] = [
    entry(0, .info, "App", "started"),
    entry(1, .warning, "Dolphin", "slow shader"),
    entry(2, .warning, "Dolphin", "slow shader"),
    entry(3, .error, "RetroArch", "core missing"),
    entry(4, .debug, "App", "tick"),
    entry(5, .trace, "App", "detail"),
]

@Suite("Filter, summary, Clear")
struct FilterTests {
    @Test("Trace is hidden by default; levels, source and search combine")
    func filter() {
        #expect(LogFilter().apply(to: sample).map(\.id) == [0, 1, 2, 3, 4])
        #expect(LogFilter(levels: [.warning, .error]).apply(to: sample).map(\.id) == [1, 2, 3])
        #expect(LogFilter(source: "App").apply(to: sample).map(\.id) == [0, 4])
        #expect(LogFilter(query: "SHADER").apply(to: sample).map(\.id) == [1, 2])
        #expect(LogFilter(query: "retro").apply(to: sample).map(\.id) == [3])
    }

    @Test("Repeats fold into one line with a count")
    func repeats() {
        let shown = LogFilter(collapseRepeats: true).apply(to: sample)
        #expect(shown.map(\.id) == [0, 1, 3, 4])
        #expect(shown[1].repeats == 2)
    }

    @Test("With a repeat limit, Hide Repeats also hides a message below Warning logged too often, even between others")
    func repeatLimit() {
        var log: [LogEntry] = []
        for i in 0..<4 {
            log.append(entry(i * 3, .debug, "Lua", "polling"))
            log.append(entry(i * 3 + 1, .warning, "Lua", "polling"))
            log.append(entry(i * 3 + 2, .info, "App", "frame \(i)"))
        }
        // Debug "polling" 4 times; the Warning with the same text 4 times too.
        let levels = Set(LogLevel.allCases)
        var filter = LogFilter(levels: levels, collapseRepeats: true, repeatLimit: 3)
        let shown = filter.apply(to: log)
        #expect(!shown.contains { $0.level == .debug })               // hidden: logged 4 > 3 times
        #expect(shown.filter { $0.level == .warning }.count == 4)     // a warning always shows
        filter.repeatLimit = 4
        #expect(filter.apply(to: log).filter { $0.level == .debug }.count == 4)   // not more than 4
        filter.repeatLimit = 3
        filter.collapseRepeats = false
        #expect(filter.apply(to: log).count == log.count)             // only with Hide Repeats on
        // Show All Messages keeps the app's limit.
        #expect(LogFilter(source: "Lua").reset(to: LogFilter(repeatLimit: 50)).repeatLimit == 50)
    }

    @Test("Problems: worst first, then most frequent; counts include repeats")
    func summary() {
        let summary = LogSummary(entries: sample)
        #expect(summary.counts[.warning] == 2)
        #expect(summary.problems.map(\.source) == ["RetroArch", "Dolphin"])
        #expect(summary.problems[1].count == 2)
        #expect(summary.problemsHaveSources)
        #expect(!LogSummary(entries: [LogEntry(id: 0, level: .error, source: "", message: "x")]).problemsHaveSources)
        #expect(summary.sources.first == "App")
    }

    @Test("A filter narrows by level, source or search, not by folding repeats; reset goes back to the start")
    func narrowAndReset() {
        let start = LogFilter(levels: [.info, .warning, .error, .critical])
        var filter = start
        #expect(!filter.narrows(start))
        filter.collapseRepeats = true
        #expect(!filter.narrows(start))
        filter.levels.insert(.debug)
        #expect(!filter.narrows(start))   // shows more, hides nothing
        filter.levels.remove(.info)
        #expect(filter.narrows(start))
        filter = start
        filter.source = "Lua"
        #expect(filter.narrows(start))
        filter.source = nil
        filter.query = "  "
        #expect(!filter.narrows(start))
        filter.query = "Mods/MCM"
        filter.levels = [.error]
        filter.collapseRepeats = true
        let reset = filter.reset(to: start)
        #expect(reset.levels == start.levels && reset.source == nil && reset.query.isEmpty)
        #expect(reset.collapseRepeats)    // the person's choice stays
    }

    @Test("The source menu lists every source, most messages first, without a header's blank source")
    func sourceList() {
        let header = LogEntry(id: 100, level: .trace, source: "", message: "=== BG3SE-macOS v0.44.0 ===")
        let summary = LogSummary(entries: [header] + sample)
        #expect(summary.sources.first == "App")
        #expect(!summary.sources.contains(""))
        #expect(Set(summary.sources) == Set(sample.map(\.source)))
    }

    @Test("Clear hides what came before, only for the same file and session")
    func clearMark() throws {
        let url = URL(filePath: "/tmp/a.log")
        let document = LogDocument(entries: sample)
        let mark = ClearMark(file: url, session: document.sessionKey, entryCount: 4)
        #expect(try #require(mark.apply(to: document, file: url)).entries.map(\.id) == [4, 5])
        #expect(mark.apply(to: document, file: URL(filePath: "/tmp/b.log")) == nil)
        let newSession = LogDocument(entries: [entry(0, .info, "App", "started again")] + sample)
        #expect(mark.apply(to: newSession, file: url) == nil)
    }

    @Test("Clear for a store hides by id")
    func clearByID() throws {
        let mark = ClearMark(lastID: 2)
        #expect(try #require(mark.apply(to: LogDocument(entries: sample), file: nil)).entries.map(\.id) == [3, 4, 5])
    }

    @Test("Clear remembers when it happened, so the viewer can say \"Cleared at …\"")
    func clearDate() throws {
        let before = Date.now
        let mark = ClearMark(lastID: 2)
        #expect(mark.date >= before && mark.date <= .now)
        let earlier = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ClearMark(lastID: 2, date: earlier).date == earlier)
    }

    @Test("Text for a bug report")
    func text() {
        var repeated = sample[1]
        repeated.repeats = 3
        #expect(LogDocument.text(of: [repeated]) == "00:00:01 WARN [Dolphin] slow shader (×3)")
    }
}

@Suite("Files")
struct FileTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "LogKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("A big file is read from its end, without the cut first line")
    func tail() throws {
        let url = try temporaryFolder().appending(path: "big.log")
        let lines = (0..<1000).map { "[00:00:00 INFO A] line \($0)" }
        try lines.joined(separator: "\r\n").write(to: url, atomically: true, encoding: .utf8)
        let (text, truncated) = try LogFiles.readTail(of: url, maxBytes: 300)
        #expect(truncated)
        let entries = BracketLogParser().parse(text).entries
        #expect(entries.allSatisfy { $0.source == "A" })
        #expect(entries.last?.message == "line 999")

        let whole = try LogFiles.load(url, parser: BracketLogParser())
        #expect(!whole.truncated)
        #expect(whole.entries.count == 1000)
    }

    @Test("Sessions: newest first, filtered by prefix and extension")
    func sessions() throws {
        let folder = try temporaryFolder()
        let manager = FileManager.default
        for (index, name) in ["bg3se_1.log", "bg3se_2.log", "other.log", "notes.md"].enumerated() {
            let url = folder.appending(path: name)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + index))], ofItemAtPath: url.path(percentEncoded: false))
        }
        #expect(LogFiles.sessions(in: folder, prefix: "bg3se_").map(\.lastPathComponent) == ["bg3se_2.log", "bg3se_1.log"])
        #expect(LogFiles.sessions(in: folder).count == 3)
    }

    @Test("A link to the newest session (latest.log) changes date when the session writes, so follow live sees it")
    func linkDate() throws {
        let folder = try temporaryFolder()
        let manager = FileManager.default
        let session = folder.appending(path: "bg3se_1.log"), link = folder.appending(path: "latest.log")
        try "x".write(to: session, atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: link, withDestinationURL: session)
        let written = Date(timeIntervalSince1970: 2_000_000_000)
        try manager.setAttributes([.modificationDate: written], ofItemAtPath: session.path(percentEncoded: false))
        #expect(LogFiles.modificationDate(of: link) == written)
        #expect(LogFiles.modificationDate(of: folder.appending(path: "missing.log")) == nil)
    }
}

@Suite("LogStore")
struct StoreTests {
    @Test("Posts from any thread reach the store in order; repeats fold; the file has each line once")
    @MainActor
    func store() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "LogKitTests-\(UUID().uuidString)/App.log")
        let store = LogStore(fileURL: url)
        await Task.detached {
            store.post(.info, "started", source: "App")
            store.post(.warning, "slow", source: "Dolphin")
            store.post(.warning, "slow", source: "Dolphin")
        }.value
        for _ in 0..<50 where store.entries.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.entries.map(\.message) == ["started", "slow"])
        #expect(store.entries[1].repeats == 2)

        store.flushFile()
        let written = try LogFiles.load(url, parser: LogKitFormat.parser).entries
        #expect(written.map(\.message) == ["started", "slow"])
        #expect(written.map(\.source) == ["App", "Dolphin"])
    }

    @Test("The file rotates once it's too big")
    @MainActor
    func rotation() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "LogKitTests-\(UUID().uuidString)")
        let store = LogStore(fileURL: folder.appending(path: "App.log"), maxFileBytes: 200)
        for index in 0..<20 { store.post(.info, "message number \(index)", source: "App") }
        store.flushFile()
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "App.previous.log").path(percentEncoded: false)))
    }

    @Test("Memory keeps the newest entries only")
    @MainActor
    func limit() async throws {
        let store = LogStore(limit: 100)
        for index in 0..<250 { store.post(.info, "m\(index)", source: "App") }
        for _ in 0..<50 where store.entries.last?.message != "m249" { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.entries.count <= 100)
        #expect(store.entries.last?.message == "m249")
    }

    @Test("A line posted with its own time keeps it, its detail, and shows the date on another day")
    @MainActor
    func datedPost() async throws {
        let store = LogStore()
        let calendar = Calendar.current
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 11, minute: 43, second: 53))!
        store.post(.error, "exited", source: "web", date: earlier, detail: "code 137")
        store.post(.info, "now", source: "web", date: Date())
        for _ in 0..<50 where store.entries.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.entries.first?.time == "11-05 11:43:53")
        #expect(store.entries.first?.detail == "code 137")
        #expect(store.entries.last?.time?.count == 8)
    }

    @Test("The store's metadata and insights reach its document and the viewer")
    @MainActor
    func insights() async throws {
        let store = LogStore()
        store.metadata = [LogMetadata("nginx:1.27", symbol: "shippingbox")]
        store.insights = [LogInsight(id: "restarts", level: .warning, title: "Restarted 4 times")]
        store.post(.info, "up", source: "")
        for _ in 0..<50 where store.entries.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.document.insights.map(\.id) == ["restarts"])
        let model = LogViewerModel(store: store)
        #expect(model.document?.insights.count == 1)
        #expect(model.document?.metadata.first?.label == "nginx:1.27")
    }
}
