// IJSDashboardUI.swift
// IJSDashboardUI
//
// The native (SwiftUI) surface of the IJS dashboard — the stable entry point the
// CLI's `quality-gate dashboard --native` calls. Keeping this seam narrow (one
// launch function, no SwiftGUIKit types in its signature) is deliberate: it
// quarantines the GUI stack so the rendering approach can change (or be replaced
// wholesale) without touching IJSDashboardCore or the CLI.

#if canImport(SwiftUI)
import SwiftUI
import AppKit
import IJSDashboardCore

/// The native dashboard surface.
public enum IJSDashboardUI {

    /// Opens a native window rendering the portfolio overview and runs the app
    /// loop until it is closed. The dashboard command has already loaded the
    /// corpus and computed the summaries, so they are passed in directly — this
    /// layer only renders.
    /// - Parameters:
    ///   - portfolio: The cross-project rollup.
    ///   - projects: The per-project summaries.
    @MainActor
    public static func launch(portfolio: PortfolioSummary, projects: [ProjectSummary]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)   // a real windowed app, from a CLI process

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "IJS Portfolio Dashboard"
        window.contentView = NSHostingView(
            rootView: PortfolioDashboardView(portfolio: portfolio, projects: projects)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)

        app.activate(ignoringOtherApps: true)
        app.run()   // blocks until the window closes — the CLI process stays alive
    }
}
#endif
