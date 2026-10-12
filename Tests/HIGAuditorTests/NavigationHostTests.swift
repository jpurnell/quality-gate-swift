import Foundation
import Testing
@testable import HIGAuditor
@testable import QualityGateCore

/// `hig.navigation-pattern` is about a navigation *hierarchy*, not about the word
/// `NavigationStack`.
///
/// The rule reported every `NavigationStack` reference in a `body` (outside an `if`/`switch`).
/// A sheet wraps its form in a stack to get a title bar and a toolbar; it pushes nothing, so
/// there is no hierarchy a sidebar could organise — three sites in WineTaster 4, each carrying
/// a `HIG-EXEMPT` to say so. The rule now asks whether the stack hosts navigation.
@Suite("hig.navigation-pattern: a stack that hosts navigation")
struct NavigationHostTests {
    private let auditor = HIGAuditor()
    private let ruleId = "hig.navigation-pattern"

    private func findings(_ source: String, index: NavigationHostIndex? = nil) -> [Diagnostic] {
        let result: (diagnostics: [Diagnostic], overrides: [DiagnosticOverride])
        if let index {
            result = auditor.auditSource(
                source, fileName: "View.swift", activePlatforms: .macOS, navigation: index)
        } else {
            result = auditor.auditSource(source, fileName: "View.swift", activePlatforms: .macOS)
        }
        return result.diagnostics.filter { $0.ruleId == ruleId }
    }

    // MARK: - Title-and-toolbar chrome

    /// WineTaster 4 `Wines/AddWineModal.swift:68-128`, reduced.
    @Test("A sheet's stack with a title and a toolbar hosts no navigation")
    func sheetChromeWithToolbar() {
        let found = findings("""
            import SwiftUI
            struct AddWineModal: View {
                @Environment(\\.presentationMode) var presentationMode
                @State private var wineName = ""
                var body: some View {
                    NavigationStack {
                        VStack {
                            Form {
                                Section(header: Text("Wine Name")) {
                                    TextField("Wine Name", text: self.$wineName)
                                }
                            }
                        }
                        .navigationTitle("Add Wines ")
                        .toolbar {
                            ToolbarItem(placement: .automatic) {
                                Button(action: { presentationMode.wrappedValue.dismiss() }, label: { Text("Done") })
                            }
                        }
                    }
                    .onAppear { }
                }
            }
            """)
        #expect(found.count == 0)
    }

    /// WineTaster 4 `Judges/JudgeRankingCard.swift:35-61`, reduced. `RankingSelector` is
    /// declared in the same file and `BottomButton` in another; neither pushes anything.
    @Test("A modal card whose content is other views that host nothing")
    func modalCardWithChildViews() {
        let found = findings("""
            import SwiftUI
            struct JudgeRankingCard: View {
                var body: some View {
                    NavigationStack {
                        VStack(alignment: .center) {
                            List {
                                ForEach(results) { result in
                                    RankingSelector(result, results.count)
                                }
                            }
                            BottomButton(action: { }, judge: self.judge)
                        }
                        .navigationTitle(Text("Rankings"))
                    }
                }
            }
            struct RankingSelector: View {
                var body: some View { Text("1") }
            }
            """)
        #expect(found.count == 0)
    }

    // MARK: - Near misses: a stack that does host navigation

    @Test("A stack whose content pushes with NavigationLink is reported")
    func navigationLinkInside() {
        let found = findings("""
            import SwiftUI
            struct ContentView: View {
                var body: some View {
                    NavigationStack {
                        List {
                            NavigationLink(destination: DetailView()) { Text("Item") }
                        }
                        .navigationTitle("Items")
                    }
                }
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }

    @Test("A stack with a navigationDestination is reported")
    func navigationDestinationInside() {
        let found = findings("""
            import SwiftUI
            struct ContentView: View {
                @State private var showDetail = false
                var body: some View {
                    NavigationStack {
                        Button("Open") { showDetail = true }
                    }
                    .navigationDestination(isPresented: $showDetail) { Text("Detail") }
                }
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 5)
    }

    @Test("A stack driven by a path is reported")
    func pathBoundStack() {
        let found = findings("""
            import SwiftUI
            struct ContentView: View {
                @State private var path = NavigationPath()
                var body: some View {
                    NavigationStack(path: $path) {
                        Text("Root")
                    }
                }
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 5)
    }

    /// WineTaster 4 `Load Previous Tasting/LoadingProgressView.swift:66-113`, reduced: the
    /// link lives in the row type, not in the stack's own closure.
    @Test("A stack whose row type pushes is reported")
    func navigationInAChildViewOfTheSameFile() {
        let found = findings("""
            import SwiftUI
            struct TastingListView: View {
                var body: some View {
                    NavigationStack {
                        List(previews, id: \\.url) { preview in
                            TastingPreviewRow(preview: preview)
                        }
                        .navigationTitle("Tastings")
                    }
                }
            }
            struct TastingPreviewRow: View {
                let preview: TastingPreview
                var body: some View {
                    NavigationLink { Text("Detail") } label: { Text(preview.name) }
                }
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }

    @Test("A stack whose helper property pushes is reported")
    func navigationInAHelperProperty() {
        let found = findings("""
            import SwiftUI
            struct ContentView: View {
                var body: some View {
                    NavigationStack {
                        rows
                    }
                }
                private var rows: some View {
                    List { NavigationLink("Item") { Text("Detail") } }
                }
            }
            """)
        #expect(found.count == 1)
        #expect(found.first?.lineNumber == 4)
    }

    @Test("A stack whose content is a view known elsewhere in the project to push is reported")
    func navigationInAViewFromAnotherFile() {
        let source = """
            import SwiftUI
            struct RootView: View {
                var body: some View {
                    NavigationStack {
                        LibraryList()
                    }
                }
            }
            """
        #expect(findings(source, index: NavigationHostIndex(types: ["LibraryList"])).map(\.lineNumber) == [4])
        #expect(findings(source, index: NavigationHostIndex()).count == 0)
    }

    // MARK: - The project-wide answer

    @Test("A helper declared in an extension in another file is the type's own")
    func navigationInAnExtensionElsewhere() {
        let source = """
            import SwiftUI
            struct ContentView: View {
                var body: some View {
                    NavigationStack {
                        rows
                    }
                }
            }
            """
        let index = NavigationHostIndex.build(sources: [
            source,
            """
            import SwiftUI
            extension ContentView {
                var rows: some View { List { NavigationLink("Item") { Text("Detail") } } }
            }
            struct Unrelated: View {
                var rows: some View { Text("no links") }
                var body: some View { rows }
            }
            """,
        ])
        #expect(index.membersByType["ContentView"] == ["rows"])
        #expect(findings(source, index: index).map(\.lineNumber) == [4])
    }

    @Test("Navigation hosts are found through any number of wrappers")
    func hostsAreTransitive() {
        let hosts = NavigationHostIndex.build(sources: [
            """
            import SwiftUI
            struct Row: View { var body: some View { NavigationLink("x") { Text("y") } } }
            struct Plain: View { var body: some View { Text("plain") } }
            """,
            """
            import SwiftUI
            struct Section2: View { var body: some View { VStack { Row() } } }
            struct Screen: View { var body: some View { List { Section2() } } }
            struct Sheet: View { var body: some View { Form { Plain() } } }
            """,
        ]).types
        #expect(hosts == ["Row", "Section2", "Screen"])
    }
}
