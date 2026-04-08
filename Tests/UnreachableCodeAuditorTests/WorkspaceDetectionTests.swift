import Foundation
import Testing
@testable import UnreachableCodeAuditor

@Suite("Workspace detection")
struct WorkspaceDetectionTests {

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wstest-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("*.xcworkspace → xcworkspace")
    func detectsWorkspace() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ws = dir.appendingPathComponent("Test.xcworkspace")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let kind = ProjectKind.detect(at: dir)
        if case .xcworkspace(let f, let r) = kind {
            #expect(f.standardizedFileURL == ws.standardizedFileURL)
            #expect(r.standardizedFileURL == dir.standardizedFileURL)
        } else {
            Issue.record("expected .xcworkspace, got \(kind)")
        }
    }

    @Test("Workspace wins over project when both present")
    func workspaceWinsOverProject() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Test.xcworkspace"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Test.xcodeproj"),
            withIntermediateDirectories: true)
        let kind = ProjectKind.detect(at: dir)
        if case .xcworkspace = kind {} else {
            Issue.record("expected .xcworkspace (wins over project), got \(kind)")
        }
    }

    @Test("SwiftPM still wins over workspace")
    func swiftPMWinsOverWorkspace() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "".write(to: dir.appendingPathComponent("Package.swift"),
                     atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Test.xcworkspace"),
            withIntermediateDirectories: true)
        let kind = ProjectKind.detect(at: dir)
        if case .swiftPM = kind {} else {
            Issue.record("expected .swiftPM (still wins over workspace), got \(kind)")
        }
    }
}
