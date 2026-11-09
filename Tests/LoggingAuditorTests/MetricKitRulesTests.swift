import Foundation
import Testing
@testable import LoggingAuditor
@testable import QualityGateCore

private let noSubscriberRule = "logging.no-metrickit-subscriber"
private let payloadRule = "logging.metrickit-payload-ignored"

private func run(
    _ files: [String: String],
    name: String = "App",
    platforms: [String] = [],
    projectType: String = "application",
    unsupported: [String] = [],
    noDiagnostics: [String] = [],
    distribution: [String] = ["testFlight"],
    severity: MetricKitSeverity = .error
) -> CheckResult {
    let config = LoggingAuditorConfig(
        projectType: projectType,
        metricKitUnsupportedPlatforms: unsupported,
        metricKitNoDiagnosticPlatforms: noDiagnostics,
        distribution: distribution,
        metricKitSeverity: severity
    )
    let target = MetricKitTarget(
        name: name,
        platforms: platforms,
        files: files.sorted { $0.key < $1.key }.map { MetricKitSourceFile(path: $0.key, source: $0.value) }
    )
    return LoggingAuditor(config: config).auditMetricKit(targets: [target])
}

private func runTargets(_ targets: [MetricKitTarget]) -> CheckResult {
    LoggingAuditor(config: LoggingAuditorConfig(distribution: ["appStore"], metricKitSeverity: .error))
        .auditMetricKit(targets: targets)
}

private let appNoSubscriber = """
import SwiftUI
@main struct DemoApp: App {
    var body: some Scene { WindowGroup { Text("hi") } }
}
"""

/// A well-formed subscriber whose handlers hand the payload on.
private let goodSubscriber = """
import MetricKit
final class Collector: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) { Store.save(payloads) }
    func didReceive(_ payloads: [MXDiagnosticPayload]) { Store.save(payloads) }
}
"""

@Suite("LoggingAuditor: logging.no-metrickit-subscriber")
struct MetricKitSubscriberTests {

    @Test("App with no subscriber: one error naming the rule, with the remedy")
    func appWithoutSubscriber() {
        let result = run(["App.swift": appNoSubscriber])
        let hits = result.diagnostics.filter { $0.ruleId == noSubscriberRule }
        #expect(hits.count == 1)
        #expect(hits.first?.severity == .error)
        #expect(result.status == .failed)
        let text = (hits.first?.message ?? "") + (hits.first?.suggestedFix ?? "")
        #expect(text.contains("MXMetricManagerSubscriber"))
        #expect(text.contains("MXMetricManager.shared.add"))
    }

    @Test("App whose init registers a subscriber: no finding")
    func initRegisters() {
        let app = """
        import SwiftUI
        import MetricKit
        @main struct DemoApp: App {
            let collector = Collector()
            init() { MXMetricManager.shared.add(collector) }
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """
        let result = run(["App.swift": app, "Collector.swift": goodSubscriber])
        #expect(result.diagnostics.isEmpty)
        #expect(result.status == .passed)
    }

    @Test("Subscriber defined but never registered: a finding")
    func neverRegistered() {
        let result = run(["App.swift": appNoSubscriber, "Collector.swift": goodSubscriber])
        #expect(result.diagnostics.contains { $0.ruleId == noSubscriberRule })
    }

    @Test("Registration in a function never called from start: a finding")
    func unreachableRegistration() {
        let app = """
        import SwiftUI
        import MetricKit
        @main struct DemoApp: App {
            init() { }
            func neverCalled() { MXMetricManager.shared.add(Collector()) }
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """
        let result = run(["App.swift": app, "Collector.swift": goodSubscriber])
        #expect(result.diagnostics.contains { $0.ruleId == noSubscriberRule })
    }

    @Test("Registration in a helper that init calls: no finding")
    func helperCalledFromInit() {
        let app = """
        import SwiftUI
        import MetricKit
        @main struct DemoApp: App {
            init() { Self.startDiagnostics() }
            static func startDiagnostics() { MXMetricManager.shared.add(Collector()) }
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """
        let result = run(["App.swift": app, "Collector.swift": goodSubscriber])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("UIApplicationDelegate registering in didFinishLaunching: no finding")
    func uiKitDelegate() {
        let delegate = """
        import UIKit
        import MetricKit
        class AppDelegate: UIResponder, UIApplicationDelegate {
            func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
                MXMetricManager.shared.add(Collector())
                return true
            }
        }
        """
        let result = run(["AppDelegate.swift": delegate, "Collector.swift": goodSubscriber])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("NSApplicationDelegate and WKApplicationDelegate are entry points")
    func otherEntryPoints() {
        let mac = "import AppKit\nfinal class D: NSObject, NSApplicationDelegate { }"
        let watch = "import WatchKit\nfinal class D: NSObject, WKApplicationDelegate { }"
        #expect(run(["D.swift": mac]).diagnostics.contains { $0.ruleId == noSubscriberRule })
        #expect(run(["D.swift": watch]).diagnostics.contains { $0.ruleId == noSubscriberRule })
    }

    @Test("A library project is skipped, no finding")
    func libraryProject() {
        let result = run(["App.swift": appNoSubscriber], projectType: "library")
        #expect(result.status == .skipped)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A command-line tool project is skipped, no finding")
    func cliProject() {
        let result = run(["App.swift": appNoSubscriber], projectType: "cli")
        #expect(result.status == .skipped)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A target with no app entry point is never flagged")
    func noEntryPoint() {
        let result = run(["Lib.swift": "public struct Helper { }"])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A platform in metricKitUnsupportedPlatforms is exempt")
    func unsupportedPlatform() {
        let result = run(["App.swift": appNoSubscriber], platforms: ["tvOS"], unsupported: ["tvos"])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("A target for several platforms is exempt only if every one is unsupported")
    func mixedPlatforms() {
        let result = run(["App.swift": appNoSubscriber], platforms: ["tvOS", "iOS"], unsupported: ["tvOS"])
        #expect(result.diagnostics.contains { $0.ruleId == noSubscriberRule })
    }

    @Test("The // logging: exemption comment does not silence the rule")
    func exemptionCommentDoesNotSilence() {
        let app = """
        import SwiftUI
        // logging: exempt, we do not want MetricKit
        @main struct DemoApp: App { // logging: not applicable
            var body: some Scene { WindowGroup { Text("hi") } } // logging: no
        }
        """
        let result = run(["App.swift": app])
        #expect(result.diagnostics.contains { $0.ruleId == noSubscriberRule })
        #expect(result.status == .failed)
    }

    @Test("Registration behind #if canImport(MetricKit) is recognised")
    func guardedRegistration() {
        let app = """
        import SwiftUI
        @main struct DemoApp: App {
            init() {
                #if canImport(MetricKit)
                MXMetricManager.shared.add(Collector())
                #endif
            }
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """
        let sub = "#if canImport(MetricKit)\n" + goodSubscriber + "\n#endif"
        let result = run(["App.swift": app, "Collector.swift": sub])
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Registration in the #else of canImport(MetricKit) is not counted")
    func wrongBranch() {
        let app = """
        import SwiftUI
        @main struct DemoApp: App {
            init() {
                #if canImport(MetricKit)
                #else
                MXMetricManager.shared.add(Collector())
                #endif
            }
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """
        let result = run(["App.swift": app, "Collector.swift": goodSubscriber])
        #expect(result.diagnostics.contains { $0.ruleId == noSubscriberRule })
    }

    @Test("Multi-target: each app target is judged on its own sources")
    func multiTarget() {
        let phone = MetricKitTarget(name: "Phone", platforms: ["iOS"], files: [
            MetricKitSourceFile(path: "Phone/App.swift", source: appNoSubscriber),
        ])
        let watchApp = """
        import SwiftUI
        import MetricKit
        @main struct WatchApp: App {
            init() { MXMetricManager.shared.add(Collector()) }
            var body: some Scene { WindowGroup { Text("w") } }
        }
        """
        let watch = MetricKitTarget(name: "Watch", platforms: ["watchOS"], files: [
            MetricKitSourceFile(path: "Watch/App.swift", source: watchApp),
            MetricKitSourceFile(path: "Watch/Collector.swift", source: goodSubscriber),
        ])
        let result = runTargets([phone, watch])
        let hits = result.diagnostics.filter { $0.ruleId == noSubscriberRule }
        #expect(hits.count == 1)
        #expect(hits.first?.filePath?.hasPrefix("Phone/") == true)
    }
}

@Suite("LoggingAuditor: logging.metrickit-payload-ignored")
struct MetricKitPayloadTests {

    private let app = """
    import SwiftUI
    import MetricKit
    @main struct DemoApp: App {
        init() { MXMetricManager.shared.add(Collector()) }
        var body: some Scene { WindowGroup { Text("hi") } }
    }
    """

    private func subscriber(metric: String?, diagnostic: String?) -> String {
        var s = "import MetricKit\nimport os\nfinal class Collector: NSObject, MXMetricManagerSubscriber {\n"
        s += "    private let logger = Logger(subsystem: \"x\", category: \"mk\")\n    private var kept: [Any] = []\n"
        if let metric { s += "    func didReceive(_ payloads: [MXMetricPayload]) { \(metric) }\n" }
        if let diagnostic { s += "    func didReceive(_ payloads: [MXDiagnosticPayload]) { \(diagnostic) }\n" }
        return s + "}\n"
    }

    private func payloadFindings(
        metric: String?, diagnostic: String?, noDiagnostics: [String] = [], platforms: [String] = []
    ) -> [Diagnostic] {
        run(
            ["App.swift": app, "Collector.swift": subscriber(metric: metric, diagnostic: diagnostic)],
            platforms: platforms, noDiagnostics: noDiagnostics
        ).diagnostics.filter { $0.ruleId == payloadRule }
    }

    @Test("An empty didReceive body is a finding")
    func emptyBody() {
        let hits = payloadFindings(metric: "", diagnostic: "Store.save(payloads)")
        #expect(hits.count == 1)
        #expect(hits.first?.severity == .error)
    }

    @Test("A body that only calls Logger or print is a finding")
    func onlyLogging() {
        let hits = payloadFindings(
            metric: "logger.info(\"got \\(payloads.count)\")",
            diagnostic: "print(payloads)"
        )
        #expect(hits.count == 2)
    }

    @Test("Logging that wraps a call inside its arguments is still only logging")
    func loggingWithNestedCall() {
        let hits = payloadFindings(
            metric: "logger.info(\"\\(payloads.map { $0.jsonRepresentation() })\")",
            diagnostic: "Store.save(payloads)"
        )
        #expect(hits.count == 1)
    }

    @Test("A body that calls a function with the payload passes")
    func callsFunction() {
        #expect(payloadFindings(metric: "Store.save(payloads)", diagnostic: "Store.save(payloads)").isEmpty)
    }

    @Test("A body that assigns or enqueues the payload passes")
    func assignsOrEnqueues() {
        let hits = payloadFindings(metric: "kept = payloads", diagnostic: "kept.append(payloads)")
        #expect(hits.isEmpty)
    }

    @Test("Logging plus a real hand-off passes")
    func loggingAndHandOff() {
        let body = "logger.info(\"got\"); Store.save(payloads)"
        #expect(payloadFindings(metric: body, diagnostic: body).isEmpty)
    }

    @Test("A subscriber missing the diagnostic method is a finding")
    func missingDiagnosticMethod() {
        let hits = payloadFindings(metric: "Store.save(payloads)", diagnostic: nil)
        #expect(hits.count == 1)
        #expect(hits.first?.message.contains("MXDiagnosticPayload") == true)
    }

    @Test("A subscriber missing the metric method is a finding")
    func missingMetricMethod() {
        let hits = payloadFindings(metric: nil, diagnostic: "Store.save(payloads)")
        #expect(hits.count == 1)
        #expect(hits.first?.message.contains("MXMetricPayload") == true)
    }

    @Test("The diagnostic method is not required where diagnostics are not delivered")
    func diagnosticNotRequired() {
        let hits = payloadFindings(
            metric: "Store.save(payloads)", diagnostic: nil,
            noDiagnostics: ["watchOS"], platforms: ["watchOS"]
        )
        #expect(hits.isEmpty)
    }

    @Test("The // logging: comment does not silence the payload rule")
    func commentDoesNotSilence() {
        let hits = payloadFindings(metric: "/* logging: ok */ ", diagnostic: "Store.save(payloads) ")
        #expect(hits.count == 1)
    }

    @Test("Payload rule runs only when the subscriber rule is satisfied")
    func notReportedWithoutSubscriber() {
        let result = run(["App.swift": appNoSubscriber])
        #expect(!result.diagnostics.contains { $0.ruleId == payloadRule })
    }

    @Test("Library projects get no payload finding")
    func libraryNoPayloadFinding() {
        let result = run(
            ["App.swift": app, "Collector.swift": subscriber(metric: "", diagnostic: "")],
            projectType: "library"
        )
        #expect(result.diagnostics.isEmpty)
    }
}

@Suite("LoggingAuditor: MetricKit config")
struct MetricKitConfigTests {
    @Test("Defaults are empty, and the requirement cannot be turned off")
    func defaults() {
        let c = LoggingAuditorConfig.default
        #expect(c.metricKitUnsupportedPlatforms.isEmpty)
        #expect(c.metricKitNoDiagnosticPlatforms.isEmpty)
        #expect(c.requireMetricKitSubscriber)
    }

    @Test("YAML-style decoding reads the platform keys and ignores requireMetricKitSubscriber: false")
    func decoding() throws {
        let json = #"{"metricKitUnsupportedPlatforms":["tvOS"],"requireMetricKitSubscriber":false}"#
        let c = try JSONDecoder().decode(LoggingAuditorConfig.self, from: Data(json.utf8))
        #expect(c.metricKitUnsupportedPlatforms == ["tvOS"])
        #expect(c.requireMetricKitSubscriber)
    }
}

@Suite("LoggingAuditor: MetricKit scoping and severity")
struct MetricKitScopingTests {
    private let phone = ["App.swift": appNoSubscriber]

    @Test("A project that declares no distribution is not evaluated at all")
    func undeclared() {
        let result = run(phone, distribution: [])
        #expect(result.diagnostics.isEmpty)
        #expect(result.status == .skipped)
    }

    @Test("A declared project yields a note by default, which does not fail the checker")
    func declaredDefaultsToNote() {
        let config = LoggingAuditorConfig(distribution: ["testFlight"])
        let target = MetricKitTarget(name: "App", platforms: [], files: [MetricKitSourceFile(path: "App.swift", source: appNoSubscriber)])
        let result = LoggingAuditor(config: config).auditMetricKit(targets: [target])
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.severity == .note)
        #expect(result.status == .passed)
    }

    @Test("metricKitSeverity sets the severity of both rules", arguments: [
        (MetricKitSeverity.note, Diagnostic.Severity.note, CheckResult.Status.passed),
        (.warning, .warning, .warning),
        (.error, .error, .failed),
    ])
    func severityOverride(setting: MetricKitSeverity, expected: Diagnostic.Severity, status: CheckResult.Status) {
        let app = """
        import SwiftUI
        import MetricKit
        @main struct DemoApp: App {
            init() { MXMetricManager.shared.add(Collector()) }
            var body: some Scene { WindowGroup { Text("hi") } }
        }
        """
        let empty = "import MetricKit\nfinal class Collector: NSObject, MXMetricManagerSubscriber {\n"
            + "func didReceive(_ p: [MXMetricPayload]) { }\nfunc didReceive(_ p: [MXDiagnosticPayload]) { }\n}"
        let rule1 = run(phone, severity: setting)
        #expect(rule1.diagnostics.map(\.severity) == [expected])
        #expect(rule1.status == status)
        let rule2 = run(["App.swift": app, "Collector.swift": empty], severity: setting)
        #expect(rule2.diagnostics.filter { $0.ruleId == payloadRule }.map(\.severity) == [expected, expected])
    }

    @Test("Each distribution channel is accepted")
    func acceptedChannels() throws {
        let json = #"{"distribution":["testFlight","appStore","developerID"]}"#
        let c = try JSONDecoder().decode(LoggingAuditorConfig.self, from: Data(json.utf8))
        #expect(c.distribution == ["testFlight", "appStore", "developerID"])
    }

    @Test("An unknown distribution value is a clear config error")
    func unknownDistribution() {
        let json = #"{"distribution":["sideload"]}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LoggingAuditorConfig.self, from: Data(json.utf8))
        }
    }

    @Test("An unknown metricKitSeverity is a config error")
    func unknownSeverity() {
        let json = #"{"metricKitSeverity":"fatal"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LoggingAuditorConfig.self, from: Data(json.utf8))
        }
    }

    @Test("Defaults: no distribution, note severity")
    func defaults() {
        #expect(LoggingAuditorConfig.default.distribution.isEmpty)
        #expect(LoggingAuditorConfig.default.metricKitSeverity == .note)
    }
}
