import Foundation
import Testing
@testable import DocCodeAuditor

/// The auditor must check documentation under the same rules the package builds under.
///
/// Checking under *weaker* rules is how an actor method returning a non-`Sendable` type
/// passed for months: the compiler's default mode made the violation a warning, and the
/// auditor only collects errors. Checking under *stronger* rules is the mirror defect —
/// a package on Swift 5 would be handed errors its own build never raises, and the
/// documentation would be "fixed" to satisfy a rule nobody adopted.
///
/// So the mode is read, not assumed. These tests pin what is read.
@Suite("Manifest Language Mode")
struct ManifestLanguageModeTests {

    // MARK: - Tools version sets the default

    @Test("A tools-version 6.x manifest builds in Swift 6 mode")
    func toolsVersionSixMeansSix() {
        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "P")])
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(mode.isDetermined)
        #expect(mode.swiftVersion == "6")
        #expect(mode.flags.contains("-swift-version"))
        #expect(mode.flags.contains("6"))
    }

    @Test("A tools-version 5.9 manifest builds in Swift 5 mode")
    func toolsVersionFiveMeansFive() {
        let manifest = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "P")])
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(mode.isDetermined)
        #expect(mode.swiftVersion == "5")
    }

    // MARK: - Explicit settings override it

    @Test("A per-target .swiftLanguageMode overrides the tools version")
    func targetLanguageModeWins() {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [
            .target(name: "P", swiftSettings: [.swiftLanguageMode(.v5)])
        ])
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(mode.swiftVersion == "5")
    }

    @Test("The legacy .swiftLanguageVersion spelling is read too")
    func legacySpellingWins() {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [
            .target(name: "P", swiftSettings: [.swiftLanguageVersion(.v5)])
        ])
        """
        #expect(ManifestLanguageMode.read(manifest: manifest, target: "P").swiftVersion == "5")
    }

    @Test("A package-level swiftLanguageModes sets the default for every target")
    func packageLevelModeApplies() {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "P",
            swiftLanguageModes: [.v5],
            targets: [.target(name: "P")]
        )
        """
        #expect(ManifestLanguageMode.read(manifest: manifest, target: "P").swiftVersion == "5")
    }

    // MARK: - swiftSettings become swiftc flags

    @Test("An upcoming feature reaches the compiler")
    func upcomingFeatureIsPassed() {
        let manifest = """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "P", targets: [
            .target(name: "P", swiftSettings: [.enableUpcomingFeature("StrictConcurrency")])
        ])
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(mode.flags.contains("-enable-upcoming-feature"))
        #expect(mode.flags.contains("StrictConcurrency"))
    }

    @Test("An experimental feature, a define and unsafe flags all reach the compiler")
    func otherSettingsArePassed() {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [
            .target(name: "P", swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
                .define("FEATURE_X"),
                .unsafeFlags(["-warnings-as-errors"])
            ])
        ])
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(mode.flags.contains("-enable-experimental-feature"))
        #expect(mode.flags.contains("Lifetimes"))
        #expect(mode.flags.contains("-DFEATURE_X"))
        #expect(mode.flags.contains("-warnings-as-errors"))
    }

    @Test("Settings belonging to a different target do not leak")
    func settingsAreTargetScoped() {
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [
            .target(name: "Other", swiftSettings: [.define("OTHER_ONLY")]),
            .target(name: "P")
        ])
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(!mode.flags.contains("-DOTHER_ONLY"))
    }

    @Test("A target declared inside a #if is still found")
    func conditionalTargetIsFound() {
        // BusinessMath builds its target list with `var targets` and `#if !os(Linux)`.
        // A parser that only reads the literal array argument of `Package(...)` finds nothing.
        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        var targets: [Target] = []
        #if !os(Linux)
        targets.append(.target(name: "P", swiftSettings: [.define("CONDITIONAL")]))
        #endif
        let package = Package(name: "P", targets: targets)
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(mode.flags.contains("-DCONDITIONAL"))
    }

    @Test("An unrecognised setting is recorded rather than silently dropped")
    func unrecognisedSettingIsRecorded() {
        // Silence is indistinguishable from support. If the auditor cannot translate a
        // setting the build applies, the report has to say so.
        let manifest = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "P", targets: [
            .target(name: "P", swiftSettings: [.someFutureSetting(.enabled)])
        ])
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(mode.unrecognisedSettings.contains("someFutureSetting"))
    }

    // MARK: - When it cannot be determined

    @Test("A manifest with no tools-version comment is undetermined, and says so")
    func missingToolsVersionIsUndetermined() {
        let manifest = """
        import PackageDescription
        let package = Package(name: "P", targets: [.target(name: "P")])
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "P")
        #expect(!mode.isDetermined)
        #expect(mode.swiftVersion == nil)
        #expect(!mode.flags.contains("-swift-version"))
        #expect(!mode.explanation.isEmpty)
    }

    @Test("An undetermined mode never guesses the strictest rules")
    func undeterminedDoesNotAssumeStrict() {
        // Assuming Swift 6 is right for the corpus this was built against and wrong in
        // general: it hands an older package errors its own build would never raise.
        let mode = ManifestLanguageMode.read(manifest: "", target: "P")
        #expect(!mode.flags.contains("6"))
        #expect(!mode.flags.contains("-strict-concurrency=complete"))
    }

    @Test("BusinessMath's shape resolves to Swift 6 with strict concurrency")
    func businessMathShape() {
        // The regression corpus. tools-version 6.2 (so Swift 6 mode, which already implies
        // complete strict concurrency) plus an explicit upcoming-feature flag.
        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription
        var targets: [Target] = [
            .target(
                name: "BusinessMath",
                dependencies: ["Numerics"],
                swiftSettings: [
                    .enableUpcomingFeature("StrictConcurrency")
                ]
            )
        ]
        let package = Package(name: "BusinessMath", targets: targets)
        """
        let mode = ManifestLanguageMode.read(manifest: manifest, target: "BusinessMath")
        #expect(mode.swiftVersion == "6")
        #expect(mode.flags.contains("StrictConcurrency"))
    }
}
