import Testing
import Foundation
@testable import IJSDashboardCore

/// The corpus change-signature backs the GUI's auto-refresh: it must advance
/// when a file under the corpus changes and stay put otherwise, so an idle poll
/// is a cheap stat rather than a full re-parse.
@Suite("Corpus signature")
struct CorpusSignatureTests {

    @Test("Returns nil for a directory that does not exist")
    func missingDirectory() {
        let path = NSTemporaryDirectory() + "ijs-signature-missing-\(ProcessInfo.processInfo.globallyUniqueString)"
        #expect(DashboardLoader.corpusSignature(at: path) == nil)
    }

    @Test("Reports the newest modification time under the directory")
    func reportsNewestMTime() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Flat files only — a freshly created subdirectory would carry a
        // current mtime and mask the values under test.
        let older = dir.appendingPathComponent("old.json")
        let newer = dir.appendingPathComponent("new.json")
        try "{}".write(to: older, atomically: true, encoding: .utf8)
        try "{}".write(to: newer, atomically: true, encoding: .utf8)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try setMTime(base, on: older)
        try setMTime(base.addingTimeInterval(3600), on: newer)

        // Compare whole-second epoch values: the signature must equal the newer
        // file's mtime exactly (filesystems store mtime at 1-second resolution).
        let signature = DashboardLoader.corpusSignature(at: dir.path)
        #expect(signature.map { Int($0.timeIntervalSince1970) } == 1_700_003_600)
    }

    @Test("Signature advances when a file is touched")
    func advancesOnChange() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("run.json")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        try setMTime(Date(timeIntervalSince1970: 1_700_000_000), on: file)
        let before = DashboardLoader.corpusSignature(at: dir.path)

        try setMTime(Date(timeIntervalSince1970: 1_700_000_500), on: file)
        let after = DashboardLoader.corpusSignature(at: dir.path)

        // Exact epoch values before and after the touch — the signature tracks
        // the file's recorded mtime, advancing by the 500 seconds applied.
        #expect(before.map { Int($0.timeIntervalSince1970) } == 1_700_000_000)
        #expect(after.map { Int($0.timeIntervalSince1970) } == 1_700_000_500)
    }
}

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ijs-signature-\(ProcessInfo.processInfo.globallyUniqueString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func setMTime(_ date: Date, on url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}
