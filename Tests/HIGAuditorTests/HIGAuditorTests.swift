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

    @Test("NavigationStack in non-body property is not flagged")
    func navigationStackInSheetHelper() {
        let source = """
        import SwiftUI
        struct LobbyView: View {
            var body: some View {
                Text("Lobby")
            }
            private var createRoomSheet: some View {
                NavigationStack {
                    Form { Text("Room settings") }
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "LobbyView.swift", activePlatforms: .macOS)
        let navDiag = result.diagnostics.filter { $0.ruleId == "hig.navigation-pattern" }
        #expect(navDiag.isEmpty, "NavigationStack in non-body property should not be flagged")
    }

    @Test("NavigationStack inside conditional branch is not flagged")
    func navigationStackInConditionalBranch() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State private var showSetup = true
            var body: some View {
                Group {
                    if showSetup {
                        NavigationStack {
                            Text("Setup")
                        }
                    } else {
                        Text("Game")
                    }
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let navDiag = result.diagnostics.filter { $0.ruleId == "hig.navigation-pattern" }
        #expect(navDiag.isEmpty, "NavigationStack inside if/else branch should not be flagged")
    }

    @Test("NavigationStack as sole body content is still flagged")
    func navigationStackAsSoleBodyContent() {
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
        #expect(!navDiag.isEmpty, "NavigationStack as sole body content should still be flagged")
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

    // MARK: - Foundations: forced-color-scheme

    @Test("Flags .preferredColorScheme(.dark) locking appearance")
    func forcedColorSchemeFlagged() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View { Text("Hi").preferredColorScheme(.dark) }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.forced-color-scheme" })
    }

    @Test("No preferredColorScheme passes")
    func forcedColorSchemeClean() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View { Text("Hi") }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(!result.diagnostics.contains { $0.ruleId == "hig.forced-color-scheme" })
    }

    // MARK: - Foundations: opaque-material

    @Test("Flags opaque Color toolbar background")
    func opaqueMaterialFlagged() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View { NavigationStack { Text("x") }.toolbarBackground(Color.blue) }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.opaque-material" })
    }

    @Test("Material toolbar background and Visibility argument pass")
    func opaqueMaterialClean() {
        let materialSource = """
        import SwiftUI
        struct ContentView: View {
            var body: some View { NavigationStack { Text("x") }.toolbarBackground(.regularMaterial) }
        }
        """
        let visibilitySource = """
        import SwiftUI
        struct ContentView: View {
            var body: some View { NavigationStack { Text("x") }.toolbarBackground(.visible, for: .navigationBar) }
        }
        """
        let m = auditor.auditSource(materialSource, fileName: "M.swift", activePlatforms: .iOS)
        let v = auditor.auditSource(visibilitySource, fileName: "V.swift", activePlatforms: .iOS)
        #expect(!m.diagnostics.contains { $0.ruleId == "hig.opaque-material" })
        #expect(!v.diagnostics.contains { $0.ruleId == "hig.opaque-material" })
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

    @Test("Does not flag List whose rows are extracted into @ViewBuilder sections with context menus")
    func listWithExtractedSectionContextMenus() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                List {
                    headerSection
                    rowsSection
                }
            }
            @ViewBuilder private var headerSection: some View {
                Section { Text("Header") }
            }
            @ViewBuilder private var rowsSection: some View {
                Section {
                    ForEach(items) { item in
                        Text(item.name)
                            .contextMenu { Button("Delete") { } }
                    }
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let ctxDiag = result.diagnostics.filter { $0.ruleId == "hig.context-menus" }
        #expect(ctxDiag.isEmpty, "List delegating rows to @ViewBuilder sections should not be flagged")
    }

    @Test("Does not flag List with only static rows")
    func listWithStaticRowsNotFlagged() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                List {
                    Text("One")
                    Text("Two")
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let ctxDiag = result.diagnostics.filter { $0.ruleId == "hig.context-menus" }
        #expect(ctxDiag.isEmpty, "Static List with no data-driven items should not be flagged")
    }

    @Test("Flags List containing ForEach without .contextMenu")
    func listWithForEachWithoutContextMenu() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                List {
                    ForEach(items) { item in
                        Text(item.name)
                    }
                }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .macOS)
        let ctxDiag = result.diagnostics.filter { $0.ruleId == "hig.context-menus" }
        #expect(!ctxDiag.isEmpty, "List with a ForEach lacking context menu should be flagged")
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

    // MARK: - Input: secure-field

    @Test("Flags password TextField (should be SecureField)")
    func secureFieldFlagged() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State var pw = ""
            var body: some View { TextField("Password", text: $pw) }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.secure-field" })
    }

    @Test("SecureField for password passes")
    func secureFieldClean() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State var pw = ""
            var body: some View { SecureField("Password", text: $pw) }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(!result.diagnostics.contains { $0.ruleId == "hig.secure-field" })
    }

    // MARK: - Input: text-input-content-type

    @Test("Flags typed field missing content-type hints")
    func contentTypeFlagged() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State var email = ""
            var body: some View { TextField("Email", text: $email) }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.text-input-content-type" })
    }

    @Test("Typed field with keyboardType passes")
    func contentTypeClean() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State var email = ""
            var body: some View { TextField("Email", text: $email).keyboardType(.emailAddress) }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(!result.diagnostics.contains { $0.ruleId == "hig.text-input-content-type" })
    }

    @Test("Content-type rule is excluded on tvOS")
    func contentTypeTvOSExcluded() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State var email = ""
            var body: some View { TextField("Email", text: $email) }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .tvOS)
        #expect(!result.diagnostics.contains { $0.ruleId == "hig.text-input-content-type" })
    }

    // MARK: - Input: searchable

    @Test("Flags a raw TextField used for search")
    func searchableRawField() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State var q = ""
            var body: some View { TextField("Search", text: $q) }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.searchable" })
    }

    @Test("Flags a vague .searchable prompt")
    func searchableVaguePrompt() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State var q = ""
            var body: some View { List { Text("x") }.searchable(text: $q, prompt: "Search") }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.searchable" })
    }

    @Test("Descriptive .searchable prompt passes")
    func searchableGoodPrompt() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            @State var q = ""
            var body: some View { List { Text("x") }.searchable(text: $q, prompt: "Search recipes") }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(!result.diagnostics.contains { $0.ruleId == "hig.searchable" })
    }

    // MARK: - Input: tab-item-label

    @Test("Flags a tab item with an icon but no label")
    func tabItemNoLabel() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                TabView { Text("Home").tabItem { Image(systemName: "house") } }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(result.diagnostics.contains { $0.ruleId == "hig.tab-item-label" })
    }

    @Test("Tab item with a Label passes")
    func tabItemWithLabel() {
        let source = """
        import SwiftUI
        struct ContentView: View {
            var body: some View {
                TabView { Text("Home").tabItem { Label("Home", systemImage: "house") } }
            }
        }
        """
        let result = auditor.auditSource(source, fileName: "ContentView.swift", activePlatforms: .iOS)
        #expect(!result.diagnostics.contains { $0.ruleId == "hig.tab-item-label" })
    }
}
