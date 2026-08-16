import Foundation
#if canImport(os)
import os
#endif
import QualityGateCore

/// A stable fingerprint of one normalized-token window, emitted for the
/// future cross-project corpus join (Phase 4c §2).
///
/// Fingerprints are winnowed window hashes: sparse, deterministic, and
/// comparable across packages and machines (FNV-1a, not per-process seeded).
public struct CloneFingerprint: Sendable, Codable, Equatable {
    /// 16-hex-digit FNV-1a hash of the normalized token window.
    public let hash: String
    /// Absolute path of the file containing the window.
    public let filePath: String
    /// 1-based line of the window's first token.
    public let startLine: Int
    /// 1-based line of the window's last token.
    public let endLine: Int
    /// Number of normalized tokens in the window.
    public let tokenCount: Int

    /// Creates a clone fingerprint.
    ///
    /// - Parameters:
    ///   - hash: 16-hex-digit FNV-1a hash of the window.
    ///   - filePath: Absolute path of the containing file.
    ///   - startLine: 1-based line of the window's first token.
    ///   - endLine: 1-based line of the window's last token.
    ///   - tokenCount: Number of normalized tokens in the window.
    public init(hash: String, filePath: String, startLine: Int, endLine: Int, tokenCount: Int) {
        self.hash = hash
        self.filePath = filePath
        self.startLine = startLine
        self.endLine = endLine
        self.tokenCount = tokenCount
    }
}

/// Sonar-parity duplicate-code detection over SwiftSyntax token streams.
///
/// Every `.swift` file under `Sources/` (and `Tests/` unless excluded) is
/// tokenized with trivia dropped, identifiers normalized to `ID`, and literal
/// content to `LIT` — so renamed-identifier clones are caught. Sliding
/// windows of ``DuplicationConfig/minTokens`` normalized tokens are hashed
/// with FNV-1a; matching windows merge into maximal clone blocks, and each
/// block pair is reported once under rule `duplication.clone`.
///
/// Advisory posture: findings are `.note` and the check passes unless
/// ``DuplicationConfig/warnOnClones`` escalates them to `.warning`.
public struct DuplicationAuditor: QualityChecker, Sendable {
    private static let logger = Logger(subsystem: "com.quality-gate", category: "DuplicationAuditor")

    /// Unique identifier for this checker.
    public let id = "duplication"
    /// Human-readable display name for this checker.
    public let name = "Duplication Auditor"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Token-level clone detection across files and modules (advisory)"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.codeHygiene

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// The rule identifier stamped on every clone diagnostic.
    static let ruleId = "duplication.clone"

    /// Detection thresholds and severity posture.
    private let config: DuplicationConfig
    /// Project root override; `nil` scans the current working directory.
    private let root: String?

    /// Creates a duplication auditor.
    ///
    /// - Parameters:
    ///   - config: Detection thresholds and posture (defaults per ``DuplicationConfig``).
    ///   - root: Project root to scan; `nil` uses the current directory.
    public init(config: DuplicationConfig = DuplicationConfig(), root: String? = nil) {
        self.config = config
        self.root = root
    }

    /// Runs in-package clone detection and reports each clone pair once.
    ///
    /// - Parameter configuration: The project configuration (unused; the
    ///   orchestrator injects ``DuplicationConfig`` at construction).
    /// - Returns: A result whose diagnostics name both clone locations,
    ///   sorted by path then line for deterministic output.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let start = ContinuousClock.now
        let files = collectFiles()
        let classes = CloneDetector.detectClasses(files: files, minTokens: config.minTokens)
        let severity: Diagnostic.Severity = config.warnOnClones ? .warning : .note

        var diagnostics: [Diagnostic] = []
        for cloneClass in classes {
            // Diversity floor: drop low-variety boilerplate whose representative
            // block spans too few distinct normalized token texts.
            guard let anchor = cloneClass.blocks.first,
                  anchor.file < files.count,
                  distinctTokenCount(in: files[anchor.file], start: anchor.start, count: cloneClass.tokenCount)
                      >= config.minDistinctTokens
            else { continue }

            // Render each member as `relativePath:startLine-endLine`, in order.
            var sites: [String] = []
            for block in cloneClass.blocks {
                guard block.file < files.count,
                      let span = files[block.file].lineSpan(start: block.start, count: block.tokenCount)
                else { continue }
                sites.append("\(files[block.file].relativePath):\(span.startLine)-\(span.endLine)")
            }
            guard sites.count >= 2 else { continue }

            let message = "\(cloneClass.tokenCount)-token clone across \(sites.count) sites: "
                + sites.joined(separator: " ≈ ")
            guard let anchorSpan = files[anchor.file].lineSpan(start: anchor.start, count: cloneClass.tokenCount)
            else { continue }
            diagnostics.append(Diagnostic(
                severity: severity,
                message: message,
                filePath: files[anchor.file].absolutePath,
                lineNumber: anchorSpan.startLine,
                ruleId: Self.ruleId
            ))
        }

        let status: CheckResult.Status =
            (config.warnOnClones && !diagnostics.isEmpty) ? .warning : .passed
        return CheckResult(
            checkerId: id,
            status: status,
            diagnostics: diagnostics,
            duration: ContinuousClock.now - start
        )
    }

    /// Winnowed per-window clone fingerprints for every scanned file.
    ///
    /// This is the corpus-facing API (Phase 4c §2): the future telemetry
    /// emission serializes these so the pulse can join clones portfolio-wide.
    /// The winnowing guarantee: any duplicate span of at least
    /// `2 × minTokens − 1` tokens shared with another package contributes at
    /// least one common fingerprint hash.
    ///
    /// - Returns: Fingerprints sorted by path, line, then hash — stable
    ///   across runs and processes.
    public func fingerprints() throws -> [CloneFingerprint] {
        let window = max(1, config.minTokens)
        var result: [CloneFingerprint] = []
        for file in collectFiles() {
            let hashes = CloneDetector.windowHashes(for: file, window: window)
            for index in CloneDetector.winnowedIndices(of: hashes, winnowWindow: window) {
                guard index < hashes.count,
                      let span = file.lineSpan(start: index, count: window) else { continue }
                result.append(CloneFingerprint(
                    hash: Self.hexString(hashes[index]),
                    filePath: file.absolutePath,
                    startLine: span.startLine,
                    endLine: span.endLine,
                    tokenCount: window
                ))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
            if lhs.startLine != rhs.startLine { return lhs.startLine < rhs.startLine }
            if lhs.endLine != rhs.endLine { return lhs.endLine < rhs.endLine }
            return lhs.hash < rhs.hash
        }
    }

    // MARK: - Private

    /// Number of distinct normalized token texts spanned by `count` tokens
    /// starting at `start` in `file`. Used by the diversity floor to reject
    /// low-variety boilerplate clones.
    private func distinctTokenCount(in file: FileTokenStream, start: Int, count: Int) -> Int {
        guard start >= 0, count > 0, start + count <= file.tokens.count else { return 0 }
        var seen: Set<String> = []
        for offset in 0..<count {
            seen.insert(file.tokens[start + offset].text)
        }
        return seen.count
    }

    /// Collects and tokenizes every `.swift` file under `Sources/` (and
    /// `Tests/` unless excluded), sorted by root-relative path.
    private func collectFiles() -> [FileTokenStream] {
        let fileManager = FileManager.default
        let rootPath = root ?? fileManager.currentDirectoryPath
        var directories = ["Sources"]
        if !config.excludeTests {
            directories.append("Tests")
        }

        var files: [FileTokenStream] = []
        for directory in directories {
            let directoryPath = (rootPath as NSString).appendingPathComponent(directory)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let enumerator = fileManager.enumerator(atPath: directoryPath) else { continue }

            var relativePaths: [String] = []
            while let entry = enumerator.nextObject() as? String {
                if entry.hasSuffix(".swift") {
                    relativePaths.append(entry)
                }
            }

            for entry in relativePaths.sorted() {
                let absolutePath = (directoryPath as NSString).appendingPathComponent(entry)
                do {
                    let source = try String(contentsOfFile: absolutePath, encoding: .utf8)
                    files.append(FileTokenStream(
                        absolutePath: absolutePath,
                        relativePath: directory + "/" + entry,
                        tokens: CloneTokenizer.tokenize(source: source)
                    ))
                } catch {
                    Self.logger.warning("DuplicationAuditor could not read \(absolutePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    /// Zero-padded 16-digit lowercase hex rendering of a 64-bit hash.
    private static func hexString(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        let padding = max(0, 16 - hex.count)
        return String(repeating: "0", count: padding) + hex
    }
}
