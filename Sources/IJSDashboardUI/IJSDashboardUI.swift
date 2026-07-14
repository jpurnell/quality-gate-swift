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
import CorpusKit

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
    public static func launch(
        portfolio: PortfolioSummary,
        projects: [ProjectSummary],
        pulse: InstitutionalPulse? = nil,
        health: [String: [Double]] = [:],
        groups: [String: [String]] = [:],
        inbox: [String: [InboxFinding]] = [:]
    ) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)   // a real windowed app, from a CLI process
        app.mainMenu = makeMainMenu()       // so fullscreen (⌃⌘F) and its exit work

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "IJS Portfolio Dashboard"
        window.collectionBehavior.insert(.fullScreenPrimary)   // resize to fill on fullscreen
        window.contentView = NSHostingView(
            rootView: PortfolioDashboardView(portfolio: portfolio, projects: projects, pulse: pulse, health: health, groups: groups, inbox: inbox)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)

        app.activate(ignoringOtherApps: true)
        app.run()   // blocks until the window closes — the CLI process stays alive
    }

    /// A minimal main menu so the app behaves like a real Mac app: an App menu
    /// (Hide/Quit) and a View menu whose "Enter Full Screen" (⌃⌘F) toggles — and
    /// therefore also *exits* — fullscreen. Without a menu bar, fullscreen is a
    /// one-way trap.
    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let fullScreen = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreen)

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")

        return mainMenu
    }
}
#endif
