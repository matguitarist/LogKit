import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension LogLevel {
    /// Console colors: dim trace and debug, plain info, orange warnings, red errors, purple alerts.
    public var color: Color {
        switch self {
        case .trace: .gray
        case .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error: .red
        case .critical: .purple
        }
    }

    public var symbol: String {
        switch self {
        case .trace: "ellipsis.circle"
        case .debug: "ladybug"
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .critical: "bell.fill"
        }
    }

    public var title: String {
        switch self {
        case .trace: String(localized: "Trace", bundle: .module)
        case .debug: String(localized: "Debug", bundle: .module)
        case .info: String(localized: "Info", bundle: .module)
        case .warning: String(localized: "Warning", bundle: .module)
        case .error: String(localized: "Error", bundle: .module)
        case .critical: String(localized: "Alert", bundle: .module)
        }
    }
}

/// What an app adds to the viewer. Every part is optional.
public struct LogViewerOptions {
    /// Shown when there's no log yet, with the app's actions ("Launch the Game").
    public var emptyTitle: String
    public var emptyMessage: String
    public var emptyActions: (() -> AnyView)?
    /// The insights panel's title: "What SMAPI is telling you".
    public var insightsTitle: String
    /// Buttons for an insight. Without them, an insight about a source gets "Show Messages".
    public var insightActions: ((LogInsight) -> AnyView)?
    /// A banner above everything, from the log ("This save uses mods you don't have").
    public var banner: ((LogDocument) -> AnyView)?
    /// More items for the header's first line, after the log's metadata.
    public var headerAccessory: (() -> AnyView)?
    /// The panel at the right, with its toolbar button title ("Loaded Mods").
    public var inspectorTitle: String?
    public var inspector: ((LogDocument) -> AnyView)?
    /// More items for the Share menu ("Upload to smapi.io…"). They get the shown text.
    public var shareActions: [ShareAction]
    /// The color of a source's name; the app's own sources stand out.
    public var sourceColor: (String) -> Color

    public struct ShareAction {
        public var title: String
        public var action: (_ text: String) -> Void
        public init(_ title: String, action: @escaping (_ text: String) -> Void) {
            self.title = title
            self.action = action
        }
    }

    /// Texts left nil get LogKit's own, in the person's language.
    public init(emptyTitle: String? = nil,
                emptyMessage: String? = nil,
                emptyActions: (() -> AnyView)? = nil,
                insightsTitle: String? = nil,
                insightActions: ((LogInsight) -> AnyView)? = nil,
                banner: ((LogDocument) -> AnyView)? = nil,
                headerAccessory: (() -> AnyView)? = nil,
                inspectorTitle: String? = nil,
                inspector: ((LogDocument) -> AnyView)? = nil,
                shareActions: [ShareAction] = [],
                sourceColor: @escaping (String) -> Color = { _ in .indigo }) {
        self.emptyTitle = emptyTitle ?? String(localized: "No Log Yet", bundle: .module)
        self.emptyMessage = emptyMessage ?? String(localized: "Messages appear here as they're logged.", bundle: .module)
        self.emptyActions = emptyActions
        self.insightsTitle = insightsTitle ?? String(localized: "What the log is telling you", bundle: .module)
        self.insightActions = insightActions
        self.banner = banner
        self.headerAccessory = headerAccessory
        self.inspectorTitle = inspectorTitle
        self.inspector = inspector
        self.shareActions = shareActions
        self.sourceColor = sourceColor
    }
}

/// A log with colored levels that double as filters and counts, problems
/// grouped by source, insights, search, Clear (⌘K), live follow, and copy or
/// export. Put it in a page or window and give it a title:
///
///     LogViewer(model: model.log, options: .init(insightsTitle: "What SMAPI is telling you"))
///         .navigationTitle("SMAPI Log")
public struct LogViewer: View {
    @Bindable private var model: LogViewerModel
    private let options: LogViewerOptions
    @State private var selection = Set<LogEntry.ID>()
    @State private var insightsExpanded = true

    public init(model: LogViewerModel, options: LogViewerOptions = LogViewerOptions()) {
        _model = Bindable(model)
        self.options = options
    }

    public var body: some View {
        content
            .navigationSubtitle(model.fileURL?.lastPathComponent ?? "")
            .searchable(text: $model.filter.query, placement: .toolbar, prompt: Text("Search log", bundle: .module))
            .toolbar { toolbar }
            .modifier(InspectorModifier(model: model, options: options))
            .task(id: model.fileURL) {
                if model.fileSource != nil { await model.watch() }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let document = model.document {
            let summary = model.summary
            VStack(spacing: 0) {
                if let banner = options.banner { banner(document) }
                InsightsPanel(insights: document.insights, title: options.insightsTitle, expanded: $insightsExpanded,
                              actions: options.insightActions, showSource: { model.filter.source = $0 })
                header(document, summary: summary)
                Divider()
                entryList(document)
            }
        } else {
            ContentUnavailableView {
                Label(options.emptyTitle, systemImage: "doc.text.magnifyingglass")
            } description: {
                Text(model.loadError ?? options.emptyMessage)
            } actions: {
                if let emptyActions = options.emptyActions { emptyActions() }
                if model.fileSource != nil {
                    Button(String(localized: "Open Log File…", bundle: .module), action: chooseFile)
                }
            }
        }
    }

    // MARK: Header

    private func header(_ document: LogDocument, summary: LogSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                // With an inspector open there's little room: the facts
                // become icons (named on hover) rather than "SM…".
                ViewThatFits(in: .horizontal) {
                    metadataRow(document, iconsOnly: false)
                    metadataRow(document, iconsOnly: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) { status(document) }
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.callout)

            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(LogLevel.allCases, id: \.self) { level in
                            levelChip(level, count: summary.counts[level, default: 0])
                        }
                    }
                }
                if summary.sources.count > 1 {
                    Menu {
                        Button(String(localized: "All Sources", bundle: .module)) { model.filter.source = nil }
                        Divider()
                        ForEach(summary.sources, id: \.self) { source in
                            Toggle(source, isOn: Binding(get: { model.filter.source == source },
                                                         set: { model.filter.source = $0 ? source : nil }))
                        }
                    } label: {
                        Text(model.filter.source ?? String(localized: "All Sources", bundle: .module))
                    }
                    .fixedSize()
                    .controlSize(.small)
                    .help(String(localized: "Show the messages from one source only", bundle: .module))
                }
                if let source = model.filter.source {
                    Button {
                        model.filter.source = nil
                    } label: {
                        Label(String(localized: "Source: \(source)", bundle: .module), systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Toggle(String(localized: "Hide Repeats", bundle: .module), isOn: $model.filter.collapseRepeats)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help(String(localized: "Show a message logged again and again once, with how many times", bundle: .module))
                shownCount(document)
            }
            .fixedSize(horizontal: false, vertical: true)

            if !summary.problems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Problems:", bundle: .module).font(.callout.bold()).foregroundStyle(.secondary)
                        ForEach(summary.problems, id: \.self) { problem in
                            problemChip(problem)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func metadataRow(_ document: LogDocument, iconsOnly: Bool) -> some View {
        HStack(spacing: 14) {
            ForEach(document.metadata, id: \.self) { item in
                Label(item.label, systemImage: item.symbol)
                    .labelStyle(iconsOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .lineLimit(1)
                    .fixedSize()
                    .help(item.label)
            }
            if let headerAccessory = options.headerAccessory { headerAccessory() }
        }
    }

    @ViewBuilder
    private func status(_ document: LogDocument) -> some View {
        if model.clearMark != nil {
            Text(String(localized: "Cleared at \((model.clearMark?.date ?? .now).formatted(date: .omitted, time: .standard)) · \(model.hiddenCount) earlier messages hidden", bundle: .module))
                .foregroundStyle(.secondary)
            Button(String(localized: "Show All", bundle: .module)) { model.showAll() }
                .controlSize(.small)
        } else if document.truncated {
            Text("Showing the end of a long log", bundle: .module).foregroundStyle(.secondary)
        } else if let lastModified = model.lastModified {
            Text(String(localized: "Updated \(lastModified.formatted(date: .omitted, time: .standard))", bundle: .module))
                .foregroundStyle(.secondary)
        }
    }

    /// "1,204 messages", or "12 of 1,204 messages" with a way back when a filter hides some.
    @ViewBuilder
    private func shownCount(_ document: LogDocument) -> some View {
        let total = document.entries.count
        if model.filter.narrows(model.defaultFilter) {
            Text(String(localized: "\(model.shownEntries.count) of \(total) messages", bundle: .module))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
            Button(String(localized: "Show All Messages", bundle: .module)) {
                model.filter = model.filter.reset(to: model.defaultFilter)
            }
            .controlSize(.small)
            .help(String(localized: "Show every level the log starts with, from every source, without the search", bundle: .module))
        } else {
            Text(String(localized: "\(total) messages", bundle: .module))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit().fixedSize()
        }
    }

    private func levelChip(_ level: LogLevel, count: Int) -> some View {
        let isOn = model.filter.levels.contains(level)
        return Button {
            if isOn { model.filter.levels.remove(level) } else { model.filter.levels.insert(level) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: level.symbol)
                Text(verbatim: "\(level.title) \(count)").monospacedDigit()
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(isOn ? level.color.opacity(0.2) : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(level.color.opacity(isOn ? 0.6 : 0.25)))
            .foregroundStyle(isOn ? level.color : .secondary)
        }
        .buttonStyle(.plain)
        .help(isOn ? String(localized: "Hide \(level.title) messages", bundle: .module)
                   : String(localized: "Show \(level.title) messages", bundle: .module))
    }

    private func problemChip(_ problem: LogSummary.Problem) -> some View {
        let isOn = model.filter.source == problem.source
        return Button {
            model.filter.source = isOn ? nil : problem.source
        } label: {
            HStack(spacing: 4) {
                Image(systemName: problem.worst.symbol)
                Text(verbatim: "\(problem.source) (\(problem.count))")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(problem.worst.color.opacity(isOn ? 0.35 : 0.15), in: Capsule())
            .foregroundStyle(problem.worst.color)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Show only \(problem.source)", bundle: .module))
    }

    // MARK: Messages

    private func entryList(_ document: LogDocument) -> some View {
        let entries = model.shownEntries
        return ScrollViewReader { proxy in
            List(entries, selection: $selection) { entry in
                LogRow(entry: entry, sourceColor: options.sourceColor(entry.source)) { model.filter.source = $0 }
                    .listRowBackground(entry.isProblem ? entry.level.color.opacity(0.08) : Color.clear)
                    .id(entry.id)
            }
            .listStyle(.plain)
            .contextMenu(forSelectionType: LogEntry.ID.self) { ids in
                Button(String(localized: "Copy", bundle: .module)) {
                    copy(LogDocument.text(of: entries.filter { ids.contains($0.id) }))
                }
                if let source = entries.first(where: { ids.contains($0.id) })?.source, !source.isEmpty, ids.count == 1 {
                    Button(String(localized: "Show Only \(source)", bundle: .module)) { model.filter.source = source }
                }
            }
            .overlay {
                if entries.isEmpty {
                    if document.entries.isEmpty, model.clearMark != nil {
                        ContentUnavailableView(String(localized: "Log Cleared", bundle: .module), systemImage: "clear",
                                               description: Text("New messages appear here as they're logged.", bundle: .module))
                    } else if !model.filter.query.isEmpty {
                        ContentUnavailableView.search(text: model.filter.query)
                    } else {
                        ContentUnavailableView(String(localized: "No Matching Messages", bundle: .module),
                                               systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .onChange(of: document.entries.last?.id) {
                if model.followLive, let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let file = model.fileSource {
                Menu {
                    ForEach(file.files, id: \.self) { named in
                        Button(named.title) { model.fileURL = named.url }
                            .disabled(!FileManager.default.fileExists(atPath: named.url.path(percentEncoded: false)))
                    }
                    let sessions = model.sessions
                    if !sessions.isEmpty {
                        Divider()
                        Section(String(localized: "Earlier Sessions", bundle: .module)) {
                            ForEach(sessions.prefix(15), id: \.self) { url in
                                Button(url.deletingPathExtension().lastPathComponent) { model.fileURL = url }
                            }
                        }
                    }
                    Divider()
                    Button(String(localized: "Open Log File…", bundle: .module), action: chooseFile)
                    if let folder = file.folder {
                        Button(String(localized: "Open Logs Folder", bundle: .module)) { NSWorkspace.shared.open(folder) }
                    }
                } label: {
                    Label(String(localized: "Log File", bundle: .module), systemImage: "doc.text")
                }
                .help(String(localized: "Choose which log to show", bundle: .module))
            }

            Toggle(isOn: $model.followLive) {
                Label(String(localized: "Follow Live", bundle: .module), systemImage: "arrow.down.to.line")
            }
            .help(String(localized: "Show new messages as they're logged, and scroll to them", bundle: .module))

            Button {
                model.clear()
            } label: {
                Label(String(localized: "Clear", bundle: .module), systemImage: "clear")
            }
            .keyboardShortcut("k")
            .help(String(localized: "Hide everything logged so far and show only new messages (⌘K). The log file isn't changed.", bundle: .module))
            .disabled(model.document?.entries.isEmpty ?? true)

            if model.fileSource != nil {
                Button {
                    Task { await model.reload(force: true) }
                } label: {
                    Label(String(localized: "Reload", bundle: .module), systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help(String(localized: "Read the log file again (⌘R)", bundle: .module))
            }

            Menu {
                Button(String(localized: "Copy Shown Messages", bundle: .module)) { copy(LogDocument.text(of: model.shownEntries)) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                if let url = logFileURL {
                    Button(String(localized: "Copy Log File", bundle: .module)) {
                        if let text = try? String(contentsOf: url, encoding: .utf8) { copy(text) }
                    }
                    Button(String(localized: "Export Log…", bundle: .module)) { export(url) }
                    Button(String(localized: "Show in Finder", bundle: .module)) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                if !options.shareActions.isEmpty {
                    Divider()
                    ForEach(options.shareActions.indices, id: \.self) { index in
                        let action = options.shareActions[index]
                        Button(action.title) { action.action(LogDocument.text(of: model.shownEntries)) }
                    }
                }
            } label: {
                Label(String(localized: "Share", bundle: .module), systemImage: "square.and.arrow.up")
            }
            .help(String(localized: "Copy, export, or show the log file", bundle: .module))
            .disabled(model.document == nil)
        }
        if let title = options.inspectorTitle, options.inspector != nil {
            ToolbarItem {
                Toggle(isOn: $model.showInspector) {
                    Label(title, systemImage: "sidebar.trailing")
                }
                .help(title)
            }
        }
    }

    /// The file behind the log: the one shown, or the store's.
    private var logFileURL: URL? {
        switch model.source {
        case .file: model.fileURL
        case .store(let store): store.fileURL
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .log]
        panel.directoryURL = model.fileSource?.folder
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { model.fileURL = url }
    }

    private func export(_ url: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.plainText, .log]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: url, to: destination)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct InspectorModifier: ViewModifier {
    @Bindable var model: LogViewerModel
    let options: LogViewerOptions

    @ViewBuilder
    func body(content: Content) -> some View {
        if let inspector = options.inspector {
            content.inspector(isPresented: $model.showInspector) {
                inspector(model.document ?? LogDocument())
                    .inspectorColumnWidth(min: 240, ideal: 320, max: 480)
            }
        } else {
            content
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let sourceColor: Color
    let onSourceTap: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let time = entry.time {
                Text(verbatim: time).foregroundStyle(.tertiary)
            }
            Text(verbatim: entry.displayCode)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(entry.level == .info ? Color.secondary : entry.level.color)
                .frame(width: 44, alignment: .leading)
            if !entry.source.isEmpty {
                Button(entry.source) { onSourceTap(entry.source) }
                    .buttonStyle(.plain)
                    .foregroundStyle(sourceColor)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
                    .help(String(localized: "Show only \(entry.source)", bundle: .module))
            }
            Text(verbatim: entry.message)
                .foregroundStyle(entry.level.color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.repeats > 1 {
                Text(verbatim: "×\(entry.repeats)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .background(.quaternary, in: Capsule())
            }
        }
        .font(.system(.callout, design: .monospaced))
        .padding(.vertical, 1)
    }
}

/// Findings in plain words, each with a way to act on it.
private struct InsightsPanel: View {
    let insights: [LogInsight]
    let title: String
    @Binding var expanded: Bool
    let actions: ((LogInsight) -> AnyView)?
    let showSource: (String) -> Void

    var body: some View {
        if !insights.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                DisclosureGroup(isExpanded: $expanded) {
                    // Scrolls when long, so a few findings don't push the messages out of the window.
                    ViewThatFits(in: .vertical) {
                        rows
                        ScrollView { rows }
                    }
                    .frame(maxHeight: 180)
                    .padding(.top, 6)
                } label: {
                    Label(String(localized: "\(title) (\(insights.count))", bundle: .module), systemImage: "lightbulb")
                        .font(.headline)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            Divider()
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(insights) { insight in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: insight.level.symbol)
                        .foregroundStyle(insight.level.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: insight.title).fontWeight(.semibold)
                        if !insight.detail.isEmpty {
                            Text(verbatim: insight.detail).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Group {
                        if let actions {
                            actions(insight)
                        } else if let source = insight.source {
                            Button(String(localized: "Show Messages", bundle: .module)) { showSource(source) }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }
}


/// A label style chosen at run time.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some LabelStyle) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
