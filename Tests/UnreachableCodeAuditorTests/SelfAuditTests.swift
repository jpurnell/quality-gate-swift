import Foundation
import Testing
@testable import UnreachableCodeAuditor
@testable import QualityGateCore

/// Runs the auditor's **syntactic** pass against its own source tree on
/// every test invocation. Any new dead code in `Sources/` (under
/// `quality-gate-swift`) breaks `swift test`.
///
/// The cross-module pass cannot run from inside `swift test`: it would
/// have to invoke `swift build` / `swift package describe` against the
/// same package, which deadlocks on SwiftPM's shared build cache. The
/// cross-module self-audit lives in the `scripts/self-audit.sh` shell
/// script (run separately in CI) instead.
///
/// Honors `.quality-gate.yml` so test fixtures with intentionally-dead
/// symbols are excluded.
@Suite("Self-audit (syntactic)")
struct SelfAuditTests {

    private static let packageRoot: URL = {
        let here = URL(fileURLWithPath: #filePath)
        return here
            .deletingLastPathComponent() // UnreachableCodeAuditorTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // quality-gate-swift root
    }()

    @Test("quality-gate-swift Sources/ has zero unreachable diagnostics")
    func selfSourcesAreClean() async throws {
        let configPath = Self.packageRoot.appendingPathComponent(".quality-gate.yml").path
        let config = (try? Configuration.load(from: configPath)) ?? Configuration()

        let sourcesDir = Self.packageRoot.appendingPathComponent("Sources")
        let files = SourceWalker.swiftFiles(under: sourcesDir, excludePatterns: config.excludePatterns)

        let auditor = UnreachableCodeAuditor()
        var allDiagnostics: [Diagnostic] = []
        for file in files {
            guard let src = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            let result = try await auditor.auditSource(src, fileName: file, configuration: config)
            allDiagnostics.append(contentsOf: result.diagnostics)
        }

        if !allDiagnostics.isEmpty {
            for d in allDiagnostics {
                Issue.record(
                    "Self-audit found dead code: \(d.file ?? "?"):\(d.line ?? 0) [\(d.severity.rawValue)] \(d.ruleId ?? "?"): \(d.message)"
                )
            }
        }
        #expect(allDiagnostics.isEmpty)
    }
}
