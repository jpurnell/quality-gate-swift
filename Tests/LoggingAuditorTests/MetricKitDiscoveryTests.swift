import Foundation
import Testing
@testable import LoggingAuditor
@testable import QualityGateCore

/// Whole-project runs through `check(configuration:)`: how app targets are found on disk.
@Suite("LoggingAuditor: MetricKit target discovery")
struct MetricKitDiscoveryTests {

    private static let appSource = """
    import SwiftUI
    @main struct DemoApp: App { var body: some Scene { WindowGroup { Text("hi") } } }
    """

    private func makeProject(_ build: (URL) throws -> Void) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func check(_ root: URL, projectType: String = "application") async throws -> CheckResult {
        var configuration = Configuration()
        configuration.projectRoot = root
        let auditor = LoggingAuditor(config: LoggingAuditorConfig(projectType: projectType, distribution: ["appStore"], metricKitSeverity: .error))
        return try await auditor.check(configuration: configuration)
    }

    @Test("A SwiftPM app target under Sources/ is flagged; a library target beside it is not")
    func swiftPMLayout() async throws {
        let root = try makeProject { root in
            try write(Self.appSource, to: root.appendingPathComponent("Sources/Phone/App.swift"))
            try write("public struct Helper { }", to: root.appendingPathComponent("Sources/Kit/Kit.swift"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await check(root)
        let hits = result.diagnostics.filter { $0.ruleId == "logging.no-metrickit-subscriber" }
        #expect(hits.count == 1)
        #expect(hits.first?.filePath?.contains("Sources/Phone/") == true)
    }

    @Test("A library project is skipped on disk too")
    func libraryOnDisk() async throws {
        let root = try makeProject { root in
            try write(Self.appSource, to: root.appendingPathComponent("Sources/Phone/App.swift"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await check(root, projectType: "library")
        #expect(result.status == .skipped)
    }

    /// A minimal old-style project: an app target and an app-extension target, both compiling
    /// one file, the app for iOS and the extension for iOS too.
    private func pbxproj() -> String {
        """
        // !$*UTF8*$!
        {
          archiveVersion = 1; classes = {}; objectVersion = 56;
          objects = {
            AAA = { isa = PBXFileReference; path = App.swift; sourceTree = "<group>"; };
            BBB = { isa = PBXFileReference; path = Ext.swift; sourceTree = "<group>"; };
            G = { isa = PBXGroup; children = (AAA, BBB); path = Sources; sourceTree = SOURCE_ROOT; };
            BF1 = { isa = PBXBuildFile; fileRef = AAA; };
            BF2 = { isa = PBXBuildFile; fileRef = BBB; };
            PH1 = { isa = PBXSourcesBuildPhase; files = (BF1); };
            PH2 = { isa = PBXSourcesBuildPhase; files = (BF2); };
            CFG1 = { isa = XCBuildConfiguration; name = Debug; buildSettings = { SDKROOT = watchos; }; };
            CL1 = { isa = XCConfigurationList; buildConfigurations = (CFG1); };
            CL2 = { isa = XCConfigurationList; buildConfigurations = (CFG1); };
            T1 = { isa = PBXNativeTarget; name = WatchApp; productType = "com.apple.product-type.application"; buildPhases = (PH1); buildConfigurationList = CL1; };
            T2 = { isa = PBXNativeTarget; name = Widget; productType = "com.apple.product-type.app-extension"; buildPhases = (PH2); buildConfigurationList = CL2; };
          };
          rootObject = ROOT;
        }
        """
    }

    @Test("An Xcode project: the application target is judged, the extension is not, and the platform comes from build settings")
    func xcodeProject() async throws {
        let root = try makeProject { root in
            try write(pbxproj(), to: root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
            try write(Self.appSource, to: root.appendingPathComponent("Sources/App.swift"))
            try write("import WidgetKit\nstruct W { }\n@main struct B: App { }", to: root.appendingPathComponent("Sources/Ext.swift"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let targets = MetricKitTargetDiscovery.discover(root: root, excludePatterns: [])
        #expect(targets.map(\.name) == ["WatchApp"])
        #expect(targets.first?.platforms == ["watchOS"])
        let result = try await check(root)
        #expect(result.diagnostics.filter { $0.ruleId == "logging.no-metrickit-subscriber" }.count == 1)
    }

    @Test("An Xcode app target on a platform listed as unsupported is exempt")
    func xcodePlatformExempt() async throws {
        let root = try makeProject { root in
            try write(pbxproj(), to: root.appendingPathComponent("Demo.xcodeproj/project.pbxproj"))
            try write(Self.appSource, to: root.appendingPathComponent("Sources/App.swift"))
            try write("struct E { }", to: root.appendingPathComponent("Sources/Ext.swift"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Configuration()
        configuration.projectRoot = root
        let auditor = LoggingAuditor(config: LoggingAuditorConfig(metricKitUnsupportedPlatforms: ["watchOS"], distribution: ["appStore"], metricKitSeverity: .error))
        let result = try await auditor.check(configuration: configuration)
        #expect(!result.diagnostics.contains { $0.ruleId == "logging.no-metrickit-subscriber" })
    }
}
