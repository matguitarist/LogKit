# LogKit

The log viewer my Mac apps share. It started as Starseed's SMAPI Log and
gathers what each app added since: Attic's own log with repeats folded,
AM2R's tail of a big file, UnbloatMyMac's copy and export, Tadpole's sessions.

- **LogKit**: parsing (built-in formats and your own), filtering, summaries,
  Clear, reading the end of big files, and `LogStore`, the app's own log,
  written from any thread to `~/Library/Logs/<App>/<App>.log`. No SwiftUI.
- **LogKitUI**: `LogViewer`, the SwiftUI view. Re-exports LogKit.

macOS 14 or later. English, French, German, Spanish, Brazilian Portuguese and Simplified Chinese.

## What the viewer does

- Levels as colored chips that are also filters and counts
- Problems grouped by source, worst first; a click shows only that source
- Insights in plain words above the messages, with the app's own buttons
- Search, Hide Repeats (×12), Follow Live, Clear (⌘K) that leaves the file alone
- How many messages are shown ("12 of 1,204 messages"), and Show All Messages when a filter hides some
- Latest, crash and earlier session files, Open Log File…, Open Logs Folder
- Copy selected lines, Copy Shown Messages (⇧⌘C), Copy Log File, Export Log…, Show in Finder
- A banner, header items, an inspector and Share actions, all optional, from the app

## Add it to an app

SwiftPM (`Package.swift`):

```swift
.package(url: "https://github.com/matguitarist/LogKit", from: "0.3.0"),
// in the app target:
.product(name: "LogKitUI", package: "LogKit"),
```

XcodeGen (`project.yml`):

```yaml
packages:
  LogKit:
    url: https://github.com/matguitarist/LogKit
    from: 0.3.0
targets:
  App:
    dependencies:
      - package: LogKit
        product: LogKitUI
```

## A log file the app reads (a game's, a tool's)

```swift
import LogKitUI

let smapiFolder = URL.homeDirectory.appending(path: ".config/StardewValley/ErrorLogs")
let logModel = LogViewerModel(file: LogFileSource(
    files: [.init("Latest Log", url: smapiFolder.appending(path: "SMAPI-latest.txt")),
            .init("Crash Log", url: smapiFolder.appending(path: "SMAPI-crash.txt"))],
    folder: smapiFolder,
    parser: BracketLogParser(finish: { document in
        document.metadata = [LogMetadata("SMAPI 4.1.10", symbol: "gearshape.2")]
        document.insights = []   // findings in plain words
    })))

LogViewer(model: logModel, options: .init(insightsTitle: "What SMAPI is telling you"))
    .navigationTitle("SMAPI Log")
```

Keep the model in the app model (or a `@State` at the app level), so filters,
Clear and the chosen file survive moving between pages.

An app that starts with some levels hidden (Debug, say) sets the filter and
`defaultFilter` together, so Show All Messages goes back to that start:
`model.filter.levels = [.info, .warning, .error, .critical]; model.defaultFilter = model.filter`.

Another format: `LineLogParser { line in ... }` returns a `ParsedLine` for a
line that starts an entry and nil for a line that continues one.

## The app's own log

```swift
extension LogStore {
    static let app = LogStore(fileURL: LogStore.defaultFileURL(app: "Attic"))
}

LogStore.app.post(.error, "Dolphin quit with code 6", source: "Dolphin")   // from any thread

LogViewer(model: LogViewerModel(store: .app))
    .navigationTitle("Log")
```

The file uses LogKit's format, `2026-11-06T22:14:05-05:00 WARN [Source] message`,
which `LogKitFormat.parser` reads back.

## Develop

`swift build` and `swift test` (Swift Testing). CI runs both on macOS for
every push. Tag a release (`git tag 0.2.0 && git push --tags`) for apps to
pick it up with `from:`.
