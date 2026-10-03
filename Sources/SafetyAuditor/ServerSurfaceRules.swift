import Foundation
import QualityGateCore
import ServerSurface
import SwiftParser
import SwiftSyntax

/// `security.bind-all-interfaces` and `security.listener-auth-optional`: the first consumers of
/// the server-surface inventory.
///
/// Both are package-wide questions answered per site. Whether a `host` default is a bind
/// address depends on whether the package opens a socket; whether an authenticator defaulting
/// to `nil` matters depends on whether its *target* does — SwiftCLIKit declares `authMode` in
/// one file and opens the socket in another. So the rules read the joined inventory, and each
/// finding is then reported through `SecurityVisitor.report(_:)` against its own file, which is
/// what makes a `// SECURITY:` acknowledgement on the line above work as it does for every
/// other security rule.
///
/// Plans: `AHandlerThatAnyoneCanCall.md` §3.1 and `AHandlerSaysWhoMayCallIt.md` §3.3,
/// reconciled per `TheGateIsNotYetAggressive.md` §2.1 — one bind rule; the authenticator
/// *parameter* rule kept; the fail-open *function* rule reduced to the case only it could see,
/// a flag read from the environment.
enum ServerSurfaceRules {

    static let bindRule = "security.bind-all-interfaces"
    static let authRule = "security.listener-auth-optional"
    static let coverageRule = "security.server-surface-coverage"
    static let ruleIds: Set<String> = [bindRule, authRule]

    /// Labels that name a bind address and nothing else, so an argument under one is a bind
    /// wherever the package opens a socket — VaultMCP's `bindAddress:` reaches its bootstrap
    /// through an options struct.
    static let unambiguousBindLabels: Set<String> = ["bindAddress", "bindHost", "listenAddress"]

    /// One finding, before it is reported against its file.
    struct Finding {
        let ruleId: String
        let severity: Diagnostic.Severity
        let message: String
        let suggestedFix: String
        let site: SourceSite
    }

    /// Every finding the inventory supports, for the rules `isEnabled` admits.
    static func findings(in inventory: ServerSurfaceInventory, isEnabled: (String) -> Bool) -> [Finding] {
        var found: [Finding] = []
        if isEnabled(bindRule) { found += bindFindings(inventory) }
        if isEnabled(authRule) { found += authFindings(inventory) }
        return found
    }

    // MARK: - bind-all-interfaces (CWE-1327)

    static func bindFindings(_ inventory: ServerSurfaceInventory) -> [Finding] {
        let packageListens = !inventory.listenerTargets.isEmpty
        var found = inventory.hostSettings
            .filter { $0.addressKind == .allInterfaces && !$0.inTestTarget }
            .compactMap { bindFinding($0, inventory: inventory, packageListens: packageListens) }
        for listener in inventory.productionListeners {
            guard case .frameworkDefault(.allInterfaces, let note) = listener.host else { continue }
            found.append(Finding(
                ruleId: bindRule, severity: .warning,
                message: "\(note), so anything that can reach this machine can connect. "
                    + "\(SecurityVisitor.citation(bindRule))",
                suggestedFix: "Set parameters.requiredLocalEndpoint = .hostPort(host: \"127.0.0.1\", port: …), "
                    + "or acknowledge with // SECURITY: naming what stands in front of it",
                site: listener.site))
        }
        return found
    }

    private static func bindFinding(_ setting: HostSetting, inventory: ServerSurfaceInventory, packageListens: Bool) -> Finding? {
        let quoted = "\"\(setting.value)\""
        switch setting.kind {
        case .bindArgument:
            return Finding(
                ruleId: bindRule, severity: .error,
                message: "Listener bound to \(quoted), every interface, by a literal at the bind: a caller "
                    + "cannot narrow it without editing this code. \(SecurityVisitor.citation(bindRule))",
                suggestedFix: "Bind 127.0.0.1 and let a reverse proxy face the network, or take the host as a "
                    + "parameter; if every interface is intended, say why with // SECURITY:",
                site: setting.site)
        case .parameterDefault, .propertyDefault, .assignment:
            guard packageListens else { return nil }
            return defaultFinding(setting, quoted: quoted)
        case .argument:
            let callee = setting.callee ?? ""
            let reachesListener = setting.fileHasListener || inventory.listenerOwningTypes.contains(callee)
                || (unambiguousBindLabels.contains(setting.name) && packageListens)
            guard reachesListener else { return nil }
            return defaultFinding(setting, quoted: quoted)
        }
    }

    private static func defaultFinding(_ setting: HostSetting, quoted: String) -> Finding {
        Finding(
            ruleId: bindRule, severity: .warning,
            message: "'\(setting.name)' is \(quoted), every interface, unless someone changes it — and in a "
                + "package that opens a listener, nobody decided. \(SecurityVisitor.citation(bindRule))",
            suggestedFix: "Default to \"127.0.0.1\" and make the wider address something an operator asks for; "
                + "if every interface is intended, say why with // SECURITY:",
            site: setting.site)
    }

    // MARK: - listener-auth-optional (CWE-1188)

    static func authFindings(_ inventory: ServerSurfaceInventory) -> [Finding] {
        inventory.authSettings.filter { !$0.inTestTarget }.compactMap { setting in
            switch setting.kind {
            case .parameterDefault, .propertyDefault:
                guard inventory.targetHasListener(setting.target) else { return nil }
                return authFinding(setting, what: "'\(setting.names.joined(separator: "', '"))' defaults to "
                    + "\(setting.value) in a target that opens a listener: whoever constructs it without one gets a "
                    + "server that authenticates nobody")
            case .environmentFlag:
                guard inventory.targetHasListener(setting.target) else { return nil }
                return authFinding(setting, what: environmentSentence(setting))
            case .argument:
                return authFinding(setting, what: "\(setting.callee ?? "A listener") is constructed with "
                    + "'\(setting.names.joined(separator: "', '"))' passed as \(setting.value): it will accept "
                    + "requests from anyone who can reach it")
            }
        }
    }

    private static func environmentSentence(_ setting: AuthSetting) -> String {
        let variable = setting.environmentKey.map { "the environment variable \($0)" } ?? "an environment variable"
        let name = setting.names.first ?? "authentication"
        switch setting.state {
        case .offUnlessSet:
            return "'\(name)' is off unless \(variable) is set: a server launched without it authenticates nobody"
        case .onUnlessDisabled, .off:
            return "'\(name)' is on unless \(variable) turns it off on the deployed host, and nothing in source "
                + "records where that is decided"
        }
    }

    private static func authFinding(_ setting: AuthSetting, what: String) -> Finding {
        Finding(
            ruleId: authRule, severity: .warning,
            message: what + " — an insecure default whose consequence is missing authentication (CWE-306). "
                + SecurityVisitor.citation(authRule),
            suggestedFix: "Make the authenticator required (no default), or default to one that rejects; if "
                + "no authentication is intended here, say what stands in front instead with // SECURITY:",
            site: setting.site)
    }

    // MARK: - Coverage

    /// The `security.server-surface-coverage` note: the inventory's summary and how many findings
    /// were acknowledged. Emitted with zeros; not emitted when neither rule runs.
    static func coverageNote(_ inventory: ServerSurfaceInventory, overrides: [DiagnosticOverride]) -> Diagnostic {
        let acknowledged = overrides.filter { ruleIds.contains($0.ruleId) }.count
        return Diagnostic(
            severity: .note,
            message: "security.server-surface \(inventory.summary) · \(acknowledged) acknowledged",
            ruleId: coverageRule)
    }
}

extension SafetyAuditor {

    /// What the server-surface rules produced for one package.
    struct ServerSurfaceOutcome {
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
        var inventory = ServerSurfaceInventory()
    }

    /// Whether either server-surface rule runs under `security`.
    static func serverSurfaceEnabled(_ security: SecurityAuditorConfig) -> Bool {
        security.enabledRules.isEmpty || ServerSurfaceRules.ruleIds.contains(where: security.enabledRules.contains)
    }

    /// Joins `facts`, runs both rules, and reports each finding through its file's
    /// `SecurityVisitor`, so acknowledgements are validated and recorded as everywhere else.
    ///
    /// - Parameter source: The text of a file by name — read from disk for a package run,
    ///   from memory for a single-source audit.
    static func runServerSurface(
        facts: [ServerSurfaceFileFacts],
        targets: TargetTypeMap,
        configuration: Configuration,
        includeNote: Bool = true,
        source: (String) -> String?
    ) -> ServerSurfaceOutcome {
        var outcome = ServerSurfaceOutcome()
        guard serverSurfaceEnabled(configuration.security) else { return outcome }
        outcome.inventory = ServerSurfaceInventory(files: facts, targets: targets)
        let security = configuration.security
        let found = ServerSurfaceRules.findings(in: outcome.inventory) {
            security.enabledRules.isEmpty || security.enabledRules.contains($0)
        }
        for (file, findings) in Dictionary(grouping: found, by: \.site.file).sorted(by: { $0.key < $1.key }) {
            guard let text = source(file) else { continue }
            let tree = Parser.parse(source: text)
            let visitor = SecurityVisitor(
                fileName: file, source: text,
                converter: SourceLocationConverter(fileName: file, tree: tree),
                configuration: security)
            for finding in findings.sorted(by: { $0.site < $1.site }) {
                visitor.report(Diagnostic(
                    severity: finding.severity, message: finding.message, filePath: file,
                    lineNumber: finding.site.line, columnNumber: finding.site.column,
                    ruleId: finding.ruleId, suggestedFix: finding.suggestedFix))
            }
            outcome.diagnostics += visitor.diagnostics
            outcome.overrides += visitor.overrides
        }
        // A package-level statement, so only a package run makes it — the XML note's rule.
        if includeNote {
            outcome.diagnostics.append(ServerSurfaceRules.coverageNote(outcome.inventory, overrides: outcome.overrides))
        }
        return outcome
    }

    /// The server-surface rules over in-memory sources. For tests and single-source audits.
    static func auditServerSurface(
        sources: [(path: String, source: String)],
        targets: TargetTypeMap,
        configuration: Configuration
    ) -> ServerSurfaceOutcome {
        let texts = Dictionary(sources.map { ($0.path, $0.source) }, uniquingKeysWith: { first, _ in first })
        return runServerSurface(
            facts: sources.map { ServerSurfaceFileFacts.collect(source: $0.source, fileName: $0.path) },
            targets: targets, configuration: configuration, source: { texts[$0] })
    }
}
