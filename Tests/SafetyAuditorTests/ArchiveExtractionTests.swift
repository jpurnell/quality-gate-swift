import Foundation
import Testing
@testable import SafetyAuditor
@testable import QualityGateCore

/// An archive describes itself.
///
/// An entry's name is a claim its author made. Joining it onto a destination and writing — or
/// creating a link to wherever the entry says — without checking the result against something the
/// archive did not supply is zip-slip. marmelroy/Zip did it (GHSA-g454-wj9r-jpg4): an entry named
/// `../../x` was written outside the destination.
///
/// These are tripwires: measured across the portfolio before release, nothing extracts to disk.
/// SwiftZIP returns entries in memory and its consumers key a dictionary by `entry.path`, which is
/// pinned below as clean.
///
/// See `quality-gate-swift-project/plans/proposals/AnArchiveDescribesItself.md` §4.1, §4.2.
@Suite("Archive extraction")
struct ArchiveExtractionTests {

    private func audit(_ body: String, configuration: Configuration = Configuration()) async throws -> CheckResult {
        let code = """
            import Foundation
            func extract(data: Data, dest: URL, base: String, archive: Archive, fm: FileManager) throws {
            \(body)
            }
            """
        return try await SafetyAuditor().auditSource(code, fileName: "test.swift", configuration: configuration)
    }

    private func findings(_ result: CheckResult, _ rule: String) -> [Diagnostic] {
        result.diagnostics.filter { $0.ruleId == rule }
    }

    private static let escape = "security.archive-path-escape"
    private static let symlink = "security.archive-symlink"

    // MARK: - Path escape: reported

    @Test("An entry's name joined onto the destination and written is an error")
    func joinedAndWrittenIsError() async throws {
        let result = try await audit("""
                for entry in try ZIPReader.read(from: data) {
                    try entry.data.write(to: dest.appendingPathComponent(entry.path))
                }
            """)
        let all = findings(result, Self.escape)
        #expect(all.count == 1)
        let finding = try #require(all.first)
        #expect(finding.severity == .error)
        #expect(finding.lineNumber == 4)
        #expect(finding.message.contains("[CWE-22]"))
    }

    @Test("Every join spelling is a join", arguments: [
        "dest.appending(path: entry.name)",
        "dest.appending(component: entry.fileName)",
        "URL(fileURLWithPath: entry.relativePath, relativeTo: dest)",
        "URL(fileURLWithPath: (base as NSString).appendingPathComponent(entry.filename))",
    ])
    func everyJoinSpelling(join: String) async throws {
        let result = try await audit("""
                for entry in archive.entries {
                    try entry.data.write(to: \(join))
                }
            """)
        #expect(findings(result, Self.escape).count == 1, "\(join)")
    }

    @Test("A join bound to a name and written later is an error")
    func joinThroughALocal() async throws {
        let result = try await audit("""
                for member in try TarReader(data: data).members() {
                    let name = member.pathname
                    let out = dest.appendingPathComponent(name)
                    try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try member.contents.write(to: out)
                }
            """)
        #expect(findings(result, Self.escape).count == 1)
    }

    @Test("A forEach closure over entries is a loop over entries")
    func forEachClosure() async throws {
        let result = try await audit("""
                try archive.entries.forEach { e in try e.data.write(to: dest.appendingPathComponent(e.name)) }
            """)
        #expect(findings(result, Self.escape).count == 1)
    }

    /// The shape of marmelroy/Zip before GHSA-g454-wj9r-jpg4: a minizip cursor loop, the name read
    /// from the C API, joined and opened for writing.
    @Test("A minizip cursor loop that joins the current file's name and writes is an error")
    func minizipCursorLoop() async throws {
        let result = try await audit("""
                var ret = unzGoToFirstFile(zip)
                repeat {
                    var info = unz_file_info64()
                    let raw = [CChar](repeating: 0, count: 4096)
                    ret = unzGetCurrentFileInfo64(zip, &info, raw, 4096, nil, 0, nil, 0)
                    let pathString = String(cString: raw)
                    let fullPath = dest.appendingPathComponent(pathString).path
                    let filePointer = fopen(fullPath, "wb")
                    fclose(filePointer)
                    ret = unzGoToNextFile(zip)
                } while ret == UNZ_OK
            """)
        let all = findings(result, Self.escape)
        #expect(all.count == 1)
        #expect(all.first?.lineNumber == 9)
    }

    // MARK: - Path escape: what clears it

    @Test("Standardised and compared by whole components before the write clears it", arguments: [
        "guard out.pathComponents.starts(with: dest.standardizedFileURL.pathComponents) else { continue }",
        "guard out.path.hasPrefix(dest.standardizedFileURL.path + \"/\") else { throw ExtractError.escape }",
    ])
    func standardisedAndComparedClears(check: String) async throws {
        let result = try await audit("""
                for entry in try ZIPReader.read(from: data) {
                    let out = dest.appendingPathComponent(entry.path).standardizedFileURL
                    \(check)
                    try entry.data.write(to: out)
                }
            """)
        #expect(findings(result, Self.escape).isEmpty, "\(check)")
    }

    /// ZIPFoundation's `isContained(in:)` and a configured checker standardise by contract.
    @Test("isContained(in:) or a configured checker clears it on its own", arguments: [
        "guard out.isContained(in: dest) else { continue }",
        "guard PathContainment.isContained(out, in: dest) else { continue }",
    ])
    func soundCheckerClears(check: String) async throws {
        let result = try await audit("""
                for entry in try ZIPReader.read(from: data) {
                    let out = dest.appendingPathComponent(entry.path)
                    \(check)
                    try entry.data.write(to: out)
                }
            """)
        #expect(findings(result, Self.escape).isEmpty, "\(check)")
    }

    @Test("A configured checker that throws, called as a statement, clears it")
    func throwingCheckerClears() async throws {
        var config = Configuration()
        config.security.containmentCheckers = ["Confine.inside"]
        let result = try await audit("""
                for entry in try ZIPReader.read(from: data) {
                    let out = dest.appendingPathComponent(entry.path)
                    try Confine.inside(out, dest)
                    try entry.data.write(to: out)
                }
            """, configuration: config)
        #expect(findings(result, Self.escape).isEmpty)
    }

    @Test("A write inside the branch that checked containment is cleared")
    func writeInsideCheckedBranch() async throws {
        let result = try await audit("""
                for entry in try ZIPReader.read(from: data) {
                    let out = dest.appendingPathComponent(entry.path)
                    if out.isContained(in: dest) {
                        try entry.data.write(to: out)
                    }
                }
            """)
        #expect(findings(result, Self.escape).isEmpty)
    }

    // MARK: - Path escape: half a defence

    @Test("A prefix test on a path never standardised does not clear it, and says so")
    func comparedButNotStandardised() async throws {
        let result = try await audit("""
                for entry in try ZIPReader.read(from: data) {
                    let out = dest.appendingPathComponent(entry.path)
                    guard out.path.hasPrefix(dest.standardizedFileURL.path + "/") else { continue }
                    try entry.data.write(to: out)
                }
            """)
        let finding = try #require(findings(result, Self.escape).first)
        #expect(findings(result, Self.escape).count == 1)
        #expect(finding.message.contains("compares a path that was never standardised"))
    }

    @Test("Standardising without comparing does not clear it, and says so")
    func standardisedButNotCompared() async throws {
        let result = try await audit("""
                for entry in try ZIPReader.read(from: data) {
                    let out = dest.appendingPathComponent(entry.path).standardizedFileURL
                    try entry.data.write(to: out)
                }
            """)
        let finding = try #require(findings(result, Self.escape).first)
        #expect(findings(result, Self.escape).count == 1)
        #expect(finding.message.contains("standardised but never compared"))
    }

    @Test("A check whose branch does not leave the iteration does not clear it")
    func nonExitingCheck() async throws {
        let result = try await audit("""
                var skipped = 0
                for entry in try ZIPReader.read(from: data) {
                    let out = dest.appendingPathComponent(entry.path)
                    if !out.isContained(in: dest) { skipped += 1 }
                    try entry.data.write(to: out)
                }
            """)
        #expect(findings(result, Self.escape).count == 1)
    }

    // MARK: - Path escape: not archives, not extraction

    /// `MemoryBuilder.swift:100`: records the tool generated, not archive members.
    @Test("A loop over generated records with no archive vocabulary is not reported")
    func generatedRecordsAreNotArchives() async throws {
        let result = try await audit("""
                let allEntries: [MemoryEntry] = []
                for entry in allEntries {
                    let path = (base as NSString).appendingPathComponent(entry.filename)
                    try entry.content.write(toFile: path, atomically: true, encoding: .utf8)
                }
            """)
        #expect(findings(result, Self.escape).isEmpty)
    }

    /// `development-guidelines/setup.swift`, in twenty copies across the portfolio: a loop over
    /// literal directory names, one of which is `05_99_ARCHIVE`. A word inside a string literal
    /// is data, not a description of the sequence.
    @Test("A word inside a string literal does not make a sequence an archive")
    func literalTextIsNotVocabulary() async throws {
        let result = try await audit("""
                let dirs = ["05_SUMMARIES", "05_SUMMARIES/05_99_ARCHIVE"]
                for dir in dirs {
                    let url = dest.appendingPathComponent("guidelines/\\(dir)")
                    try fm.createDirectory(at: dest.appendingPathComponent(dir), withIntermediateDirectories: true)
                    _ = url
                }
            """)
        #expect(findings(result, Self.escape).isEmpty)
    }

    /// `WorkbookReader.swift:28`: SwiftZIP's consumers read entries in memory.
    @Test("Reading entries into memory is not extraction")
    func inMemoryReadIsClean() async throws {
        let result = try await audit("""
                var entryMap: [String: Data] = [:]
                for entry in try ZIPReader.read(from: data) {
                    entryMap[entry.path] = entry.data
                }
            """)
        #expect(findings(result, Self.escape).isEmpty)
        #expect(findings(result, Self.symlink).isEmpty)
    }

    @Test("Joining a name without writing anything is not extraction")
    func joinWithoutWrite() async throws {
        let result = try await audit("""
                var names: [URL] = []
                for entry in archive.entries {
                    names.append(dest.appendingPathComponent(entry.path))
                }
            """)
        #expect(findings(result, Self.escape).isEmpty)
    }

    @Test("A literal segment in an entry loop chose nothing", arguments: [
        "dest.appendingPathComponent(\"manifest.json\")",
    ])
    func literalSegment(join: String) async throws {
        let result = try await audit("""
                for entry in archive.entries {
                    try entry.data.write(to: \(join))
                }
            """)
        #expect(findings(result, Self.escape).isEmpty)
    }

    @Test("ZIPFoundation's unzipItem checks containment itself")
    func unzipItemIsClean() async throws {
        let result = try await audit("    try fm.unzipItem(at: dest, to: dest)")
        #expect(findings(result, Self.escape).isEmpty)
        #expect(findings(result, Self.symlink).isEmpty)
    }

    /// One defect, one diagnostic: the more specific rule wins the line.
    @Test("Where path-traversal and archive-path-escape both fire, only the archive rule reports")
    func oneDiagnosticPerLine() async throws {
        let result = try await audit("""
                for entry in try ZIPReader.read(from: data) {
                    _ = fm.createFile(atPath: dest.appendingPathComponent(entry.path).path, contents: entry.data)
                }
            """)
        #expect(findings(result, Self.escape).count == 1)
        #expect(findings(result, "security.path-traversal").isEmpty)
    }

    @Test("path-traversal still reports a join outside any archive loop")
    func pathTraversalElsewhereUnchanged() async throws {
        let result = try await audit("""
                let name = base
                _ = fm.createFile(atPath: dest.appendingPathComponent(name).path, contents: data)
            """)
        #expect(findings(result, "security.path-traversal").count == 1)
        #expect(findings(result, Self.escape).isEmpty)
    }

    // MARK: - Path escape: command-line extractors told to keep '..'

    @Test("unzip given -: keeps '../' in entry names")
    func unzipKeepDotDot() async throws {
        let result = try await audit("""
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                task.arguments = ["-:", "-o", base, "-d", dest.path]
            """)
        let finding = try #require(findings(result, Self.escape).first)
        #expect(findings(result, Self.escape).count == 1)
        #expect(finding.severity == .error)
        #expect(finding.lineNumber == 5)
        #expect(finding.message.contains("-:"))
    }

    @Test("tar given an absolute-paths flag keeps '/' and '..'", arguments: ["-P", "--absolute-paths", "--insecure", "--absolute-names"])
    func tarAbsolutePaths(flag: String) async throws {
        let result = try await audit("""
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                task.arguments = ["-x", "\(flag)", "-f", base]
            """)
        #expect(findings(result, Self.escape).count == 1, "\(flag)")
    }

    @Test("env names the extractor in its first argument")
    func envUnzip() async throws {
        let result = try await audit("""
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                task.arguments = ["unzip", "-:", base]
            """)
        #expect(findings(result, Self.escape).count == 1)
    }

    @Test("An extractor run with its defaults is clean", arguments: [
        ("/usr/bin/tar", "[\"-xf\", base, \"-C\", dest.path]"),
        ("/usr/bin/unzip", "[\"-o\", base, \"-d\", dest.path]"),
        // `-P` is unzip's password flag, not tar's absolute-paths flag.
        ("/usr/bin/unzip", "[\"-P\", base, \"-d\", dest.path]"),
        // `-:` means nothing to tar.
        ("/usr/bin/tar", "[\"-:\", base]"),
    ])
    func extractorDefaultsAreClean(executable: String, arguments: String) async throws {
        let result = try await audit("""
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "\(executable)")
                task.arguments = \(arguments)
            """)
        #expect(findings(result, Self.escape).isEmpty, "\(executable) \(arguments)")
    }

    /// v1 matches whole arguments; a flag bundled into `-xPf` is not seen. Pinned so a change to
    /// that is a decision, not an accident.
    @Test("A bundled -P is a known miss")
    func bundledFlagIsAKnownMiss() async throws {
        let result = try await audit("""
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                task.arguments = ["-xPf", base]
            """)
        #expect(findings(result, Self.escape).isEmpty)
    }

    // MARK: - Symlink

    @Test("A link whose target the entry chose, created unchecked, is an error")
    func symlinkFromEntryIsError() async throws {
        let result = try await audit("""
                for entry in archive.entries {
                    let out = dest.appendingPathComponent(entry.path).standardizedFileURL
                    guard out.pathComponents.starts(with: dest.pathComponents) else { continue }
                    try fm.createSymbolicLink(at: out, withDestinationURL: URL(fileURLWithPath: entry.linkTarget))
                }
            """)
        let all = findings(result, Self.symlink)
        #expect(all.count == 1)
        let finding = try #require(all.first)
        #expect(finding.severity == .error)
        #expect(finding.lineNumber == 6)
        #expect(finding.message.contains("[CWE-59]"))
        #expect(findings(result, Self.escape).isEmpty)
    }

    @Test("The path-string spelling is the same link")
    func symlinkPathSpelling() async throws {
        let result = try await audit("""
                for entry in archive.entries {
                    let out = (base as NSString).appendingPathComponent("links")
                    try fm.createSymbolicLink(atPath: out, withDestinationPath: entry.linkName)
                }
            """)
        #expect(findings(result, Self.symlink).count == 1)
    }

    @Test("A link target resolved and contained before the link is made is clean", arguments: [
        "guard target.pathComponents.starts(with: dest.standardizedFileURL.pathComponents) else { continue }",
        "guard target.isContained(in: dest) else { continue }",
    ])
    func containedTargetIsClean(check: String) async throws {
        let result = try await audit("""
                for entry in archive.entries {
                    let out = dest.appendingPathComponent("link")
                    let target = URL(fileURLWithPath: entry.linkTarget, relativeTo: out.deletingLastPathComponent()).standardizedFileURL
                    \(check)
                    try fm.createSymbolicLink(at: out, withDestinationURL: target)
                }
            """)
        #expect(findings(result, Self.symlink).isEmpty, "\(check)")
    }

    @Test("A link made outside any archive loop is not this rule's")
    func symlinkOutsideArchiveLoop() async throws {
        let result = try await audit("""
                let target = URL(fileURLWithPath: base)
                try fm.createSymbolicLink(at: dest, withDestinationURL: target)
            """)
        #expect(findings(result, Self.symlink).isEmpty)
    }

    @Test("Opting out of ZIPFoundation's symlink containment is an error", arguments: [
        "try archive.extract(entry, to: dest, symlinksValidWithin: .rootFS)",
        "try fm.unzipItem(at: dest, to: dest, allowUncontainedSymlinks: true)",
    ])
    func optOutIsError(call: String) async throws {
        let result = try await audit("    " + call)
        let all = findings(result, Self.symlink)
        #expect(all.count == 1, "\(call)")
        #expect(all.first?.severity == .error)
    }

    @Test("Keeping ZIPFoundation's symlink containment is clean", arguments: [
        "try archive.extract(entry, to: dest, symlinksValidWithin: dest)",
        "try fm.unzipItem(at: dest, to: dest, allowUncontainedSymlinks: false)",
    ])
    func keepingContainmentIsClean(call: String) async throws {
        #expect(findings(try await audit("    " + call), Self.symlink).isEmpty, "\(call)")
    }

    // MARK: - Acknowledgement

    @Test("A reasoned acknowledgement is recorded, not reported", arguments: [
        ("security.archive-path-escape",
         "    for entry in archive.entries { try entry.data.write(to: dest.appendingPathComponent(entry.path)) }"),
        ("security.archive-symlink",
         "    try archive.extract(entry, to: dest, symlinksValidWithin: .rootFS)"),
    ])
    func acknowledged(rule: String, line: String) async throws {
        let result = try await audit("""
                // SECURITY: archives are produced by our own build step and signed before upload
            \(line)
            """)
        #expect(findings(result, rule).isEmpty)
        let override = try #require(result.overrides.first { $0.ruleId == rule })
        #expect(override.lineNumber == 4)
        #expect(override.justification == "archives are produced by our own build step and signed before upload")
    }

    @Test("A short acknowledgement is refused and the error stands", arguments: [
        ("security.archive-path-escape",
         "    for entry in archive.entries { try entry.data.write(to: dest.appendingPathComponent(entry.path)) }"),
        ("security.archive-symlink",
         "    try archive.extract(entry, to: dest, symlinksValidWithin: .rootFS)"),
    ])
    func shortAcknowledgementRefused(rule: String, line: String) async throws {
        let result = try await audit("""
                // SECURITY: trusted archive
            \(line)
            """)
        let finding = try #require(findings(result, rule).first)
        #expect(finding.severity == .error)
        #expect(finding.message.contains("not accepted: 2 words, 8 required"))
        #expect(!result.overrides.contains { $0.ruleId == rule })
    }
}
