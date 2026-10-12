import Foundation
import Testing
import QualityGateCore
@testable import BuildChecker

/// A throwaway package the warm-build tests build with the real toolchain.
///
/// One library target and one test target. `Warns.swift` drops the result of `loud()` at
/// line 6, column 9 — the "result of call is unused" warning that prompted the proposal —
/// and `Clean.swift` compiles clean, so the two can be edited independently.
struct WarmBuildFixture {
    let root: URL

    static let warnsSource = """
        public enum Warns {
            public static func loud() -> Int { 42 }

            public static func caller() {
                // The result is deliberately dropped.
                loud()
            }
        }

        """

    static let fixedWarnsSource = """
        public enum Warns {
            public static func loud() -> Int { 42 }

            public static func caller() {
                // The result is deliberately dropped.
                _ = loud()
            }
        }

        """

    static let cleanSource = """
        public enum Clean {
            public static let answer = 42
        }

        """

    /// Creates the package under the temporary directory. Nothing is built.
    ///
    /// - Parameters:
    ///   - name: The package and library target name.
    ///   - parent: The directory to create the package in; a fresh one when `nil`.
    ///   - dependencyPath: A sibling package to depend on by path, or `nil`.
    init(name: String = "Fixture", parent: URL? = nil, dependencyPath: String? = nil) throws {
        let directory = parent ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("qg-warm-build-\(UUID().uuidString)")
        root = directory.appendingPathComponent(name)

        let dependencies = dependencyPath.map { "dependencies: [.package(path: \"\($0)\")]," } ?? ""
        let targetDependencies = dependencyPath.map { path in
            "dependencies: [.product(name: \"\((path as NSString).lastPathComponent)\", package: \"\((path as NSString).lastPathComponent)\")]"
        }
        try write("Package.swift", """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "\(name)",
                products: [.library(name: "\(name)", targets: ["\(name)"])],
                \(dependencies)
                targets: [
                    .target(name: "\(name)"\(targetDependencies.map { ", \($0)" } ?? "")),
                    .testTarget(name: "\(name)Tests", dependencies: ["\(name)"]),
                ]
            )

            """)
        try write("Sources/\(name)/Warns.swift", Self.warnsSource)
        try write("Sources/\(name)/Clean.swift", Self.cleanSource)
        // Not `@testable`: a release build does not enable testing, and one test builds release.
        try write("Tests/\(name)Tests/\(name)Tests.swift", """
            import \(name)

            enum \(name)Tests {
                static let answer = Clean.answer
            }

            """)
    }

    /// Removes the package and the directory it was created in.
    func remove() {
        do {
            try FileManager.default.removeItem(at: root.deletingLastPathComponent())
        } catch {
            Issue.record("could not remove \(root.path): \(error)")
        }
    }

    /// Writes a file under the package root.
    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Deletes a file under the package root.
    func delete(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))
    }

    /// Runs the real checker against the package.
    func check(buildConfiguration: String? = nil) async throws -> CheckResult {
        var configuration = Configuration()
        configuration.projectRoot = root
        configuration.buildConfiguration = buildConfiguration
        return try await BuildChecker().check(configuration: configuration)
    }

    /// The paths of every file named `name` under the package's build directory.
    func buildProducts(named name: String) -> [String] {
        let buildDirectory = root.appendingPathComponent(".build").path
        guard let walker = FileManager.default.enumerator(atPath: buildDirectory) else { return [] }
        var found: [String] = []
        while let relative = walker.nextObject() as? String {
            if (relative as NSString).lastPathComponent == name {
                found.append((buildDirectory as NSString).appendingPathComponent(relative))
            }
        }
        return found
    }
}

extension CheckResult {
    /// The compiler warnings in this result — not the checker's own findings about coverage.
    var compilerWarnings: [Diagnostic] {
        diagnostics.filter { $0.severity == .warning && $0.ruleId == "swift-compiler" }
    }

    /// The warnings located in a file with this name, as `line:column` strings.
    func warningLocations(inFileNamed name: String) -> [String] {
        compilerWarnings
            .filter { ($0.filePath.map { ($0 as NSString).lastPathComponent }) == name }
            .map { "\($0.lineNumber ?? 0):\($0.columnNumber ?? 0)" }
    }

    /// The first diagnostic with this rule, if any.
    func finding(_ ruleId: String) -> Diagnostic? {
        diagnostics.first { $0.ruleId == ruleId }
    }

    /// The three counts in the coverage note — total, compiled by this run, read — or `nil`
    /// when the result carries no note or the note is not in the expected form.
    var coverageCounts: (units: Int, compiled: Int, read: Int)? {
        guard let message = finding("build.diagnostic-coverage")?.message else { return nil }
        let pattern = /(\d+) Swift compile unit\(s\): (\d+) compiled by this run, (\d+) read from recorded diagnostics/
        guard let match = message.firstMatch(of: pattern),
              let units = Int(match.1), let compiled = Int(match.2), let read = Int(match.3) else {
            return nil
        }
        return (units, compiled, read)
    }
}
