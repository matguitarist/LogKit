@_exported import LogKit
import Foundation
import Observation

/// A log file the viewer reads, and the other files it can switch to.
public struct LogFileSource: Sendable {
    public struct NamedFile: Hashable, Sendable {
        public var title: String
        public var url: URL
        public init(_ title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    /// "Latest Log", "Crash Log": the first one opens by default.
    public var files: [NamedFile]
    /// Where the app's logs live: earlier sessions are listed from here, and "Open Log File…" starts here.
    public var folder: URL?
    /// Lists only the files whose name starts with this as sessions ("bg3se_").
    public var sessionPrefix: String?
    public var parser: any LogParser
    /// Bigger files show their end only.
    public var maxBytes: Int

    public init(files: [NamedFile], folder: URL? = nil, sessionPrefix: String? = nil,
                parser: any LogParser, maxBytes: Int = 8 << 20) {
        self.files = files
        self.folder = folder
        self.sessionPrefix = sessionPrefix
        self.parser = parser
        self.maxBytes = maxBytes
    }
}

/// The viewer's state. The app keeps it (in its app model or a @State), so
/// filters, Clear and the chosen file survive moving between pages.
@Observable
@MainActor
public final class LogViewerModel {
    public enum Source {
        case file(LogFileSource)
        case store(LogStore)
    }

    public let source: Source
    /// The file shown, for a file source.
    public var fileURL: URL? {
        didSet { if fileURL != oldValue { fileDocument = nil; lastModified = nil } }
    }
    public var filter = LogFilter()
    /// Reloads as the file changes and scrolls to new messages.
    public var followLive = true
    public var showInspector = false
    public private(set) var clearMark: ClearMark?
    public private(set) var loadError: String?
    public private(set) var lastModified: Date?
    private var fileDocument: LogDocument?
    /// The file's log with Clear applied, and its summary, computed off the main actor.
    private var cleared: (document: LogDocument, summary: LogSummary)?

    public init(file: LogFileSource) {
        source = .file(file)
        fileURL = file.files.first?.url
    }

    public init(store: LogStore) {
        source = .store(store)
    }

    // MARK: What the viewer shows

    /// The log with Clear applied, or nil when there's no log yet.
    public var document: LogDocument? {
        switch source {
        case .file: return cleared?.document
        case .store(let store):
            let document = store.document
            return clearMark?.apply(to: document, file: nil) ?? document
        }
    }

    public var summary: LogSummary {
        switch source {
        case .file: return cleared?.summary ?? LogSummary(entries: [])
        case .store: return LogSummary(entries: document?.entries ?? [])
        }
    }

    public var shownEntries: [LogEntry] { filter.apply(to: document?.entries ?? []) }

    /// Messages hidden by Clear, for the header.
    public var hiddenCount: Int {
        guard let clearMark else { return 0 }
        switch source {
        case .file: return max(0, (fileDocument?.entries.count ?? 0) - (cleared?.document.entries.count ?? 0))
        case .store(let store): return store.entries.filter { $0.id <= (clearMark.lastID ?? 0) }.count
        }
    }

    public var fileSource: LogFileSource? {
        if case .file(let file) = source { return file }
        return nil
    }

    /// Earlier sessions in the logs folder, newest first.
    public var sessions: [URL] {
        guard let file = fileSource, let folder = file.folder else { return [] }
        let named = Set(file.files.map(\.url.standardizedFileURL))
        return LogFiles.sessions(in: folder, prefix: file.sessionPrefix).filter { !named.contains($0.standardizedFileURL) }
    }

    // MARK: Actions

    /// Hides what was logged so far; new messages still appear. The file isn't changed.
    public func clear() {
        switch source {
        case .file:
            guard let fileDocument else { return }
            clearMark = ClearMark(file: fileURL, session: fileDocument.sessionKey, entryCount: fileDocument.entries.count)
            Task { await updateCleared() }
        case .store(let store):
            clearMark = ClearMark(lastID: store.entries.last?.id ?? 0)
        }
    }

    public func showAll() {
        clearMark = nil
        if case .file = source { Task { await updateCleared() } }
    }

    /// Reads the file again; with `force` false, only when it changed.
    public func reload(force: Bool = true) async {
        guard let file = fileSource, let url = fileURL else { return }
        guard let modified = LogFiles.modificationDate(of: url) else {
            fileDocument = nil
            cleared = nil
            loadError = nil
            lastModified = nil
            return
        }
        guard force || modified != lastModified else { return }
        let parser = file.parser, maxBytes = file.maxBytes
        do {
            let document = try await Task.detached { try LogFiles.load(url, parser: parser, maxBytes: maxBytes) }.value
            guard url == fileURL else { return }   // another file was picked meanwhile
            fileDocument = document
            lastModified = modified
            loadError = nil
            await updateCleared()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Follows the file while the viewer is open: `.task(id: model.fileURL) { await model.watch() }`.
    public func watch(every interval: Duration = .seconds(2)) async {
        await reload(force: true)
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if followLive { await reload(force: false) }
        }
    }

    private func updateCleared() async {
        guard let fileDocument else { cleared = nil; return }
        let mark = clearMark, url = fileURL
        cleared = await Task.detached {
            let document = mark?.apply(to: fileDocument, file: url) ?? fileDocument
            return (document: document, summary: LogSummary(entries: document.entries))
        }.value
    }
}
