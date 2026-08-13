import Foundation
import Testing
@testable import GPUSafetyAuditor

@Suite("GPUSafetyAuditor")
struct GPUSafetyAuditorScanTests {

    /// Builds a throwaway package tree and returns its root.
    private func makeTree(
        manifest: String, files: [String: String]
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gpu-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manifest.write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for (relative, contents) in files {
            let target = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Coverage is stated on every run, including one that finds nothing. A checker
    /// that examined nothing must not print what a checker that found nothing prints.
    @Test("Reports coverage when there is no shader source at all")
    func reportsZeroCoverage() throws {
        let root = try makeTree(
            manifest: "// swift-tools-version: 6.2\n",
            files: ["Sources/App/main.swift": "print(\"hello\")\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = GPUSafetyAuditor.scan(root: root.path)
        #expect(scan.coverageLine.contains("0 .metal file(s)"))
        #expect(scan.coverageLine.contains("0 kernel(s) examined"))
        #expect(scan.diagnostics.isEmpty)
    }

    /// The form that actually ships in the motivating codebase: `.metal` files
    /// excluded from every target, live shaders in a Swift string literal. A checker
    /// reading only `.metal` files reports on dead code and misses the program.
    @Test("Finds kernels embedded in a Swift string literal")
    func findsEmbeddedShaders() throws {
        let swift = """
            let source = \"\"\"
            kernel void scale(device float *out [[buffer(0)]],
                              uint id [[thread_position_in_grid]]) {
                out[id] = out[id] * 2.0;
            }
            \"\"\"
            let library = try device.makeLibrary(source: source, options: nil)
            """
        let root = try makeTree(
            manifest: "// swift-tools-version: 6.2\n",
            files: ["Sources/App/Shaders.swift": swift])
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = GPUSafetyAuditor.scan(root: root.path)
        #expect(scan.coverageLine.contains("1 embedded literal(s)"))
        #expect(scan.coverageLine.contains("1 kernel(s) examined"))
        #expect(scan.diagnostics.contains { $0.ruleId == "gpu.unbounded-thread-id" })
    }

    /// A `.metal` file no target compiles is dead. Reporting a bounds defect in it
    /// as a defect in the program would be false, so the file is noted and its
    /// kernels are counted but not audited.
    @Test("An excluded .metal file is noted as dead and not audited")
    func excludedFileIsNotedNotAudited() throws {
        let manifest = """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(
                name: "X",
                targets: [
                    .target(name: "App", exclude: ["Shaders.metal"])
                ]
            )
            """
        let metal = """
            kernel void unbounded(device float *out [[buffer(0)]],
                                  uint id [[thread_position_in_grid]]) {
                out[id] = 1.0;
            }
            """
        let root = try makeTree(
            manifest: manifest, files: ["Sources/App/Shaders.metal": metal])
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = GPUSafetyAuditor.scan(root: root.path)
        #expect(scan.diagnostics.contains { $0.ruleId == "gpu.dead-shader-file" })
        #expect(!scan.diagnostics.contains { $0.ruleId == "gpu.unbounded-thread-id" })
        #expect(scan.coverageLine.contains("excluded from every target"))
    }

    /// The same file, compiled, is audited normally.
    @Test("An included .metal file is audited")
    func includedFileIsAudited() throws {
        let metal = """
            kernel void unbounded(device float *out [[buffer(0)]],
                                  uint id [[thread_position_in_grid]]) {
                out[id] = 1.0;
            }
            """
        let root = try makeTree(
            manifest: "// swift-tools-version: 6.2\n",
            files: ["Sources/App/Shaders.metal": metal])
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = GPUSafetyAuditor.scan(root: root.path)
        #expect(scan.diagnostics.contains { $0.ruleId == "gpu.unbounded-thread-id" })
        #expect(!scan.diagnostics.contains { $0.ruleId == "gpu.dead-shader-file" })
    }

    @Test("Diagnostics are ordered by file then line")
    func orderedOutput() throws {
        let metal = """
            kernel void a(device float *o [[buffer(0)]], uint id [[thread_position_in_grid]]) {
                o[id] = 1.0;
            }
            kernel void b(device float *p [[buffer(0)]], uint id [[thread_position_in_grid]]) {
                p[id] = 2.0;
            }
            """
        let root = try makeTree(
            manifest: "// swift-tools-version: 6.2\n",
            files: ["Sources/App/S.metal": metal])
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = GPUSafetyAuditor.scan(root: root.path)
        let keys = scan.diagnostics.map { "\($0.filePath ?? "")#\(String(format: "%06d", $0.lineNumber ?? 0))" }
        #expect(keys == keys.sorted())
    }

    @Test("Scanning the same tree twice yields identical output")
    func deterministic() throws {
        let root = try makeTree(
            manifest: "// swift-tools-version: 6.2\n",
            files: ["Sources/App/S.metal": """
                kernel void a(device float *o [[buffer(0)]], uint id [[thread_position_in_grid]]) {
                    o[id] = 1.0;
                }
                """])
        defer { try? FileManager.default.removeItem(at: root) }

        let first = GPUSafetyAuditor.scan(root: root.path)
        let second = GPUSafetyAuditor.scan(root: root.path)
        #expect(first.coverageLine == second.coverageLine)
        #expect(first.diagnostics.map(\.message) == second.diagnostics.map(\.message))
    }
}
