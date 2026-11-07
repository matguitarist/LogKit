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
}
