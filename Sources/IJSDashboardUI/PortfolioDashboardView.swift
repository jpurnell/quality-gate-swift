// PortfolioDashboardView.swift
// IJSDashboardUI
//
// The SwiftUI host for the portfolio scene. It renders the SAME PortfolioScene
// Node the terminal will render — via SwiftGUIKit's SwiftUIRenderer — so this is
// the native surface of one scene, not a parallel UI.

#if canImport(SwiftUI)
import SwiftUI
import SwiftGUIKit
import SwiftGUIKitSwiftUI
import IJSDashboardCore

/// A native window body rendering the IJS portfolio overview.
struct PortfolioDashboardView: View {
    /// The cross-project rollup.
    let portfolio: PortfolioSummary
    /// The per-project summaries.
    let projects: [ProjectSummary]

    private let renderer = SwiftUIRenderer()

    var body: some View {
        // No outer ScrollView: the table renders as a `List`, which manages its
        // own scrolling. Nesting a List in a ScrollView collapses it to zero
        // height (the rows vanish), so the scene fills the window directly.
        renderer.view(for: PortfolioScene.scene(portfolio: portfolio, projects: projects))
            .padding()
            .frame(minWidth: 640, minHeight: 480, alignment: .topLeading)
    }
}
#endif
