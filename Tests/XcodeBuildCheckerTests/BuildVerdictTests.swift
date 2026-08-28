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
