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
import CorpusKit

/// A native window body rendering the IJS portfolio overview.
struct PortfolioDashboardView: View {
    /// The cross-project rollup.
    let portfolio: PortfolioSummary
    /// The per-project summaries.
    let projects: [ProjectSummary]
    /// The latest institutional pulse, if available.
    let pulse: InstitutionalPulse?

    private let renderer = SwiftUIRenderer()

    var body: some View {
        // The page is tall (table + trend + clusters + narrative), so it scrolls
        // as a whole. The narrative is rendered natively as Markdown below the
        // shared scene (excluded from the scene via includeNarrative: false).
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                renderer.view(for: PortfolioScene.scene(
                    portfolio: portfolio, projects: projects, pulse: pulse, includeNarrative: false))
                if let narrative = pulse?.narrative,
                   !narrative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Narrative").font(.headline)
                        NarrativeMarkdownView(markdown: narrative)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}
#endif
