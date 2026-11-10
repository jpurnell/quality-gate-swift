import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// One Swift source file handed to the MetricKit rules.
struct MetricKitSourceFile: Sendable, Equatable {
    /// Path used in diagnostics.
    let path: String
    /// File contents.
    let source: String
}

/// The sources one app target compiles, judged as a unit by the MetricKit rules.
struct MetricKitTarget: Sendable, Equatable {
    /// Target name, used in messages.
    let name: String
    /// Platforms the target builds for (`iOS`, `watchOS`, ...); empty when unknown.
    let platforms: [String]
    /// The target's source files.
    let files: [MetricKitSourceFile]
}

extension LoggingAuditor {
    static let noSubscriberRuleId = "logging.no-metrickit-subscriber"
    static let payloadIgnoredRuleId = "logging.metrickit-payload-ignored"

    private static let remedy = "Add a type conforming to `MXMetricManagerSubscriber` and register it with `MXMetricManager.shared.add(_:)` when the app starts (an `App` init or `application(_:didFinishLaunchingWithOptions:)`), behind `#if canImport(MetricKit)`; see DiagnosticsAndFeedback.md"

    /// Judges each app target on its own sources against the two MetricKit rules.
    ///
    /// Skipped (empty, `.skipped`) for `library` and `cli` projects, and for a project whose
    /// config declares no `distribution`. Findings carry `metricKitSeverity` (note by default). A target with no app entry
    /// point is not an app and is never flagged. The `// logging:` exemption comment is not
    /// consulted: only a structural exemption (project type, platform list) applies.
    func auditMetricKit(targets: [MetricKitTarget]) -> CheckResult {
        let start = ContinuousClock.now
        guard config.projectType == "application", !config.distribution.isEmpty else {
            return CheckResult(checkerId: id, status: .skipped, diagnostics: [], duration: ContinuousClock.now - start)
        }
        var diagnostics: [Diagnostic] = []
        for target in targets {
            diagnostics.append(contentsOf: evaluateMetricKit(target))
        }
        return CheckResult(
            checkerId: id,
            status: status(for: diagnostics),
            diagnostics: diagnostics,
            duration: ContinuousClock.now - start
        )
    }

    private func status(for diagnostics: [Diagnostic]) -> CheckResult.Status {
        if diagnostics.contains(where: { $0.severity == .error }) { return .failed }
        if diagnostics.contains(where: { $0.severity == .warning }) { return .warning }
        return .passed
    }

    private var metricKitDiagnosticSeverity: Diagnostic.Severity {
        switch config.metricKitSeverity {
        case .note: return .note
        case .warning: return .warning
        case .error: return .error
        }
    }

    private func evaluateMetricKit(_ target: MetricKitTarget) -> [Diagnostic] {
        var facts = MetricKitFileFacts()
        for file in target.files {
            let tree = Parser.parse(source: file.source)
            let visitor = MetricKitFactsVisitor(
                file: file.path,
                converter: SourceLocationConverter(fileName: file.path, tree: tree),
                customLoggerNames: config.customLoggerNames
            )
            visitor.walk(tree)
            let part = visitor.facts
            if facts.entryPoint == nil { facts.entryPoint = part.entryPoint }
            facts.entryHints.formUnion(part.entryHints)
            facts.subscribers += part.subscribers
            facts.handlers += part.handlers
            facts.functions += part.functions
        }
        guard let entry = facts.entryPoint else { return [] }

        let platforms = resolvedPlatforms(of: target, hints: facts.entryHints)
        let unsupported = Set(config.metricKitUnsupportedPlatforms.map { $0.lowercased() })
        if !platforms.isEmpty, platforms.allSatisfy({ unsupported.contains($0.lowercased()) }) { return [] }

        let subscribers = facts.subscribers.filter(\.active)
        if subscribers.isEmpty || !registrationReachable(in: facts) {
            let why = subscribers.isEmpty
                ? "has no type conforming to `MXMetricManagerSubscriber`"
                : "never registers a subscriber with `MXMetricManager.shared.add(_:)` from app start"
            return [Diagnostic(
                severity: metricKitDiagnosticSeverity,
                message: "App target `\(target.name)` \(why), so crash, hang and exit reports from users are never read",
                filePath: entry.file,
                lineNumber: entry.line,
                ruleId: Self.noSubscriberRuleId,
                suggestedFix: Self.remedy
            )]
        }
        return payloadFindings(subscribers: subscribers, facts: facts, platforms: platforms)
    }

    /// True when a registration sits in a start root, or one call level below it.
    ///
    /// A registration is reachable if its function is a root (an `App` initializer or a launch
    /// hook), is called by name from a root, or is an initializer of a type a root mentions.
    private func registrationReachable(in facts: MetricKitFileFacts) -> Bool {
        let roots = facts.functions.filter(\.isStartRoot)
        for function in facts.functions where function.registers {
            if function.isStartRoot { return true }
            for root in roots {
                if function.isInitializer, let owner = function.owner, root.referenced.contains(owner) { return true }
                if !function.isInitializer, root.referenced.contains(function.name) { return true }
            }
        }
        return false
    }

    private func payloadFindings(
        subscribers: [MetricKitSubscriberFact], facts: MetricKitFileFacts, platforms: [String]
    ) -> [Diagnostic] {
        let noDiagnostics = Set(config.metricKitNoDiagnosticPlatforms.map { $0.lowercased() })
        let diagnosticsExpected = platforms.isEmpty || !platforms.allSatisfy { noDiagnostics.contains($0.lowercased()) }
        var out: [Diagnostic] = []
        var seen = Set<String>()
        for subscriber in subscribers where seen.insert(subscriber.name).inserted {
            let handlers = facts.handlers.filter { $0.owner == subscriber.name }
            let required: [(MetricKitHandlerFact.Kind, String)] = diagnosticsExpected
                ? [(.metric, "[MXMetricPayload]"), (.diagnostic, "[MXDiagnosticPayload]")]
                : [(.metric, "[MXMetricPayload]")]
            for (kind, type) in required {
                let matching = handlers.filter { $0.kind == kind }
                if matching.isEmpty {
                    out.append(payloadDiagnostic(
                        "Subscriber `\(subscriber.name)` has no `didReceive(_: \(type))` method, so those payloads are dropped",
                        file: subscriber.file, line: subscriber.line
                    ))
                } else if !matching.contains(where: \.passesPayloadOn) {
                    let handler = matching[0]
                    out.append(payloadDiagnostic(
                        "`\(subscriber.name).didReceive(_: \(type))` only logs or ignores the payload; hand it to a store, queue or uploader",
                        file: handler.file, line: handler.line
                    ))
                }
            }
        }
        return out
    }

    private func payloadDiagnostic(_ message: String, file: String, line: Int) -> Diagnostic {
        Diagnostic(
            severity: metricKitDiagnosticSeverity,
            message: message,
            filePath: file,
            lineNumber: line,
            ruleId: Self.payloadIgnoredRuleId,
            suggestedFix: "Write the payload to a file, enqueue it, or pass it to another function; logging alone does not count"
        )
    }

    /// Platforms for a target: the build-settings answer when the caller has one, otherwise a
    /// hint from the entry-point protocol (`WKApplicationDelegate` is watchOS), otherwise a
    /// token in the target name, otherwise unknown.
    private func resolvedPlatforms(of target: MetricKitTarget, hints: Set<String>) -> [String] {
        if !target.platforms.isEmpty { return target.platforms }
        if !hints.isEmpty { return hints.sorted() }
        let lowered = target.name.lowercased()
        for (token, platform) in [("watch", "watchOS"), ("tvos", "tvOS"), ("visionos", "visionOS"), ("macos", "macOS")]
        where lowered.contains(token) { return [platform] }
        return []
    }
}
