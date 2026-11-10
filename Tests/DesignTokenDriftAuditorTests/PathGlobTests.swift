import Testing
@testable import DesignTokenDriftAuditor

@Suite("PathGlob")
struct PathGlobTests {

    @Test("Enumerated matches", arguments: [
        ("Sources/App/Palette.swift", "Sources/App/Palette.swift", true),
        ("Sources/App/Palette.swift", "Sources/App/Other.swift", false),
        ("Sources/App", "Sources/App/Palette.swift", true),
        ("Sources/App", "Sources/Application/X.swift", false),
        ("*.swift", "A.swift", true),
        ("*.swift", "Sources/A.swift", false),
        ("Sources/*/Palette.swift", "Sources/App/Palette.swift", true),
        ("Sources/*/Palette.swift", "Sources/A/B/Palette.swift", false),
        ("**/*Palette.swift", "Sources/App/WinePalette.swift", true),
        ("**/*Palette.swift", "WinePalette.swift", true),
        ("**/*Palette.swift", "Sources/App/Wine.swift", false),
        ("**/Tests/**", "Tests/A.swift", true),
        ("**/Tests/**", "Sources/Foo/Tests/A.swift", true),
        ("**/Tests/**", "Sources/Foo/Testing/A.swift", false),
        ("Assets/css/**", "Assets/css/main.css", true),
        ("Assets/css/**", "Assets/js/main.js", false),
        ("a?c.swift", "abc.swift", true),
        ("a?c.swift", "abbc.swift", false),
        ("./Sources/A.swift", "Sources/A.swift", true),
    ] as [(String, String, Bool)])
    func matches(pattern: String, path: String, expected: Bool) {
        #expect(PathGlob.matches(pattern, path: path) == expected, "\(pattern) vs \(path)")
    }
}
