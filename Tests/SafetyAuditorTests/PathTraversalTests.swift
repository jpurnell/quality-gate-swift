import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// Traversal is a join.
///
/// `security.path-traversal` used to report every `FileManager` call whose path was not a
/// literal — 238 in the gate's own source, nearly all existence probes or paths received whole.
/// Traversal happens where an untrusted segment is joined onto a directory and the result is
/// read or written; that is where it is reported now, and a sound containment check clears it.
/// The unsound one — a string prefix with no separator — is its own error.
///
/// See `quality-gate-swift-project/plans/proposals/TraversalIsAJoin.md`.
@Suite("Path traversal")
struct PathTraversalTests {

    private func audit(_ body: String) async throws -> CheckResult {
        let code = """
            import Foundation
            func run(base: URL, root: String, dir: String, name: String, sub: String, path: String, n: Int) throws {
                let fm = FileManager.default
            \(body)
            }
            """
        return try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: Configuration())
    }

    private func traversal(_ result: CheckResult) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == "security.path-traversal" }
    }

    private func prefix(_ result: CheckResult) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == "security.path-containment-by-prefix" }
    }

    // MARK: - Not traversal

    @Test("An existence probe is not a sink")
    func probeIsNotReported() async throws {
        #expect(traversal(try await audit("_ = fm.fileExists(atPath: path)")).isEmpty)
        #expect(traversal(try await audit("_ = try fm.attributesOfItem(atPath: path)")).isEmpty)
    }

    @Test("A path received whole is the caller's")
    func wholePathIsNotReported() async throws {
        #expect(traversal(try await audit("_ = fm.contents(atPath: path)")).isEmpty)
        #expect(traversal(try await audit("try fm.removeItem(atPath: path)")).isEmpty)
    }

    @Test("A literal segment joins nothing anyone else chose")
    func literalSegmentIsNotReported() async throws {
        let result = try await audit("""
                let manifest = base.appendingPathComponent("Package.swift")
                _ = fm.contents(atPath: manifest.path)
            """)
        #expect(traversal(result).isEmpty)
    }

    // MARK: - Traversal

    @Test("A non-literal segment joined onto a base and read is reported")
    func joinedThenReadIsReported() async throws {
        let result = try await audit("""
                let target = base.appendingPathComponent(name)
                _ = fm.contents(atPath: target.path)
            """)
        #expect(traversal(result).count == 1)
    }

    @Test("A join written inline is reported", arguments: [
        "try fm.removeItem(atPath: dir + \"/\" + name)",
        "try fm.createDirectory(atPath: \"\\(root)/\\(sub)\", withIntermediateDirectories: true)",
        "_ = try fm.contentsOfDirectory(atPath: base.appending(path: sub).path)",
    ])
    func inlineJoinIsReported(body: String) async throws {
        #expect(traversal(try await audit("    " + body)).count == 1, "\(body)")
    }

    // MARK: - Cleared by a sound check

    @Test("A sound containment check clears it", arguments: [
        "guard target.standardizedFileURL.pathComponents.starts(with: base.pathComponents) else { return }",
        "guard PathContainment.isContained(target, in: base) else { return }",
        "guard target.path.hasPrefix(base.path + \"/\") else { return }",
        "guard target.isContained(in: base) else { return }",
    ])
    func soundCheckClears(check: String) async throws {
        let result = try await audit("""
                let target = base.appendingPathComponent(name)
                \(check)
                _ = fm.contents(atPath: target.path)
            """)
        #expect(traversal(result).isEmpty, "\(check)")
        #expect(prefix(result).isEmpty, "\(check)")
    }

    // MARK: - The check that does not hold

    @Test("A prefix check with no separator does not clear, and is its own error")
    func bareprefixDoesNotClear() async throws {
        let result = try await audit("""
                let target = base.appendingPathComponent(name)
                guard target.path.hasPrefix(base.path) else { return }
                _ = fm.contents(atPath: target.path)
            """)
        #expect(traversal(result).count == 1)
        let finding = try #require(prefix(result).first)
        #expect(finding.severity == .error)
        #expect(finding.message.contains("CWE-22"))
    }

    @Test("A bare path prefix check is an error wherever it appears", arguments: [
        "guard path.hasPrefix(root) else { return }",
        "if base.path.hasPrefix(dir) { return }",
    ])
    func bareprefixIsError(check: String) async throws {
        #expect(prefix(try await audit("    " + check)).count == 1, "\(check)")
    }

    @Test("A prefix check that is not about paths is left alone", arguments: [
        "if name.hasPrefix(\"tmp\") { return }",
        "if sub.hasPrefix(name) { return }",
        "guard path.hasPrefix(\"/\") else { return }",
    ])
    func unrelatedPrefixIsClean(check: String) async throws {
        #expect(prefix(try await audit("    " + check)).isEmpty, "\(check)")
    }
}

/// What the gate's own source taught the rule: joins that cannot escape, and prefix tests that
/// are arithmetic rather than decisions.
@Suite("Path traversal — precision")
struct PathTraversalPrecisionTests {

    private func audit(_ body: String) async throws -> CheckResult {
        let code = """
            import Foundation
            func run(base: URL, root: String, dir: String, name: String, path: String, files: [String]) throws {
                let fm = FileManager.default
            \(body)
            }
            """
        return try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: Configuration())
    }

    private func count(_ result: CheckResult, _ rule: String) -> Int {
        result.diagnostics.filter { $0.ruleId == rule }.count
    }

    @Test("A suffix on a file name is not a join", arguments: [
        "try fm.removeItem(atPath: path + \".backup-\\(name)\")",
        "_ = fm.contents(atPath: \"\\(root)/telemetry\")",
        "try fm.createDirectory(atPath: path ?? (root as NSString).appendingPathComponent(\".build/x\"), withIntermediateDirectories: true)",
    ])
    func suffixIsNotAJoin(body: String) async throws {
        #expect(count(try await audit("    " + body), "security.path-traversal") == 0, "\(body)")
    }

    @Test("A segment from a loop over literals cannot escape")
    func literalLoopIsSafe() async throws {
        let result = try await audit("""
                for spelling in ["Sources", "Source", "src"] {
                    _ = try fm.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(spelling))
                }
                let containers: [(String, String)] = [("Sources", "library"), ("Tests", "test")]
                for (container, _) in containers {
                    _ = try fm.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(container))
                }
            """)
        #expect(count(result, "security.path-traversal") == 0)
    }

    /// A name `contentsOfDirectory` returned cannot contain `/` and is never `..`.
    @Test("A segment listed from the directory cannot escape it")
    func listedEntryIsSafe() async throws {
        let result = try await audit("""
                let contents = try fm.contentsOfDirectory(atPath: path)
                for item in contents {
                    try fm.removeItem(atPath: (path as NSString).appendingPathComponent(item))
                }
            """)
        #expect(count(result, "security.path-traversal") == 0)
    }

    @Test("A segment from a loop over input still can", arguments: ["for f in files {", "for f in name.split(separator: \",\") {"])
    func loopOverInputIsReported(loop: String) async throws {
        let result = try await audit("""
                \(loop)
                    _ = fm.contents(atPath: (path as NSString).appendingPathComponent(String(f)))
                }
            """)
        #expect(count(result, "security.path-traversal") == 1, "\(loop)")
    }

    @Test("A configured checker called as a statement clears it")
    func throwingValidatorClears() async throws {
        var config = Configuration()
        config.security.containmentCheckers = ["Guard.confine"]
        let result = try await SafetyAuditor().auditSource("""
            import Foundation
            func run(base: URL, name: String) throws {
                let target = base.appendingPathComponent(name)
                try Guard.confine(target, to: base)
                _ = FileManager.default.contents(atPath: target.path)
            }
            """, fileName: "test.swift", configuration: config)
        #expect(count(result, "security.path-traversal") == 0)
    }

    @Test("A prefix test that computes a relative path is not a decision", arguments: [
        "let rel = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path",
        "return path.hasPrefix(dir) || path.contains(dir)",
    ])
    func arithmeticPrefixIsNotReported(body: String) async throws {
        #expect(count(try await audit("    " + body), "security.path-containment-by-prefix") == 0, "\(body)")
    }

    @Test("A prefix test that filters files by directory is a decision")
    func filterPrefixIsReported() async throws {
        let result = try await audit("    let mine = files.filter { $0.hasPrefix(dir) }")
        #expect(count(result, "security.path-containment-by-prefix") == 1)
    }

    /// Measured across the portfolio before deploying: correct checks that put the separator in
    /// a local, a name that merely contains "base", and a loop over literal URL prefixes.
    @Test("A separator added through a local is a separated prefix")
    func separatorInALocal() async throws {
        let result = try await audit("""
                let prefix = root.hasSuffix("/") ? root : root + "/"
                guard path.hasPrefix(prefix) else { return }
            """)
        #expect(count(result, "security.path-containment-by-prefix") == 0)
    }

    @Test("A name that contains a path word without being one is not path-shaped")
    func wholeWordsOnly() async throws {
        let result = try await audit("""
                let base64SentinelPrefix = name
                guard name.hasPrefix(base64SentinelPrefix) else { return }
            """)
        #expect(count(result, "security.path-containment-by-prefix") == 0)
    }

    @Test("A loop over literal prefixes is not a containment check")
    func literalPrefixLoop() async throws {
        let result = try await audit("""
                for prefix in ["/css/", "/js/"] {
                    if path.hasPrefix(prefix) { return }
                }
            """)
        #expect(count(result, "security.path-containment-by-prefix") == 0)
    }

    /// A UUID or a process identifier cannot contain a separator; a temp path built from one is
    /// not a join anyone else chose. Two corpus-kit fixtures were reported for it.
    @Test("A generated identifier is not a chosen segment", arguments: [
        "try fm.removeItem(atPath: \"/tmp/fixture-\\(UUID().uuidString)\")",
        "try fm.createDirectory(atPath: root + \"/run-\" + UUID().uuidString, withIntermediateDirectories: true)",
        "try fm.removeItem(atPath: \"\\(root)/\\(ProcessInfo.processInfo.globallyUniqueString)\")",
    ])
    func generatedIdentifierIsSafe(body: String) async throws {
        #expect(count(try await audit("    " + body), "security.path-traversal") == 0, "\(body)")
    }
}

