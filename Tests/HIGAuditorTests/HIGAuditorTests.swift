import Testing
@testable import HIGAuditor
import QualityGateCore

@Suite("HIG Auditor Tests")
struct HIGAuditorTests {
    let auditor = HIGAuditor()

    // MARK: - Tier 1: Settings Scene

    @Test("Flags missing Settings scene on macOS")
    func settingsSceneMissing() {
        let source = """
        import SwiftUI
        @main struct TestApp: App {
            var body: some Scene {
                WindowGroup { Text("Hello") }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "TestApp.swift", activePlatforms: .macOS)
        let settingsDiag = result.diagnostics.filter { $0.ruleId == "hig.settings-scene" }
        #expect(!settingsDiag.isEmpty, "Should flag missing Settings scene on macOS")
    }

    @Test("Passes when Settings scene present")
    func settingsScenePresent() {
        let source = """
        import SwiftUI
        @main struct TestApp: App {
            var body: some Scene {
                WindowGroup { Text("Hello") }
                Settings { Text("Settings") }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "TestApp.swift", activePlatforms: .macOS)
        let settingsDiag = result.diagnostics.filter { $0.ruleId == "hig.settings-scene" }
        #expect(settingsDiag.isEmpty, "Should not flag when Settings scene exists")
    }

    @Test("Does not flag Settings scene on iOS-only")
    func settingsSceneNotFlaggedOnIOS() {
        let source = """
        import SwiftUI
        @main struct TestApp: App {
            var body: some Scene {
                WindowGroup { Text("Hello") }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "TestApp.swift", activePlatforms: .iOS)
        let settingsDiag = result.diagnostics.filter { $0.ruleId == "hig.settings-scene" }
        #expect(settingsDiag.isEmpty, "Should not flag Settings scene on iOS")
    }

    // MARK: - Tier 1: Menu Commands

    @Test("Flags missing .commands modifier on macOS")
    func menuCommandsMissing() {
        let source = """
        import SwiftUI
        @main struct TestApp: App {
            var body: some Scene {
                WindowGroup { Text("Hello") }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "TestApp.swift", activePlatforms: .macOS)
        let commandsDiag = result.diagnostics.filter { $0.ruleId == "hig.menu-commands" }
        #expect(!commandsDiag.isEmpty, "Should flag missing .commands on macOS")
    }

    @Test("Passes when .commands modifier present")
    func menuCommandsPresent() {
        let source = """
        import SwiftUI
        @main struct TestApp: App {
            var body: some Scene {
                WindowGroup { Text("Hello") }
                    .commands {
                        CommandGroup(replacing: .newItem) { }
                    }
                Settings { Text("Settings") }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "TestApp.swift", activePlatforms: .macOS)
        let commandsDiag = result.diagnostics.filter { $0.ruleId == "hig.menu-commands" }
        #expect(commandsDiag.isEmpty, "Should not flag when .commands exists")
    }

    @Test("Flags missing .commands on iPadOS")
    func menuCommandsFlaggedOnIPadOS() {
        let source = """
        import SwiftUI
        @main struct TestApp: App {
            var body: some Scene {
                WindowGroup { Text("Hello") }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "TestApp.swift", activePlatforms: .iPadOS)
        let commandsDiag = result.diagnostics.filter { $0.ruleId == "hig.menu-commands" }
        #expect(!commandsDiag.isEmpty, "Should flag missing .commands on iPadOS")
    }

    // MARK: - Tier 1: Navigation Pattern

    @Test("Flags NavigationStack on macOS")
    func navigationStackFlaggedOnMacOS() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                NavigationStack {
                    List { Text("Item") }
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let navDiag = result.diagnostics.filter { $0.ruleId == "hig.navigation-pattern" }
        #expect(!navDiag.isEmpty, "Should flag NavigationStack on macOS")
    }

    @Test("Does not flag NavigationStack on iOS")
    func navigationStackOKOnIOS() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                NavigationStack {
                    List { Text("Item") }
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        let navDiag = result.diagnostics.filter { $0.ruleId == "hig.navigation-pattern" }
        #expect(navDiag.isEmpty, "Should not flag NavigationStack on iOS")
    }

    @Test("NavigationSplitView does not trigger warning")
    func navigationSplitViewOK() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                NavigationSplitView {
                    List { Text("Sidebar") }
                } detail: {
                    Text("Detail")
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let navDiag = result.diagnostics.filter { $0.ruleId == "hig.navigation-pattern" }
        #expect(navDiag.isEmpty, "NavigationSplitView should not trigger warning")
    }

    // MARK: - Exemptions

    @Test("HIG-EXEMPT comment suppresses diagnostic")
    func exemptionWorks() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                // HIG-EXEMPT: single-purpose utility
                NavigationStack {
                    Text("Simple tool")
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let navDiag = result.diagnostics.filter { $0.ruleId == "hig.navigation-pattern" }
        #expect(navDiag.isEmpty, "HIG-EXEMPT should suppress the diagnostic")
        #expect(!result.overrides.isEmpty, "Should record the override")
    }

    // MARK: - Tier 2: Semantic Colors

    @Test("Flags hardcoded Color.blue")
    func flagsHardcodedColorBlue() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                Text("Hello").foregroundStyle(Color.blue)
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .all)
        let colorDiag = result.diagnostics.filter { $0.ruleId == "hig.semantic-colors" }
        #expect(!colorDiag.isEmpty, "Should flag Color.blue")
    }

    @Test("Does not flag Color.clear")
    func allowsColorClear() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                Text("Hello").background(Color.clear)
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .all)
        let colorDiag = result.diagnostics.filter { $0.ruleId == "hig.semantic-colors" }
        #expect(colorDiag.isEmpty, "Should not flag Color.clear")
    }

    // MARK: - Tier 2: Toolbar Tooltips

    @Test("Flags toolbar button without .help()")
    func toolbarButtonMissingHelp() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                Text("Content")
                    .toolbar {
                        ToolbarItem {
                            Button("Add") { }
                        }
                    }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let helpDiag = result.diagnostics.filter { $0.ruleId == "hig.toolbar-tooltips" }
        #expect(!helpDiag.isEmpty, "Should flag toolbar button without .help()")
    }

    @Test("Passes toolbar button with .help()")
    func toolbarButtonWithHelp() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                Text("Content")
                    .toolbar {
                        ToolbarItem {
                            Button("Add") { }
                                .help("Add new item")
                        }
                    }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let helpDiag = result.diagnostics.filter { $0.ruleId == "hig.toolbar-tooltips" }
        #expect(helpDiag.isEmpty, "Should not flag toolbar button with .help()")
    }

    // MARK: - Platform Detection

    @Test("Detects macOS from Package.swift content")
    func detectsMacOS() {
        let manifest = """
        let package = Package(
            platforms: [.macOS(.v15)]
        )
        """
        let platforms = PlatformDetector.detectFromManifestContents(manifest)
        #expect(platforms.contains(.macOS))
        #expect(!platforms.contains(.iOS))
    }

    @Test("Detects multiple platforms")
    func detectsMultiplePlatforms() {
        let manifest = """
        let package = Package(
            platforms: [.macOS(.v15), .iOS(.v17), .visionOS(.v2)]
        )
        """
        let platforms = PlatformDetector.detectFromManifestContents(manifest)
        #expect(platforms.contains(.macOS))
        #expect(platforms.contains(.iOS))
        #expect(platforms.contains(.iPadOS))
        #expect(platforms.contains(.visionOS))
        #expect(!platforms.contains(.tvOS))
    }

    @Test("Returns .all when no platforms specified")
    func defaultsToAll() {
        let manifest = """
        let package = Package(name: "MyPackage")
        """
        let platforms = PlatformDetector.detectFromManifestContents(manifest)
        #expect(platforms == .all)
    }

    // MARK: - Tier 2: Context Menus

    @Test("Flags List without .contextMenu")
    func listWithoutContextMenu() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                List(items) { item in
                    Text(item.name)
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let ctxDiag = result.diagnostics.filter { $0.ruleId == "hig.context-menus" }
        #expect(!ctxDiag.isEmpty, "Should flag List without .contextMenu")
    }

    @Test("Does not flag standalone ForEach without .contextMenu")
    func standaloneForEachNotFlagged() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                Picker("Choice", selection: $selection) {
                    ForEach(options) { option in
                        Text(option.name).tag(option)
                    }
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let ctxDiag = result.diagnostics.filter { $0.ruleId == "hig.context-menus" }
        #expect(ctxDiag.isEmpty, "Standalone ForEach should not trigger context menu warning")
    }

    @Test("Passes List with .contextMenu")
    func listWithContextMenu() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                List(items) { item in
                    Text(item.name)
                        .contextMenu {
                            Button("Delete") { }
                        }
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let ctxDiag = result.diagnostics.filter { $0.ruleId == "hig.context-menus" }
        #expect(ctxDiag.isEmpty, "Should not flag List with .contextMenu")
    }

    // MARK: - Non-SwiftUI files skipped

    @Test("Skips files without import SwiftUI")
    func skipsNonSwiftUIFiles() {
        let source = """
        import Foundation
        struct MyModel {
            let name: String
        }
        """
        let result = auditor.auditSource(source, fileName: "MyModel.swift", activePlatforms: .all)
        #expect(result.diagnostics.isEmpty, "Non-SwiftUI files should produce no diagnostics")
    }
}
