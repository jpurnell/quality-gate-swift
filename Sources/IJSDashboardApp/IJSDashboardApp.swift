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
            CommandGroup(replacing: .newItem) { }   // the dashboard has no documents
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
    @AppStorage("corpusPath") private var savedCorpusPath: String = ""

    private static let logger = Logger(subsystem: "org.roseclub.IJSDashboard", category: "load")

    var body: some View {
        content
            .task { await initialLoad() }
            .onReceive(NotificationCenter.default.publisher(for: .ijsChooseCorpus)) { _ in
                chooseCorpus()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case let .loaded(data):
            PortfolioDashboardView(portfolio: data.portfolio, projects: data.projects,
                                   pulse: data.pulse, health: data.health)
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

    private func load(_ path: String) async {
        state = .loading
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try DashboardLoader.load(corpusPath: path)
            }.value
            savedCorpusPath = path
            state = .loaded(data)
        } catch {
            Self.logger.error("Corpus load failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
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
