import Foundation
import QualityGateCore
import Testing
@testable import IndexStoreInfra

/// A nested package is a different package.
///
/// The walk's governing question is what *this* repository owns and can fix. `.gitignore`
/// answers it for vendored trees, but not for a directory carrying its own `Package.swift`:
/// that is a second package, with its own manifest, targets and rules, that this package
/// neither builds nor releases. Auditing it reports our house rules against someone else's
/// code — the same incoherence the git-ignore rule exists to prevent, arriving by a
/// different route.
///
/// This repository has one: the `docref` prototype kept as the evidence behind a written
/// proposal. Widening `safety` to the whole root reported seven findings against a frozen
/// artifact whose value is being a record of what was tried.
@Suite("SourceWalker — nested packages")
struct NestedPackageWalkTests {

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qg-nested-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a directory with its own Package.swift is not descended into")
    func nestedPackageIsSkipped() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("// swift-tools-version:6.0", to: root.appendingPathComponent("Package.swift"))
        try write("func ours() {}", to: root.appendingPathComponent("Sources/Ours.swift"))
        try write("// swift-tools-version:6.0",
                  to: root.appendingPathComponent("prototype/Package.swift"))
        try write("func theirs() {}",
                  to: root.appendingPathComponent("prototype/Sources/Theirs.swift"))

        let result = SourceWalker.walk(under: root)

        // Two: our source and our own `Package.swift`. A manifest is Swift the package owns
        // and builds with, so the walk reads it — it is the *nested* one that is another
        // package's business.
        #expect(result.files.count == 2, "expected our source and our manifest; got \(result.files)")
        #expect(result.files.allSatisfy { !$0.contains("/prototype/") },
                "the nested package was walked: \(result.files)")
        #expect(result.nestedPackageDirectories == 1)
        #expect(result.exclusionClause?.contains("1 nested package") == true,
                "the walk must say it skipped a package; got \(result.exclusionClause ?? "nil")")
    }

    /// The root's own manifest must not exclude the root.
    ///
    /// The rule is "a *nested* package", and the cheapest wrong implementation — test every
    /// directory for `Package.swift` — skips the very tree it was asked to walk and reports
    /// a clean pass over zero files.
    @Test("the root's own Package.swift does not skip the root")
    func rootManifestDoesNotSkipRoot() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("// swift-tools-version:6.0", to: root.appendingPathComponent("Package.swift"))
        try write("func ours() {}", to: root.appendingPathComponent("Sources/Ours.swift"))

        let result = SourceWalker.walk(under: root)

        #expect(result.files.count == 2, "the root walked itself away: \(result.files)")
        #expect(result.nestedPackageDirectories == 0)
        #expect(result.exclusionClause == nil)
    }

    /// A tree with no nested package must report nothing, so the clause keeps its meaning.
    @Test("an ordinary tree reports no nested packages")
    func ordinaryTreeSaysNothing() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("func a() {}", to: root.appendingPathComponent("Sources/A.swift"))
        try write("func b() {}", to: root.appendingPathComponent("Tests/B.swift"))

        let result = SourceWalker.walk(under: root)

        #expect(result.files.count == 2)
        #expect(result.nestedPackageDirectories == 0)
        #expect(result.exclusionClause == nil)
    }
}
