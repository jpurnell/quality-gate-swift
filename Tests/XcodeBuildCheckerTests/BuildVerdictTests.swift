import Testing
import QualityGateCore
@testable import XcodeBuildChecker

/// The verdict must come from xcodebuild's exit code, never from whether this tool
/// managed to parse the output.
///
/// The regression these cover: `anyBuildFailed` was set only when a nonzero exit was
/// *accompanied* by a parsed `.error` diagnostic. Xcode 27's diagnostic format is not
/// one the parser recognises, so a build failing with four compiler errors was reported
/// as `✓ PASSED` — the single worst outcome for a build checker, because a green gate is
/// the thing that persuades you not to look.
@Suite("Xcode build verdict")
struct BuildVerdictTests {

    @Test("A nonzero exit fails even when no diagnostic could be parsed")
    func nonzeroExitWithoutParsedDiagnosticsFails() {
        #expect(XcodeBuildChecker.buildFailed(exitCode: 65, diagnostics: []))
    }

    @Test("A nonzero exit fails when diagnostics parsed but none are errors")
    func nonzeroExitWithOnlyWarningsFails() {
        let warning = Diagnostic(severity: .warning, message: "deprecated", ruleId: "x")
        #expect(XcodeBuildChecker.buildFailed(exitCode: 1, diagnostics: [warning]))
    }

    @Test("A zero exit passes")
    func zeroExitPasses() {
        #expect(!XcodeBuildChecker.buildFailed(exitCode: 0, diagnostics: []))
    }

    @Test("An unexplained failure is reported rather than left silent")
    func unexplainedFailureProducesADiagnostic() {
        let synthesized = XcodeBuildChecker.unexplainedFailureDiagnostic(
            exitCode: 65,
            destination: "platform=macOS",
            output: "some output the parser did not recognise"
        )
        #expect(synthesized.severity == .error)
        #expect(synthesized.message.contains("65"))
        #expect(synthesized.message.contains("platform=macOS"))
    }
}

/// Which scheme the checker builds.
///
/// The regression: `schemes.first` picked a Swift package dependency's scheme over the
/// project's own, so the checker compiled `BusinessMath` instead of `WineTaster 4` and
/// reported a clean build for an app it never touched.
@Suite("Scheme selection")
struct SchemeSelectionTests {

    @Test("The project's own scheme wins over a dependency's")
    func prefersTheContainerScheme() {
        let schemes = ["BusinessMath", "BusinessMath-Package", "WineTaster 4"]
        #expect(XcodeBuildChecker.preferredScheme(schemes: schemes, containerName: "WineTaster 4")
                == "WineTaster 4")
    }

    @Test("Falls back to the first scheme when none matches the container")
    func fallsBackToFirst() {
        #expect(XcodeBuildChecker.preferredScheme(schemes: ["Alpha", "Beta"], containerName: "Gamma")
                == "Alpha")
    }

    @Test("Falls back to the first scheme when the container is unnamed")
    func fallsBackWhenUnnamed() {
        #expect(XcodeBuildChecker.preferredScheme(schemes: ["Alpha"], containerName: nil) == "Alpha")
    }

    @Test("No schemes yields nothing to build")
    func noSchemes() {
        #expect(XcodeBuildChecker.preferredScheme(schemes: [], containerName: "Anything") == nil)
    }
}

/// Choosing the destination from what the scheme can actually build.
///
/// The regression these cover: the destination defaulted to `generic/platform=macOS`
/// unconditionally. IconquerApp declares one scheme per platform — `iConquer_iOS`,
/// `iConquer_macOS`, `iConquer_tvOS`, `iConquer_visionOS` — and `preferredScheme` finds no
/// scheme matching the container name `IconquerApp`, so it takes `schemes.first`
/// (`iConquer_iOS`) and asked xcodebuild to build an iOS-only target for the host. The
/// result was `xcodebuild exited 70` and a wall of destination noise, for a project whose
/// only fault was not being a Mac app.
@Suite("Xcode build destination")
struct BuildDestinationTests {

    @Test("An iOS-only scheme builds for the iOS simulator, not the host")
    func iOSOnlySchemeBuildsForIOS() {
        // The exact value `xcodebuild -showBuildSettings` reports for iConquer_iOS.
        // Simulator, not device: `generic/platform=iOS` failed this very project with
        // `Signing for "iConquer_iOS" requires a development team`, which is not a
        // question a compile check should be asking.
        #expect(
            XcodeBuildChecker.defaultDestination(supportedPlatforms: "iphoneos iphonesimulator")
                == "generic/platform=iOS Simulator")
    }

    @Test("Every platform family maps to its generic destination")
    func everyPlatformFamilyMaps() {
        let cases = [
            "macosx": "generic/platform=macOS",
            "appletvos appletvsimulator": "generic/platform=tvOS Simulator",
            "watchos watchsimulator": "generic/platform=watchOS Simulator",
            "xros xrsimulator": "generic/platform=visionOS Simulator",
        ]
        for (platforms, expected) in cases {
            #expect(
                XcodeBuildChecker.defaultDestination(supportedPlatforms: platforms) == expected,
                "\(platforms) should map to \(expected)")
        }
    }

    @Test("A scheme that also builds for the host prefers the host")
    func multiPlatformSchemePrefersHost() {
        // Cheapest and least likely to need a simulator or a signing identity. Only
        // reached when the scheme genuinely supports macOS — never as a blind default.
        #expect(
            XcodeBuildChecker.defaultDestination(
                supportedPlatforms: "iphoneos iphonesimulator macosx")
                == "generic/platform=macOS")
    }

    @Test("An unrecognised platform yields nil rather than a guess")
    func unrecognisedPlatformYieldsNil() {
        // nil means "I could not tell", and the caller keeps the old macOS default. A
        // checker that guesses here would fail a project for a reason it invented.
        #expect(XcodeBuildChecker.defaultDestination(supportedPlatforms: "") == nil)
        #expect(XcodeBuildChecker.defaultDestination(supportedPlatforms: "linux") == nil)
    }
}
