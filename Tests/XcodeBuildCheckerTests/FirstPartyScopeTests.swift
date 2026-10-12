import Testing
import QualityGateCore
import BuildChecker
@testable import XcodeBuildChecker

/// A dependency's warnings are not this package's, under xcodebuild as under `swift build`.
///
/// The regression: `build` dropped a warning under `.build/checkouts/`, and `xcode-build`
/// counted the same warning because Xcode keeps the checkout under
/// `DerivedData/<project>/SourcePackages/checkouts/` and this checker never asked. IconquerAI
/// reported 20 warnings from mlx-swift's Metal shader headers on every clean build — none of
/// them in a file it owns, none of them fixable by it.
@Suite("Xcode build first-party scope")
struct XcodeFirstPartyScopeTests {

    static let root = "/Users/x/Code/IconquerAI"
    static let derivedData = "/Users/x/Library/Developer/Xcode/DerivedData/IconquerAI-fclwxvtespztqegq"

    /// Two lines of a real clean build, with the DerivedData root shortened.
    static let metalWarnings = """
        \(derivedData)/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/complex.h:157:54: warning: 'static_assert' with no message is a C++17 extension [-Wc++17-extensions]
        \(derivedData)/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/sort.h:43:8: warning: constexpr if is a C++17 extension [-Wc++17-extensions]
        """

    static func verdict(_ output: String, failed: Bool = false) -> (status: CheckResult.Status, diagnostics: [Diagnostic]) {
        XcodeBuildChecker.verdict(
            diagnostics: BuildChecker.parseBuildOutput(output),
            anyBuildFailed: failed,
            projectRoot: root
        )
    }

    @Test("Dependency warnings alone leave the build passed, with a note saying what was not counted")
    func dependencyWarningsAreNotCounted() {
        let verdict = Self.verdict(Self.metalWarnings)

        #expect(verdict.status == .passed)
        #expect(verdict.diagnostics.filter { $0.severity == .warning }.isEmpty)
        #expect(verdict.diagnostics.map(\.message)
                == ["2 warnings in dependency mlx-swift were not counted; they are not this package's source"])
        #expect(verdict.diagnostics.first?.severity == .note)
    }

    @Test("A first-party warning is still counted, beside a dependency's that is not")
    func firstPartyWarningIsCounted() {
        let own = "\(Self.root)/Sources/IconquerAI/Policy.swift:12:9: warning: variable 'x' was never used"
        let verdict = Self.verdict(Self.metalWarnings + "\n" + own)

        #expect(verdict.status == .warning)
        let warnings = verdict.diagnostics.filter { $0.severity == .warning }
        #expect(warnings.map(\.filePath) == ["\(Self.root)/Sources/IconquerAI/Policy.swift"])
        #expect(verdict.diagnostics.last?.message
                == "2 warnings in dependency mlx-swift were not counted; they are not this package's source")
    }

    @Test("A warning in the package's own derived sources is counted")
    func derivedSourceWarningIsCounted() {
        let derived = "\(Self.derivedData)/Build/Intermediates.noindex/IconquerAI.build/Debug/IconquerAI-t.build/DerivedSources/resource_bundle_accessor.swift:3:1: warning: something"
        let verdict = Self.verdict(derived)

        #expect(verdict.status == .warning)
        #expect(verdict.diagnostics.count == 1)
    }

    @Test("A dependency error still surfaces and the build is failed")
    func dependencyErrorStillFails() {
        let error = "\(Self.derivedData)/SourcePackages/checkouts/mlx-swift/Source/MLX/Array.swift:9:5: error: cannot find 'foo' in scope"
        let verdict = Self.verdict(Self.metalWarnings + "\n" + error, failed: true)

        #expect(verdict.status == .failed)
        let errors = verdict.diagnostics.filter { $0.severity == .error }
        #expect(errors.map(\.message) == ["cannot find 'foo' in scope"])
        #expect(verdict.diagnostics.filter { $0.severity == .warning }.isEmpty)
    }

    @Test("A dependency error is kept even if the exit code were lost")
    func dependencyErrorIsNeverScoped() {
        let error = "\(Self.derivedData)/SourcePackages/checkouts/mlx-swift/Source/MLX/Array.swift:9:5: error: cannot find 'foo' in scope"
        let verdict = Self.verdict(error)

        #expect(verdict.diagnostics.filter { $0.severity == .error }.count == 1)
    }

    @Test("The verdict agrees with its diagnostics: reconciliation adds nothing")
    func verdictNeedsNoReconciliation() {
        let verdict = Self.verdict(Self.metalWarnings)
        let result = CheckResult(
            checkerId: "xcode-build", status: verdict.status, diagnostics: verdict.diagnostics, duration: .zero)

        #expect(result.reconciled().status == .passed)
        #expect(result.reconciled().diagnostics == verdict.diagnostics)
    }

    @Test("The same warning under two spellings of one path is scoped out once per spelling, and counted so")
    func countIsOfWhatWasParsed() {
        let dotted = "\(Self.derivedData)/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/steel/attn/kernels/../../../complex.h:157:54: warning: 'static_assert' with no message is a C++17 extension [-Wc++17-extensions]"
        let verdict = Self.verdict(Self.metalWarnings + "\n" + dotted + "\n" + dotted)

        #expect(verdict.diagnostics.map(\.message)
                == ["3 warnings in dependency mlx-swift were not counted; they are not this package's source"])
    }
}
