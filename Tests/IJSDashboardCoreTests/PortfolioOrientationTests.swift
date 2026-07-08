import Foundation
import Testing
@testable import IJSDashboardCore
import IJSSensor

@Suite("PortfolioOrientation")
struct PortfolioOrientationTests {

    private let ts = Date(timeIntervalSince1970: 1_777_536_311)

    // A small Iconquer-shaped portfolio:
    //   IconquerApp   built from Core, GameKit, swift-syntax(external)
    //   IconquerCLI   built from Core
    //   IconquerGameKit built from Core
    //   IconquerCore  built from swift-crypto(external only)
    private func portfolio() -> [String: OrientationReport] {
        func report(_ id: String, _ deps: [String], summary: String? = nil) -> OrientationReport {
            OrientationReport(projectID: id, timestamp: ts, cards: [], packageDependsOn: deps, packageSummary: summary)
        }
        return [
            "IconquerApp": report("IconquerApp", ["IconquerCore", "IconquerGameKit", "swift-syntax"], summary: "The game app."),
            "IconquerCLI": report("IconquerCLI", ["IconquerCore"]),
            "IconquerGameKit": report("IconquerGameKit", ["IconquerCore"]),
            "IconquerCore": report("IconquerCore", ["swift-crypto"]),
        ]
    }

    @Test("relied-on-by is inverted across the corpus; foundation library role")
    func foundationLibrary() {
        let cards = PortfolioOrientation.cards(from: portfolio())
        let core = cards["IconquerCore"]
        #expect(core?.reliedOnBy == ["IconquerApp", "IconquerCLI", "IconquerGameKit"])
        #expect(core?.dependsOn == [])                 // swift-crypto is external → filtered
        #expect(core?.role == "foundation library")
    }

    @Test("built-from keeps only first-party packages; product role for top-level")
    func productRole() {
        let cards = PortfolioOrientation.cards(from: portfolio())
        let app = cards["IconquerApp"]
        #expect(app?.dependsOn == ["IconquerCore", "IconquerGameKit"])   // swift-syntax filtered out
        #expect(app?.reliedOnBy == [])                                   // nothing builds on the app
        #expect(app?.role == "product")
        #expect(app?.whatItDoes == "The game app.")                      // packageSummary carried through
    }

    @Test("a package both built-from and relied-on is a shared/intermediate library")
    func sharedLibrary() {
        let cards = PortfolioOrientation.cards(from: portfolio())
        let gameKit = cards["IconquerGameKit"]
        #expect(gameKit?.dependsOn == ["IconquerCore"])
        #expect(gameKit?.reliedOnBy == ["IconquerApp"])
        #expect(gameKit?.role == "shared library")   // reliedOnBy(1) >= builtFrom(1)
    }

    @Test("role helper covers the portfolio positions")
    func roles() {
        #expect(PortfolioOrientation.portfolioRole(builtFromCount: 0, reliedOnByCount: 0) == "standalone")
        #expect(PortfolioOrientation.portfolioRole(builtFromCount: 3, reliedOnByCount: 0) == "product")
        #expect(PortfolioOrientation.portfolioRole(builtFromCount: 0, reliedOnByCount: 4) == "foundation library")
        #expect(PortfolioOrientation.portfolioRole(builtFromCount: 1, reliedOnByCount: 3) == "shared library")
        #expect(PortfolioOrientation.portfolioRole(builtFromCount: 4, reliedOnByCount: 1) == "intermediate library")
    }
}
