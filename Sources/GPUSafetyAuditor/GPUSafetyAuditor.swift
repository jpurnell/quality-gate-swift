import Foundation
import IndexStoreInfra
import QualityGateCore

/// Finds Metal kernels that cannot be correct, and the dispatch sites that create
/// the conditions for silent memory corruption.
///
/// ## What a green result means
///
/// Less than it looks, and the catalogue says so deliberately. This checker finds
/// kernels that are *certainly* wrong — a thread id indexing buffers with no bound
/// ever applied to it — and dispatches that round up. It does not and cannot decide
/// whether a guard that *is* present uses the right bound: `tid >= numOps`
/// type-checks exactly as well as `tid >= iterations`.
///
/// A reader who takes a clean `gpu-safety` run as proof of correctness has misread
/// it. `MTL_SHADER_VALIDATION=1` under the test suite is the companion that catches
/// what static analysis cannot; the two are complementary rather than competing,
/// since this runs in seconds on a machine with no GPU.
///
/// ## Coverage is reported, never assumed
///
/// Every run states how many shader sources it read and of which kind. Finding no
/// shader source is reported as such rather than as a pass — a checker that examined
/// nothing must not print what a checker that found nothing prints, and this suite
/// has shipped that bug twice before.
public struct GPUSafetyAuditor: QualityChecker, Sendable {

    /// Unique identifier for this checker.
    public let id = "gpu-safety"

    /// Human-readable display name.
    public let name = "GPU Safety Auditor"

    /// One sentence: what this checker finds.
    public let summary = "Metal kernels that index by thread id with no bound, and dispatches that round up — the conditions for silent out-of-bounds reads and writes"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.safetySecurity

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Creates a GPU safety auditor.
    public init() {}

    /// Declares this checker cacheable on the source tree it reads.
    ///
    /// Syntactic analysis over the sources, with no clock, corpus, network or out-of-tree path
    /// among its inputs — so the same tree under the same gate binary yields the same verdict.
    /// `gateIdentityHash` folds in the binary's identity and the toolchain, so a rebuild or a
    /// compiler change invalidates every entry.
    ///
    /// `wholeSourceAndDocs` rather than `wholeSource`: it is the wider set, and over-including
    /// an input costs a cache miss while under-including one serves a stale pass.
    public func cacheInputs(configuration: Configuration) -> CacheInputs? {
        SourceCacheInputs.wholeSourceAndDocs(
            projectRoot: configuration.resolvedProjectRoot,
            configuration: configuration
        )
    }

    /// Audits Metal shader source and Swift dispatch sites.
    ///
    /// - Parameter configuration: Project configuration.
    /// - Returns: A `CheckResult` carrying the diagnostics and a coverage line.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let started = ContinuousClock.now
        let root = configuration.resolvedProjectRoot.path
        let scan = Self.scan(root: root, excludePatterns: configuration.excludePatterns)

        var diagnostics = scan.diagnostics
        // Emitted on every run, pass or fail, including when the answer is zero.
        diagnostics.append(Diagnostic(
            severity: .note,
            message: scan.coverageLine,
            ruleId: "gpu-safety.coverage"))

        let failed = diagnostics.contains { $0.severity == .error }
        return CheckResult(
            checkerId: id,
            status: failed ? .failed : .passed,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - started)
    }

    /// What one scan found, and what it looked at.
    public struct Scan: Sendable {
        /// Every diagnostic, ordered by file then line.
        public let diagnostics: [Diagnostic]
        /// Human-readable coverage, printed on every run including a clean one.
        public let coverageLine: String
    }

    /// Scans a directory tree. Pure over the file system it is given.
    ///
    /// - Parameters:
    ///   - root: Directory to scan.
    ///   - excludePatterns: Glob patterns from configuration. Glob markers are stripped and
    ///     the remainder matched as a substring of the relative path, which is the rule
    ///     `SourceWalker` already applies. A checker that walks the tree itself has to honour
    ///     the project's exclusions explicitly, or the documented key silently does nothing
    ///     here — which is how a repository can carry a correct `excludePatterns` entry and
    ///     still be unable to make this checker stop reading a directory.
    /// - Returns: Diagnostics and a coverage statement.
    public static func scan(root: String, excludePatterns: [String] = []) -> Scan {
        let fileManager = FileManager.default
        // silent: no readable manifest means no exclude lists, so every .metal file is treated as compiled
        let manifest = (try? String(
            contentsOfFile: root + "/Package.swift", encoding: .utf8)) ?? ""

        var diagnostics: [Diagnostic] = []
        var metalFileCount = 0
        var embeddedCount = 0
        var kernelCount = 0
        var deadFileCount = 0

        guard let walker = fileManager.enumerator(atPath: root) else {
            return Scan(
                diagnostics: [],
                coverageLine: "shaders: could not read \(root) — nothing examined")
        }

        for case let relative as String in walker {
            if relative.contains(".build/") || relative.contains(".git/") { continue }
            // A kernel inside a test file is an *input* to a test, not a shader the
            // program dispatches. This checker's own fixtures are deliberately
            // unbounded kernels; auditing them would make the suite that proves the
            // rule work into eight permanent errors, and the fix would be to stop
            // testing the rule.
            if relative.hasPrefix("Tests/") || relative.contains("/Tests/") { continue }
            if isExcluded(relativePath: relative, patterns: excludePatterns) { continue }
            let fullPath = root + "/" + relative

            if relative.hasSuffix(".metal") {
                metalFileCount += 1
                // silent: an unreadable shader is counted in coverage but not audited, never reported clean
                guard let text = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                    continue
                }
                let excluded = ShaderSourceLocator.isExcluded(
                    metalPath: relative, manifest: manifest)
                if excluded {
                    deadFileCount += 1
                    diagnostics.append(Diagnostic(
                        severity: .note,
                        message: """
                            `\(relative)` is excluded from every target, so nothing compiles it. \
                            Any kernel here is dead code — and if a dispatch resolves these \
                            function names at runtime it cannot find them.
                            """,
                        filePath: fullPath,
                        lineNumber: 1,
                        ruleId: "gpu.dead-shader-file"))
                }
                let kernels = MetalKernelParser.kernels(
                    in: text,
                    source: .metalFile(path: fullPath, excludedFromTarget: excluded))
                kernelCount += kernels.count
                // A finding in a file nothing compiles is a statement about dead
                // code; reporting it as a defect in the program would be false.
                if !excluded {
                    diagnostics.append(contentsOf: kernels.flatMap(KernelBoundsRule.diagnose))
                }
            } else if relative.hasSuffix(".swift") {
                // silent: an unreadable Swift file yields no dispatch findings rather than failing the scan
                guard let text = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
                    continue
                }
                diagnostics.append(contentsOf: DispatchRules.diagnose(
                    swiftSource: text, path: fullPath))
                for located in ShaderSourceLocator.embeddedShaders(in: text, path: fullPath) {
                    embeddedCount += 1
                    let kernels = MetalKernelParser.kernels(
                        in: located.text, source: located.source)
                    kernelCount += kernels.count
                    diagnostics.append(contentsOf: kernels.flatMap(KernelBoundsRule.diagnose))
                }
            }
        }

        let sorted = diagnostics.sorted {
            ($0.filePath ?? "", $0.lineNumber ?? 0) < ($1.filePath ?? "", $1.lineNumber ?? 0)
        }
        let coverage = "shaders: \(metalFileCount) .metal file(s)"
            + " · \(embeddedCount) embedded literal(s)"
            + " · \(kernelCount) kernel(s) examined"
            + (deadFileCount > 0 ? " · \(deadFileCount) excluded from every target" : "")
        return Scan(diagnostics: sorted, coverageLine: coverage)
    }

    /// Whether `relativePath` matches any configured exclude pattern.
    ///
    /// Glob markers (`**/`, `/**`, `*`) are stripped and the remainder matched as a
    /// substring, which is exactly `SourceWalker.isExcluded`'s rule — a pattern has to mean
    /// the same thing whether a checker asks the shared walker for files or walks the tree
    /// itself, or the same entry excludes a path from one checker and not another.
    ///
    /// - Parameters:
    ///   - relativePath: Path relative to the scan root.
    ///   - patterns: Configured exclude patterns. Empty never matches.
    /// - Returns: `true` when any non-empty stripped pattern is a substring of the path.
    private static func isExcluded(relativePath: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            let stripped = pattern
                .replacingOccurrences(of: "**/", with: "")
                .replacingOccurrences(of: "/**", with: "")
                .replacingOccurrences(of: "*", with: "")
            if !stripped.isEmpty, relativePath.contains(stripped) { return true }
        }
        return false
    }
}
