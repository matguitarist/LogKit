import Foundation
import Testing
@testable import LogKit

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

    @Test("Problems: worst first, then most frequent; counts include repeats")
    func summary() {
        let summary = LogSummary(entries: sample)
        #expect(summary.counts[.warning] == 2)
        #expect(summary.problems.map(\.source) == ["RetroArch", "Dolphin"])
        #expect(summary.problems[1].count == 2)
        #expect(summary.sources.first == "App")
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
}
