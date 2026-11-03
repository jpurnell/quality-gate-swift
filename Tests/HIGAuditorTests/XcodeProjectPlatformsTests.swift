import Foundation
import Testing
@testable import HIGAuditor
import QualityGateCore

/// A watch app is not a Mac app (`AWatchAppIsNotAMacApp.md`): which platform a SwiftUI file
/// belongs to is read from the Xcode target that compiles it, for every platform.
@Suite("Xcode project platform resolution")
struct XcodeProjectPlatformsTests {

    // MARK: - Build settings → platforms

    @Test("Each SDKROOT resolves to its own platform and no other",
          arguments: [
            ("macosx", HIGPlatform.macOS),
            ("watchos", .watchOS),
            ("appletvos", .tvOS),
            ("xros", .visionOS),
            ("iphoneos", [.iOS, .iPadOS]),
          ] as [(String, HIGPlatform)])
    func sdkRoot(sdk: String, expected: HIGPlatform) {
        #expect(HIGPlatform.resolve(buildSettings: ["SDKROOT": sdk]) == expected)
    }

    @Test("TARGETED_DEVICE_FAMILY narrows an iOS target",
          arguments: [
            ("1", HIGPlatform.iOS),
            ("2", .iPadOS),
            ("1,2", [.iOS, .iPadOS]),
          ] as [(String, HIGPlatform)])
    func deviceFamily(family: String, expected: HIGPlatform) {
        let settings = ["SDKROOT": "iphoneos", "TARGETED_DEVICE_FAMILY": family]
        #expect(HIGPlatform.resolve(buildSettings: settings) == expected)
    }

    @Test("Mac Catalyst adds macOS to an iOS target")
    func catalyst() {
        let settings = ["SDKROOT": "iphoneos", "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTS_MACCATALYST": "YES"]
        #expect(HIGPlatform.resolve(buildSettings: settings) == [.iOS, .iPadOS, .macOS])
    }

    @Test("SUPPORTED_PLATFORMS outranks SDKROOT = auto",
          arguments: [
            ("iphoneos iphonesimulator macosx", HIGPlatform([.iOS, .iPadOS, .macOS])),
            ("watchos watchsimulator", .watchOS),
            ("appletvos appletvsimulator", .tvOS),
            ("xros xrsimulator", .visionOS),
            ("iphoneos macosx xros", [.iOS, .iPadOS, .macOS, .visionOS]),
          ] as [(String, HIGPlatform)])
    func supportedPlatforms(list: String, expected: HIGPlatform) {
        #expect(HIGPlatform.resolve(buildSettings: ["SDKROOT": "auto", "SUPPORTED_PLATFORMS": list]) == expected)
    }

    @Test("What cannot be resolved is nil, never a guess",
          arguments: [
            [:],
            ["SDKROOT": "auto"],
            ["SDKROOT": "$(TARGET_SDK)"],
            ["SDKROOT": "iphoneos", "SUPPORTED_PLATFORMS": "$(inherited)"],
          ] as [[String: String]])
    func unresolvable(settings: [String: String]) {
        #expect(HIGPlatform.resolve(buildSettings: settings) == nil)
    }

    // MARK: - Target membership

    @Test("A file compiled by a watchOS-only target resolves to watchOS")
    func explicitFileInWatchTarget() throws {
        let tree = try Fixture(project: .explicit(targets: [.init(name: "Watch", sdk: "watchos", files: ["Watch/WatchApp.swift"])]),
                               sources: ["Watch/WatchApp.swift", "Other/Stray.swift"])
        defer { tree.remove() }
        let projects = XcodeProjectPlatforms.discover(under: tree.root)
        #expect(projects.platforms(forFile: tree.path("Watch/WatchApp.swift")) == .watchOS)
        #expect(projects.platforms(forFile: tree.path("Other/Stray.swift")) == nil,
                "a file no target compiles is unknown, not macOS")
    }

    @Test("A synchronized folder gives every file in it, minus the target's exceptions")
    func synchronizedFolder() throws {
        let tree = try Fixture(
            project: .synchronized(targets: [.init(name: "TV", sdk: "appletvos", files: [])],
                                   folder: "TV", exceptions: ["Info.plist", "Skip/Hidden.swift"]),
            sources: ["TV/TVApp.swift", "TV/Skip/Hidden.swift"])
        defer { tree.remove() }
        let projects = XcodeProjectPlatforms.discover(under: tree.root)
        #expect(projects.platforms(forFile: tree.path("TV/TVApp.swift")) == .tvOS)
        #expect(projects.platforms(forFile: tree.path("TV/Skip/Hidden.swift")) == nil)
    }

    @Test("A file in a watch target and a Mac target is audited for both")
    func sharedFileIsUnion() throws {
        let tree = try Fixture(
            project: .explicit(targets: [
                .init(name: "Watch", sdk: "watchos", files: ["Shared/Row.swift"]),
                .init(name: "Mac", sdk: "macosx", files: ["Shared/Row.swift"]),
            ]),
            sources: ["Shared/Row.swift"])
        defer { tree.remove() }
        let projects = XcodeProjectPlatforms.discover(under: tree.root)
        #expect(projects.platforms(forFile: tree.path("Shared/Row.swift")) == [.watchOS, .macOS])
    }

    @Test("One undeterminable target makes the whole answer unknown")
    func unknownTargetPoisonsUnion() throws {
        let tree = try Fixture(
            project: .explicit(targets: [
                .init(name: "Watch", sdk: "watchos", files: ["Shared/Row.swift"]),
                .init(name: "Mystery", sdk: "auto", files: ["Shared/Row.swift"]),
            ]),
            sources: ["Shared/Row.swift"])
        defer { tree.remove() }
        let projects = XcodeProjectPlatforms.discover(under: tree.root)
        #expect(projects.platforms(forFile: tree.path("Shared/Row.swift")) == nil)
    }

    @Test("Test bundles do not add their platform to the app's files")
    func testTargetsIgnored() throws {
        let tree = try Fixture(
            project: .explicit(targets: [
                .init(name: "Watch", sdk: "watchos", files: ["W/App.swift"]),
                .init(name: "WatchTests", sdk: "macosx", files: ["W/App.swift"],
                      productType: "com.apple.product-type.bundle.unit-test"),
            ]),
            sources: ["W/App.swift"])
        defer { tree.remove() }
        let projects = XcodeProjectPlatforms.discover(under: tree.root)
        #expect(projects.platforms(forFile: tree.path("W/App.swift")) == .watchOS)
    }

    @Test("A project-level SDKROOT is inherited by a target that sets none")
    func projectLevelSettingInherited() throws {
        let tree = try Fixture(
            project: .explicit(projectSettings: ["SDKROOT": "xros"],
                               targets: [.init(name: "Vision", sdk: nil, files: ["V/App.swift"])]),
            sources: ["V/App.swift"])
        defer { tree.remove() }
        let projects = XcodeProjectPlatforms.discover(under: tree.root)
        #expect(projects.platforms(forFile: tree.path("V/App.swift")) == .visionOS)
    }

    @Test("An unparseable project is counted, not fatal")
    func unreadableProject() throws {
        let tree = try Fixture(project: .raw("this is not a plist {{{"), sources: ["A.swift"])
        defer { tree.remove() }
        let projects = XcodeProjectPlatforms.discover(under: tree.root)
        #expect(projects.unreadableProjectCount == 1)
        #expect(projects.platforms(forFile: tree.path("A.swift")) == nil)
    }

    // MARK: - Auditor behaviour, every platform

    private let appSource = """
    import SwiftUI
    @main struct SomeApp: App {
        var body: some Scene { WindowGroup { Text("Hi") } }
    }
    """

    @Test("A SwiftUI-only App on a non-Mac, non-iPad platform is asked for neither macOS rule",
          arguments: [HIGPlatform.watchOS, .tvOS, .visionOS, .iOS])
    func appRulesNotAppliedOffDesktop(platform: HIGPlatform) {
        let result = HIGAuditor().auditSource(
            appSource, fileName: "App.swift", activePlatforms: .all,
            navigation: NavigationHostIndex(), projectPlatforms: platform)
        let ids = Set(result.diagnostics.compactMap(\.ruleId))
        #expect(!ids.contains("hig.settings-scene"))
        #expect(!ids.contains("hig.menu-commands"))
    }

    @Test("A macOS target is still asked for both")
    func macAppStillAudited() {
        let result = HIGAuditor().auditSource(
            appSource, fileName: "App.swift", activePlatforms: .all,
            navigation: NavigationHostIndex(), projectPlatforms: .macOS)
        let ids = Set(result.diagnostics.compactMap(\.ruleId))
        #expect(ids.contains("hig.settings-scene"))
        #expect(ids.contains("hig.menu-commands"))
    }

    @Test("An iPad target is asked for menu commands; an iPhone-only target is not")
    func iPadVersusiPhone() {
        func ids(_ p: HIGPlatform) -> Set<String> {
            Set(HIGAuditor().auditSource(
                appSource, fileName: "App.swift", activePlatforms: .all,
                navigation: NavigationHostIndex(), projectPlatforms: p).diagnostics.compactMap(\.ruleId))
        }
        #expect(ids([.iOS, .iPadOS]).contains("hig.menu-commands"))
        #expect(!ids(.iOS).contains("hig.menu-commands"))
    }

    @Test("Project membership reaches View files too, not just App structs")
    func viewRulesUseFilePlatform() {
        let source = """
        import SwiftUI
        struct Rows: View {
            let items: [String]
            var body: some View { List(items, id: \\.self) { Text($0) } }
        }
        """
        func ids(_ p: HIGPlatform?) -> Set<String> {
            Set(HIGAuditor().auditSource(
                source, fileName: "Rows.swift", activePlatforms: .all,
                navigation: NavigationHostIndex(), projectPlatforms: p).diagnostics.compactMap(\.ruleId))
        }
        #expect(ids(nil).contains("hig.context-menus"), "no project: the old project-wide default applies")
        #expect(!ids(.watchOS).contains("hig.context-menus"), "context menus are not a watchOS idiom")
        #expect(ids(.tvOS).contains("hig.context-menus"), "the rule is declared for everything except watchOS")
    }

    @Test("An explicit platform override outranks the project")
    func overrideBeatsProject() {
        let result = HIGAuditor().auditSource(
            appSource, fileName: "App.swift", activePlatforms: .macOS,
            navigation: NavigationHostIndex(), projectPlatforms: .watchOS, isConfigured: true)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.settings-scene" })
    }

    @Test("No project information leaves the previous behaviour unchanged")
    func noProjectFallsThrough() {
        let result = HIGAuditor().auditSource(appSource, fileName: "App.swift", activePlatforms: .all)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.settings-scene" })
    }

    // MARK: - Source markers

    @Test("UIKit is not evidence of iOS alone: tvOS and visionOS import it too")
    func uiKitMarker() throws {
        let platforms = try #require(PlatformDetector.detectAppPlatform("import UIKit\nimport SwiftUI"))
        #expect(platforms == [.iOS, .iPadOS, .tvOS, .visionOS])
        #expect(!platforms.contains(.macOS) && !platforms.contains(.watchOS))
    }

    @Test("TVUIKit marks a file as tvOS")
    func tvMarker() {
        #expect(PlatformDetector.detectAppPlatform("import TVUIKit") == .tvOS)
    }

    // MARK: - End to end through check()

    @Test("check() resolves a watch-only Xcode project with no Package.swift")
    func endToEnd() async throws {
        let tree = try Fixture(
            project: .explicit(targets: [.init(name: "Spinner", sdk: "watchos", files: ["Spinner Watch/SpinnerWatchApp.swift"])]),
            rawSources: ["Spinner Watch/SpinnerWatchApp.swift": appSource])
        defer { tree.remove() }
        var config = Configuration()
        config.projectRoot = tree.root
        let result = try await HIGAuditor().check(configuration: config)
        let ids = Set(result.diagnostics.compactMap(\.ruleId))
        #expect(!ids.contains("hig.settings-scene"))
        #expect(!ids.contains("hig.menu-commands"))
        #expect(ids.contains("hig-auditor.platform-source"), "the resolution must be visible, not silent")
        #expect(result.status == .passed)
    }
}

// MARK: - Fixture

private struct FixtureTarget {
    let name: String
    let sdk: String?
    let files: [String]
    var productType = "com.apple.product-type.application"
}

private enum FixtureProject {
    case explicit(projectSettings: [String: String] = [:], targets: [FixtureTarget])
    case synchronized(targets: [FixtureTarget], folder: String, exceptions: [String])
    case raw(String)
}

/// A throwaway directory holding a `.xcodeproj` and the sources it names.
private struct Fixture {
    let root: URL

    init(project: FixtureProject, sources: [String] = [], rawSources: [String: String] = [:]) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hig-xcode-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try Self.render(project).write(to: proj.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        var all: [String: String] = [:]
        for source in sources { all[source] = "import SwiftUI\n" }
        all.merge(rawSources) { _, new in new }
        for (relative, text) in all {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func path(_ relative: String) -> String { root.appendingPathComponent(relative).path }
    func remove() { try? FileManager.default.removeItem(at: root) } // silent: temp-dir cleanup in a test

    private static func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    private static func settings(_ pairs: [String: String]) -> String {
        pairs.sorted { $0.key < $1.key }.map { "\($0.key) = \(q($0.value));" }.joined(separator: " ")
    }

    /// Old-style property list, the format Xcode writes.
    private static func render(_ project: FixtureProject) -> String {
        let (projectSettings, targets, folder, exceptions): ([String: String], [FixtureTarget], String?, [String])
        switch project {
        case .raw(let text): return text
        case .explicit(let s, let t): (projectSettings, targets, folder, exceptions) = (s, t, nil, [])
        case .synchronized(let t, let f, let e): (projectSettings, targets, folder, exceptions) = ([:], t, f, e)
        }

        var objects: [String] = []
        var groupChildren: [String] = []
        objects.append("PROJCFG = { isa = XCBuildConfiguration; name = Debug; buildSettings = { \(settings(projectSettings)) }; };")
        objects.append("PROJLIST = { isa = XCConfigurationList; buildConfigurations = (PROJCFG); };")
        objects.append("PROJECT = { isa = PBXProject; buildConfigurationList = PROJLIST; mainGroup = MAIN; targets = (\(targets.indices.map { "T\($0)" }.joined(separator: ", "))); };")

        var fileIds: [String: String] = [:]
        for (i, target) in targets.enumerated() {
            var s: [String: String] = [:]
            if let sdk = target.sdk { s["SDKROOT"] = sdk }
            objects.append("T\(i)CFG = { isa = XCBuildConfiguration; name = Debug; buildSettings = { \(settings(s)) }; };")
            objects.append("T\(i)LIST = { isa = XCConfigurationList; buildConfigurations = (T\(i)CFG); };")

            var buildFiles: [String] = []
            for file in target.files {
                let ref = fileIds[file] ?? "REF\(fileIds.count)"
                if fileIds[file] == nil {
                    fileIds[file] = ref
                    objects.append("\(ref) = { isa = PBXFileReference; path = \(q(file)); sourceTree = SOURCE_ROOT; };")
                    groupChildren.append(ref)
                }
                let bf = "T\(i)BF\(buildFiles.count)"
                objects.append("\(bf) = { isa = PBXBuildFile; fileRef = \(ref); };")
                buildFiles.append(bf)
            }
            objects.append("T\(i)SRC = { isa = PBXSourcesBuildPhase; files = (\(buildFiles.joined(separator: ", "))); };")

            var extra = ""
            if let folder {
                objects.append("SYNC\(i) = { isa = PBXFileSystemSynchronizedRootGroup; path = \(q(folder)); sourceTree = \"<group>\"; exceptions = (EXC\(i)); };")
                objects.append("EXC\(i) = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; membershipExceptions = (\(exceptions.map(q).joined(separator: ", "))); target = T\(i); };")
                groupChildren.append("SYNC\(i)")
                extra = "fileSystemSynchronizedGroups = (SYNC\(i));"
            }
            objects.append("T\(i) = { isa = PBXNativeTarget; name = \(q(target.name)); productType = \(q(target.productType)); buildConfigurationList = T\(i)LIST; buildPhases = (T\(i)SRC); \(extra) };")
        }
        objects.append("MAIN = { isa = PBXGroup; sourceTree = \"<group>\"; children = (\(groupChildren.joined(separator: ", "))); };")

        return "// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 77; rootObject = PROJECT; objects = {\n"
            + objects.joined(separator: "\n") + "\n}; }\n"
    }
}
