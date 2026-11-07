import Foundation
import Testing

/// The apps ship in these languages; a string missing one shows in English there.
@Suite("Localization")
struct LocalizationTests {
    static let languages = ["fr", "de", "es", "pt-BR", "zh-Hans"]

    @Test("Every viewer string is translated into every language the apps ship")
    func everyStringTranslated() throws {
        let catalog = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LogKitUI/Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any]
        let strings = try #require(json?["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        var missing: [String] = []
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            for language in Self.languages where localizations[language] == nil {
                missing.append("\(key) [\(language)]")
            }
        }
        #expect(missing.isEmpty, "Untranslated: \(missing.sorted().joined(separator: ", "))")
    }
}
