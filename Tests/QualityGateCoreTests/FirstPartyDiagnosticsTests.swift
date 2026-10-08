// FirstPartyDiagnosticsTests.swift
// QualityGateCoreTests

import Testing
import QualityGateTypes
@testable import QualityGateCore

@Suite("First-party diagnostic scoping")
struct FirstPartyDiagnosticsTests {

    @Test("Drops a warning from a dependency checkout")
    func dropsDependencyWarning() {
        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "constexpr if is a C++17 extension",
                filePath: "/repo/.build/checkouts/mlx-swift/Source/Cmlx/kernel.h",
                lineNumber: 108,
                ruleId: "swift-compiler"
            )
        ]
        #expect(diagnostics.scopedToFirstParty().isEmpty)
    }

    @Test("Drops a build-artifact warning whose path is only in the message")
    func dropsArtifactMessageWarning() {
        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "missing creator for mutated node: ('/repo/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS')",
                ruleId: "docc"
            )
        ]
        #expect(diagnostics.scopedToFirstParty().isEmpty)
    }

    @Test("Keeps a warning in first-party source")
    func keepsFirstPartyWarning() {
        let diagnostics = [
            Diagnostic(
                severity: .warning,
                message: "No documentation for 'foo'",
                filePath: "/repo/Sources/MyModule/File.swift",
                lineNumber: 10,
                ruleId: "docc"
            )
        ]
        #expect(diagnostics.scopedToFirstParty().count == 1)
    }

    @Test("Keeps an error even inside a dependency checkout")
    func keepsDependencyError() {
        let diagnostics = [
            Diagnostic(
                severity: .error,
                message: "cannot find type 'Foo' in scope",
                filePath: "/repo/.build/checkouts/somedep/Sources/File.swift",
                lineNumber: 5,
                ruleId: "swift-compiler"
            )
        ]
        #expect(diagnostics.scopedToFirstParty().count == 1)
    }

    @Test("Keeps a first-party note and a warning with no path")
    func keepsFirstPartyNoteAndPathlessWarning() {
        let diagnostics = [
            Diagnostic(severity: .note, message: "Documentation coverage: 100%", ruleId: "doc-coverage-summary"),
            Diagnostic(severity: .warning, message: "Institutional consistency below threshold", ruleId: "consistency")
        ]
        #expect(diagnostics.scopedToFirstParty().count == 2)
    }

    @Test("Preserves order of surviving diagnostics")
    func preservesOrder() {
        let diagnostics = [
            Diagnostic(severity: .warning, message: "first", filePath: "/repo/Sources/A.swift", ruleId: "r"),
            Diagnostic(severity: .warning, message: "dep", filePath: "/repo/.build/checkouts/x/B.swift", ruleId: "r"),
            Diagnostic(severity: .warning, message: "third", filePath: "/repo/Sources/C.swift", ruleId: "r")
        ]
        let kept = diagnostics.scopedToFirstParty()
        #expect(kept.map(\.message) == ["first", "third"])
    }

    // MARK: - Where a dependency lives, under each build system

    private static let derivedData = "/Users/x/Library/Developer/Xcode/DerivedData/App-fclwxvtespztqegq"
    private static let root = "/Users/x/Code/App"

    private static func warning(_ path: String, _ message: String = "w") -> Diagnostic {
        Diagnostic(severity: .warning, message: message, filePath: path, lineNumber: 1, ruleId: "xcode-compiler")
    }

    @Test("A path inside a dependency names the package, wherever the build system put it", arguments: [
        ("/Users/x/Code/App/.build/checkouts/mlx-swift/Source/Cmlx/kernel.h", "mlx-swift"),
        ("/Users/x/Library/Developer/Xcode/DerivedData/App-fclwxvtespztqegq/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/complex.h", "mlx-swift"),
        ("/tmp/scratch/dd/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/steel/attn/kernels/../../../complex.h", "mlx-swift"),
        ("/Users/x/Library/Developer/Xcode/DerivedData/App-fclwxvtespztqegq/SourcePackages/artifacts/sentry/Sentry.xcframework/Headers/Sentry.h", "sentry"),
        ("/Users/x/Code/App/.build/artifacts/sentry/Sentry.xcframework/Headers/Sentry.h", "sentry"),
    ])
    func dependencyPathsNameTheirPackage(path: String, package: String) {
        #expect(DependencyOrigin.of(path: path, projectRoot: Self.root) == .package(package))
        #expect(DependencyOrigin.of(path: path, projectRoot: nil) == .package(package))
    }

    @Test("A path under .build that is not a checkout is the build directory's", arguments: [
        "/Users/x/Code/App/.build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/MacOS",
        "/Users/x/Code/App/.build/arm64-apple-macosx/debug/App.build/DerivedSources/resource_bundle_accessor.swift",
        "/Users/x/Code/App/.build/plugins/outputs/app/App/Gen/Generated.swift",
    ])
    func buildDirectoryPaths(path: String) {
        #expect(DependencyOrigin.of(path: path, projectRoot: Self.root) == .buildDirectory)
    }

    /// Every kind of path xcodebuild reports for the package's own code. None of them may be
    /// scoped out: the first is source, and the rest are files the build derives from it.
    @Test("First-party paths xcodebuild reports are not a dependency's", arguments: [
        // Source in the package.
        "/Users/x/Code/App/Sources/App/File.swift",
        "/Users/x/Code/App/Tests/AppTests/FileTests.swift",
        "/Users/x/Code/App/Package.swift",
        // The package's own DerivedData intermediates.
        "/Users/x/Library/Developer/Xcode/DerivedData/App-fclwxvtespztqegq/Build/Intermediates.noindex/App.build/Debug/App-t.build/DerivedSources/resource_bundle_accessor.swift",
        "/Users/x/Library/Developer/Xcode/DerivedData/App-fclwxvtespztqegq/Build/Intermediates.noindex/App.build/Debug-iphonesimulator/App.build/DerivedSources/GeneratedAssetSymbols.swift",
        "/Users/x/Library/Developer/Xcode/DerivedData/App-fclwxvtespztqegq/Build/Intermediates.noindex/App.build/Debug/App.build/DerivedSources/CoreDataGenerated/Model/Entity+CoreDataClass.swift",
        // Build-tool plugin output: under SourcePackages, but not under checkouts.
        "/Users/x/Library/Developer/Xcode/DerivedData/App-fclwxvtespztqegq/SourcePackages/plugins/app.output/App/GenPlugin/Generated.swift",
        // Macro expansion buffers.
        "/var/folders/gt/abc/T/swift-generated-sources/@__swiftmacro_3App7MyModelC5ModelfMm_.swift",
        "/Users/x/Library/Developer/Xcode/DerivedData/App-fclwxvtespztqegq/Build/Intermediates.noindex/App.build/Debug/App.build/Objects-normal/arm64/@__swiftmacro_3App4ViewV7PreviewfMf_.swift",
        // A local path dependency and an edited package: compiled from where they are, and counted.
        "/Users/x/Code/Sibling/Sources/Sibling/File.swift",
        "/Users/x/Code/App/Packages/Edited/Sources/Edited/File.swift",
        // A project that keeps a directory called checkouts.
        "/Users/x/Code/App/Sources/checkouts/Cart.swift",
    ])
    func firstPartyPathsAreNotDependencies(path: String) {
        #expect(DependencyOrigin.of(path: path, projectRoot: Self.root) == nil)
        #expect(DependencyOrigin.of(path: path, projectRoot: nil) == nil)
        #expect([Self.warning(path)].scopedToFirstParty(projectRoot: Self.root).count == 1)
    }

    @Test("A package that is itself checked out under a build directory still owns its source")
    func rootInsideABuildDirectoryIsStillFirstParty() {
        let root = "/Users/x/Code/Host/.build/checkouts/App"
        #expect(DependencyOrigin.of(path: root + "/Sources/App/File.swift", projectRoot: root) == nil)
        #expect(DependencyOrigin.of(path: root + "/.build/checkouts/dep/Sources/D.swift", projectRoot: root)
                == .package("dep"))
        let xcodeRoot = Self.derivedData + "/SourcePackages/checkouts/App"
        #expect(DependencyOrigin.of(path: xcodeRoot + "/Sources/App/File.swift", projectRoot: xcodeRoot) == nil)
        // A sibling checkout is outside the root and is still a dependency.
        #expect(DependencyOrigin.of(
            path: Self.derivedData + "/SourcePackages/checkouts/dep/Sources/D.swift", projectRoot: xcodeRoot)
                == .package("dep"))
    }

    @Test("Drops a warning from an Xcode dependency checkout, keeps its error")
    func xcodeCheckoutWarningDroppedErrorKept() {
        let path = Self.derivedData + "/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/complex.h"
        let error = Diagnostic(severity: .error, message: "no member", filePath: path, lineNumber: 2, ruleId: "r")
        let kept = [Self.warning(path), error].scopedToFirstParty(projectRoot: Self.root)
        #expect(kept == [error])
    }

    // MARK: - Nothing is dropped silently

    @Test("Scoping nothing out says nothing")
    func noNoteWhenNothingScoped() {
        let scope = [Self.warning("/Users/x/Code/App/Sources/App/File.swift")].firstPartyScope(projectRoot: Self.root)
        #expect(scope.note == nil)
        #expect(scope.scopedOut.isEmpty)
        #expect(scope.reported == scope.counted)
    }

    @Test("The note counts what was scoped out and names the package")
    func noteNamesOnePackage() {
        let base = Self.derivedData + "/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/"
        let diagnostics = (1...20).map { Self.warning(base + "complex.h", "w\($0)") }
        let scope = diagnostics.firstPartyScope(projectRoot: Self.root)
        #expect(scope.counted.isEmpty)
        #expect(scope.scopedOut.count == 20)
        #expect(scope.note?.severity == .note)
        #expect(scope.note?.ruleId == "gate.dependency-diagnostics-not-counted")
        #expect(scope.note?.message
                == "20 warnings in dependency mlx-swift were not counted; they are not this package's source")
        #expect(scope.reported.count == 1)
    }

    @Test("One warning is singular")
    func noteSingular() {
        let scope = [Self.warning("/Users/x/Code/App/.build/checkouts/dep/S.swift")].firstPartyScope()
        #expect(scope.note?.message
                == "1 warning in dependency dep was not counted; it is not this package's source")
    }

    @Test("Several origins are each named with their own count, largest first")
    func noteNamesEveryOrigin() {
        let diagnostics = [
            Self.warning("/Users/x/Code/App/.build/checkouts/swift-nio/A.swift", "a"),
            Self.warning("/Users/x/Code/App/.build/checkouts/mlx-swift/B.h", "b"),
            Self.warning("/Users/x/Code/App/.build/checkouts/mlx-swift/C.h", "c"),
            Diagnostic(severity: .note, message: "expanded from here",
                       filePath: "/Users/x/Code/App/.build/checkouts/mlx-swift/C.h", ruleId: "r"),
            Diagnostic(severity: .warning,
                       message: "missing creator for mutated node: ('/Users/x/Code/App/.build/out/Products/Debug/x.bundle/Contents/MacOS')",
                       ruleId: "docc"),
        ]
        let scope = diagnostics.firstPartyScope(projectRoot: Self.root)
        #expect(scope.counted.isEmpty)
        #expect(scope.note?.message
                == "4 warnings and 1 note in dependencies mlx-swift (3) and swift-nio (1), and the build directory (1), "
                + "were not counted; they are not this package's source")
    }

    @Test("The note is not itself something the scope would drop")
    func noteSurvivesRescoping() throws {
        let scope = [Self.warning("/Users/x/Code/App/.build/out/gen.swift")].firstPartyScope(projectRoot: Self.root)
        let note = try #require(scope.note)
        #expect(note.message
                == "1 warning in the build directory was not counted; it is not this package's source")
        #expect(scope.reported.scopedToFirstParty(projectRoot: Self.root) == scope.reported)
    }
}
