// IJSDashboardApp.swift
// IJSDashboardApp
//
// The standalone macOS app. A real SwiftUI `App` (WindowGroup) — so it gets the
// full standard menu bar, window management, and fullscreen for free, unlike the
// hand-rolled NSApplication the CLI's --native path used. It self-loads the corpus
// (from a --corpus-path argument, the IJS_CORPUS_PATH env var, a remembered path,
// or a folder picker) and renders the portfolio dashboard.

import SwiftUI
import AppKit
#if canImport(os)
import os
#endif
import IJSDashboardCore
import IJSDashboardUI

@main
struct IJSDashboardApp: App {
    @AppStorage("corpusPath") private var corpusPath: String = ""

    var body: some Scene {
        WindowGroup("IJS Portfolio Dashboard") {
            DashboardRootView()
                .frame(minWidth: 820, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {     // the dashboard has no documents
                Button("Refresh") {
                    NotificationCenter.default.post(name: .ijsRefreshCorpus, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("Corpus") {
                Button("Choose Corpus…") {
                    NotificationCenter.default.post(name: .ijsChooseCorpus, object: nil)
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            DashboardSettingsView(corpusPath: $corpusPath)
        }
    }
}

extension Notification.Name {
    /// Posted by the Corpus menu command to open the corpus folder picker.
    static let ijsChooseCorpus = Notification.Name("ijsChooseCorpus")
    /// Posted by the File ▸ Refresh command (⌘R) to reload the active corpus.
    static let ijsRefreshCorpus = Notification.Name("ijsRefreshCorpus")
}

/// The Settings (⌘,) pane: shows and clears the remembered corpus location.
struct DashboardSettingsView: View {
    @Binding var corpusPath: String

    var body: some View {
        Form {
            LabeledContent("Corpus") {
                Text(corpusPath.isEmpty ? "Not set" : corpusPath)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Forget remembered corpus") { corpusPath = "" }
                .disabled(corpusPath.isEmpty)
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Loads the corpus and shows the dashboard, a loading state, an error, or a
/// corpus picker.
struct DashboardRootView: View {

    private enum LoadState {
        case needsCorpus
        case loading
        case loaded(DashboardData)
        case failed(String)
    }

    @State private var state: LoadState = .loading
    /// The corpus path currently displayed — the source a refresh reloads,
    /// regardless of whether it came from an argument, the environment, or a pick.
    @State private var activeCorpusPath: String?
    /// The newest corpus modification time seen at the last load, so the
    /// auto-refresh poll only reloads when the corpus actually changed.
    @State private var lastCorpusSignature: Date?
    @AppStorage("corpusPath") private var savedCorpusPath: String = ""

    private static let logger = Logger(subsystem: "org.roseclub.IJSDashboard", category: "load")
    /// Auto-refresh cadence — mirrors the CLI dashboard's 30-second reload.
    private static let refreshIntervalSeconds: UInt64 = 30

    var body: some View {
        content
            .task { await initialLoad() }
            .task { await autoRefreshLoop() }
            .onReceive(NotificationCenter.default.publisher(for: .ijsChooseCorpus)) { _ in
                chooseCorpus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .ijsRefreshCorpus)) { _ in
                Task { await manualRefresh() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case let .loaded(data):
            PortfolioDashboardView(portfolio: data.portfolio, projects: data.projects,
                                   pulse: data.pulse, health: data.health, groups: data.groups,
                                   inbox: data.inbox, trends: data.trends)
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading corpus…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsCorpus:
            messageView(
                title: "Choose an IJS corpus",
                message: "Pick the org-judgement-corpus directory to load the dashboard.",
                button: "Choose Corpus…") { chooseCorpus() }
        case let .failed(reason):
            messageView(
                title: "Couldn’t load the corpus",
                message: reason,
                button: "Choose a different corpus…") { chooseCorpus() }
        }
    }

    private func messageView(title: String, message: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(button, action: action).controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loading

    private func initialLoad() async {
        guard case .loading = state else { return }
        guard let path = resolvedCorpusPath() else { state = .needsCorpus; return }
        await load(path)
    }

    /// Loads `path` and shows it.
    ///
    /// - Parameter silent: when true, the current dashboard stays on screen
    ///   during the reload (no loading spinner) and a failed read is logged but
    ///   leaves the last-good data in place. This is how the auto-refresh poll
    ///   and an in-place manual refresh update without flicker; a cold load
    ///   (`silent: false`) shows the loading and error states.
    private func load(_ path: String, silent: Bool = false) async {
        if !silent { state = .loading }
        do {
            let (data, signature) = try await Task.detached(priority: .userInitiated) {
                let data = try DashboardLoader.load(corpusPath: path)
                return (data, DashboardLoader.corpusSignature(at: path))
            }.value
            savedCorpusPath = path
            activeCorpusPath = path
            lastCorpusSignature = signature
            state = .loaded(data)
        } catch {
            Self.logger.error("Corpus load failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !silent { state = .failed(error.localizedDescription) }
        }
    }

    // MARK: Refresh

    /// Polls the active corpus on the same 30-second cadence as the CLI and
    /// reloads in place when it changes. Runs for the window's lifetime;
    /// SwiftUI cancels the backing task when the view goes away.
    private func autoRefreshLoop() async {
        while !Task.isCancelled {
            // silent: a cancelled sleep just ends the loop via the while guard
            try? await Task.sleep(nanoseconds: Self.refreshIntervalSeconds * 1_000_000_000)
            await refreshIfChanged()
        }
    }

    /// Reloads the active corpus only when its newest modification time has
    /// advanced since the last load — so an idle poll costs a directory stat,
    /// not a full re-parse and re-render.
    private func refreshIfChanged() async {
        guard case .loaded = state, let path = activeCorpusPath else { return }
        let newest = await Task.detached(priority: .utility) { DashboardLoader.corpusSignature(at: path) }.value
        if let newest, let last = lastCorpusSignature, newest <= last { return }
        await load(path, silent: true)
    }

    /// The File ▸ Refresh (⌘R) handler: reloads the shown corpus in place, or
    /// retries resolving one (with progress) when nothing is loaded yet.
    private func manualRefresh() async {
        if case .loaded = state, let path = activeCorpusPath {
            await load(path, silent: true)
        } else if let path = resolvedCorpusPath() {
            await load(path)
        } else {
            chooseCorpus()
        }
    }

    /// The newest content-modification date anywhere under the corpus directory —
    /// a cheap change signature for the auto-refresh poll. Returns nil when the
    /// tree can't be enumerated (the caller then reloads unconditionally).
    nonisolated static func corpusSignature(_ path: String) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: keys
        ) else { return nil }
        var newest: Date?
        for case let fileURL as URL in enumerator {
            // silent: a file whose mtime can't be read simply doesn't advance the signature
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate else { continue }
            if let current = newest {
                if modified > current { newest = modified }
            } else {
                newest = modified
            }
        }
        return newest
    }

    /// A corpus path from a launch argument, the environment, or a remembered pick.
    private func resolvedCorpusPath() -> String? {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--corpus-path"), index + 1 < arguments.count {
            return arguments[index + 1]
        }
        if let env = ProcessInfo.processInfo.environment["IJS_CORPUS_PATH"], !env.isEmpty {
            return env
        }
        return savedCorpusPath.isEmpty ? nil : savedCorpusPath
    }

    @MainActor
    private func chooseCorpus() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Corpus"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url.path) }
    }
}
