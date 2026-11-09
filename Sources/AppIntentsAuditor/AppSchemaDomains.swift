import Foundation

/// Which App Intents schema domains reach Siri.
///
/// Apple's schema collection splits in two. A primary domain's schemas reach Siri; a
/// Shortcuts-specific domain's schemas support Shortcuts but not Siri, so such an intent needs
/// the tool trait as well. This is the part of the checker most likely to change during the Siri
/// AI Developer Preview, which is why it is one table with its source beside it.
///
/// Source: https://developer.apple.com/documentation/appintents/app-schema-domains
/// (read 2026-11-04). Names are compared with case and separators removed, so `wordProcessor`
/// and `word-processor` are the same domain.
enum AppSchemaDomains {

    /// Domains whose schemas support Shortcuts but not Siri.
    static let shortcutsOnly: Set<String> = [
        "books", "browser", "files", "journaling", "journal", "presentation",
        "reader", "spreadsheet", "whiteboard", "wordprocessor",
    ]

    static func isShortcutsOnly(_ domain: String) -> Bool {
        shortcutsOnly.contains(normalised(domain))
    }

    static func normalised(_ domain: String) -> String {
        String(domain.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
