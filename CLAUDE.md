# LogKit

The log viewer shared by my Mac apps (Starseed, Tadpole, Attic, AM2R Launcher
Plus, UnbloatMyMac and the next ones). A change here reaches every app at its
next package update, so keep the API stable and additive.

## Layout

- `Sources/LogKit/` no SwiftUI: `LogEntry` (levels, entries, metadata, insights,
  documents), `LogParser` (protocol, `LineLogParser`, `BracketLogParser`,
  `LogKitFormat`), `LogFiles` (tail, sessions), `LogFilter` (filter, summary,
  Clear), `LogStore` (the app's own log, thread-safe, rotating file).
- `Sources/LogKitUI/` `LogViewerModel` (state, loading, watching) and
  `LogViewer` (the view and `LogViewerOptions`). Strings in
  `Resources/Localizable.xcstrings`, English and French.
- `Tests/LogKitTests/` Swift Testing, for everything in LogKit.

## Rules

- Anything app-specific stays in the app: its parser, insights, actions,
  banner and inspector reach the viewer through `LogViewerOptions`.
- Every user-facing string uses `bundle: .module` and gets a French
  translation in the catalog.
- Colors are system colors (`LogLevel.color`); no hard-coded grays.
- Parsing is fast on 50,000 lines: no Regex per line, split by bytes (CRLF).
- Add a test for every change in LogKit. `swift build && swift test` pass,
  then CI on macOS.
- Release: tag `x.y.z` and push the tag; apps use `from:`.

## Git

Commit after each working change, with a message that says what an app can now do.
