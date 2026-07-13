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
        // A native composition: the header and analytical sections come from the
        // shared SwiftGUIKit scene; the projects table is a native, sortable,
        // resizable `Table`; the narrative is native Markdown. The page scrolls as
        // a whole, and the table gets a bounded height so it doesn't collapse.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("IJS Portfolio Dashboard").font(.title2.bold())

                renderer.view(for: PortfolioScene.headerScene(portfolio: portfolio, pulse: pulse))

                ProjectsTableView(projects: projects)
                    .frame(minHeight: 280, maxHeight: 460)

                renderer.view(for: PortfolioScene.sectionsScene(portfolio: portfolio, pulse: pulse))

                if let snapshots = pulse?.statistics.corpusSnapshots, !snapshots.isEmpty {
                    // No fixed height: EditorialChartView hardcodes its own plot
                    // height (~300pt + furniture); constraining it smaller makes it
                    // draw past its frame onto the next section.
                    CorpusTrendChartView(snapshots: snapshots)
                }

                renderer.view(for: PortfolioScene.pulseAnalyticsScene(pulse: pulse))

                if let clusters = pulse?.violationClusters, !clusters.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Violation Clusters").font(.headline)
                        ClustersTableView(clusters: clusters)
                            .frame(minHeight: 120, maxHeight: 260)
                    }
                }

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
