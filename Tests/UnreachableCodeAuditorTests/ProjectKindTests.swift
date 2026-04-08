import Foundation
import Testing
@testable import UnreachableCodeAuditor

@Suite("ProjectKind detection")
struct ProjectKindTests {

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pktest-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Package.swift → swiftPM")
    func detectsSwiftPM() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "// swift-tools-version:6.0\n"
            .write(to: dir.appendingPathComponent("Package.swift"),
                   atomically: true, encoding: .utf8)
        let kind = ProjectKind.detect(at: dir)
        if case .swiftPM(let root) = kind {
            #expect(root.standardizedFileURL == dir.standardizedFileURL)
        } else {
            Issue.record("expected .swiftPM, got \(kind)")
        }
    }

    @Test("*.xcodeproj → xcode")
    func detectsXcode() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("Test.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let kind = ProjectKind.detect(at: dir)
        if case .xcode(let pf, let root) = kind {
            #expect(pf.standardizedFileURL == proj.standardizedFileURL)
            #expect(root.standardizedFileURL == dir.standardizedFileURL)
        } else {
            Issue.record("expected .xcode, got \(kind)")
        }
    }

    @Test("Both → swiftPM wins")
    func bothPrefersSwiftPM() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "".write(to: dir.appendingPathComponent("Package.swift"),
                     atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Test.xcodeproj"),
            withIntermediateDirectories: true)
        let kind = ProjectKind.detect(at: dir)
        if case .swiftPM = kind {} else {
            Issue.record("expected .swiftPM (SwiftPM wins), got \(kind)")
        }
    }

    @Test("Empty directory → plain")
    func detectsPlain() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kind = ProjectKind.detect(at: dir)
        if case .plain = kind {} else {
            Issue.record("expected .plain, got \(kind)")
        }
    }
}
