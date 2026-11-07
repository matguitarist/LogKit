import Foundation
import Testing
@testable import LogKitUI

@Suite("Viewer model")
@MainActor
struct ViewerModelTests {
    @Test("A store with nothing logged yet has no document, so the viewer shows the app's empty state")
    func emptyStore() async throws {
        let store = LogStore()
        let model = LogViewerModel(store: store)
        #expect(model.document == nil)
        store.post(.info, "started", source: "App")
        for _ in 0..<50 where store.entries.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.document?.entries.map(\.message) == ["started"])
        // After Clear the log is there, only emptied: the viewer says "Log Cleared".
        model.clear()
        #expect(model.document?.entries.isEmpty == true)
    }

    @Test("Newest first shows the latest message at the top")
    func newestFirst() async throws {
        let store = LogStore()
        let model = LogViewerModel(store: store)
        store.post(.info, "first", source: "App")
        store.post(.info, "second", source: "App")
        for _ in 0..<50 where store.entries.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.shownEntries.map(\.message) == ["first", "second"])
        model.newestFirst = true
        #expect(model.shownEntries.map(\.message) == ["second", "first"])
    }
}

@Suite("Entry details")
@MainActor
struct EntryDetailTests {
    let entries = [
        LogEntry(id: 0, time: "14:05:09", level: .info, source: "Preferences", message: "Set com.apple.dock autohide to true",
                 detail: "defaults write com.apple.dock \"autohide\" -bool true"),
        LogEntry(id: 1, time: "14:05:10", level: .error, source: "Commands", message: "Command failed"),
    ]

    @Test("Search finds a message by what's behind it")
    func search() {
        #expect(LogFilter(query: "defaults write").apply(to: entries).map(\.id) == [0])
    }

    @Test("Copy puts the detail under its message, indented")
    func text() {
        #expect(LogDocument.text(of: entries) == """
            14:05:09 INFO [Preferences] Set com.apple.dock autohide to true
                defaults write com.apple.dock "autohide" -bool true
            14:05:10 ERROR [Commands] Command failed
            """)
    }

    @Test("The entry inspector gets the selected entries, in log order")
    func selection() async throws {
        let store = LogStore()
        let model = LogViewerModel(store: store)
        #expect(model.selectedEntries.isEmpty)
        for message in ["one", "two", "three"] { store.post(.info, message, source: "App") }
        for _ in 0..<50 where store.entries.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        let ids = store.entries.map(\.id)
        model.selection = [ids[2], ids[0]]
        #expect(model.selectedEntries.map(\.message) == ["one", "three"])
    }
}
