import Foundation

/// The configured exclusions in force for a run.
///
/// A marker sits on a finding; an exclusion sits in `.quality-gate.yml` and stops a finding
/// from ever being computed — a path left out of the walk, a checker not run, a function name
/// on an allow-list. None of them appeared in any output: a repository could exclude its whole
/// `Sources/` tree and print the summary of one that excluded nothing.
///
/// What is reported is what is cheap to know and true: that the key is set, what it lists,
/// and — for `excludePatterns`, where the source walk already counts them — how many files it
/// matched. How many findings an exclusion hid is not reported, because it is not known
/// without doing the work the exclusion exists to skip.
///
/// ## Keeping the table honest
///
/// The table below is written by hand, and a hand-written table of "every allow key" is
/// exactly the kind of list that goes stale. ``reportedProperties`` and
/// ``declinedProperties`` between them must account for every exclusion-shaped property in
/// the schema; a test reflects over ``Configuration`` and fails when a new one is added and
/// neither list names it.
public enum ConfigurationExclusions {

    /// One row of the table: a list-valued key and what setting it means.
    private struct ListKey {
        let property: String
        let form: String
        let meaning: String
        let configured: [String]
        let builtIn: [String]
    }

    /// Swift property paths this type reports on, as reflection names them.
    public static let reportedProperties: Set<String> = [
        "excludePatterns", "vendorPaths", "safetyExemptions", "enabledCheckers", "excludedCheckers",
        "consistency.exemptions",
        "concurrency.allowPreconcurrencyImports",
        "pointerEscape.allowedEscapeFunctions",
        "security.enabledRules", "security.allowedHTTPHosts", "security.atsAllowedInsecureDomains",
        "logging.allowedSilentTryFunctions",
        "dependencyAudit.allowBranchPins",
        "submoduleAudit.allowedPackages",
        "fpSafety.allowedFiles",
        "stochasticDeterminism.exemptFunctions", "stochasticDeterminism.exemptFiles",
        "temporalDeterminism.exemptFunctions", "temporalDeterminism.exemptFiles",
        "temporalDeterminism.exemptTypes",
        "memoryLifecycle.exemptFiles", "memoryLifecycle.loopGrowthExemptPatterns",
        "mcpReadiness.excludePaths", "appIntentsReadiness.excludePaths",
        "legibility.exemptModules", "legibility.exemptSymbols",
        "idiom.allowedShortIdentifiers",
        "keychainSecrets.allowKeys",
    ]

    /// Exclusion-shaped properties deliberately not reported, each with the reason.
    public static let declinedProperties: [String: String] = [
        "consistency.optOut":
            "a stated reason for staying out of the corpus; the registration notice already prints it",
        "flipDetector.enabled": "switches a detector inside the test checker; it hides no finding",
        "mcpReadiness.enabled": "opt-in checker, off by default; selection reports whether it ran",
        "appIntentsReadiness.enabled": "opt-in checker, off by default; selection reports whether it ran",
        "complexity.callGraphEnabled": "an analysis depth switch on an advisory checker",
        "duplication.excludeTests": "on by default; the duplication checker's coverage note states its scope",
        "xcodeBuild.skipPluginValidation": "passed through to xcodebuild; it hides no gate finding",
        "docCode.exemptionCeiling": "a ceiling on doc-code exemptions; it limits them rather than granting any",
    ]

    /// The exclusions `configuration` puts in force.
    ///
    /// - Parameters:
    ///   - configuration: The resolved configuration.
    ///   - filesExcludedByPattern: How many `.swift` files `excludePatterns` matched, when a
    ///     source walk has counted them. `nil` leaves the count out rather than printing zero.
    ///   - registeredCheckers: Every checker id in the registry, so `enabledCheckers` can
    ///     name what it leaves out. Pass it empty when the selection came from the command
    ///     line (`--check`, `--profile`): `enabledCheckers` did not decide that run, and
    ///     reporting it as having left checkers out would be false.
    /// - Returns: One record per key that is set to something other than its default, in a
    ///   stable order.
    public static func active(
        in configuration: Configuration,
        filesExcludedByPattern: Int? = nil,
        registeredCheckers: [String] = []
    ) -> [ActiveExclusion] {
        let defaults = Configuration()
        var active: [ActiveExclusion] = []

        if !configuration.excludePatterns.isEmpty {
            let count = configuration.excludePatterns.count
            let detail = filesExcludedByPattern.map {
                "\(count) pattern(s) matched \($0) .swift file(s); they were not audited"
            } ?? "\(count) pattern(s); matching .swift files are not audited"
            active.append(ActiveExclusion(
                form: "excludePatterns", entries: configuration.excludePatterns,
                matchedFiles: filesExcludedByPattern, detail: detail))
        }
        // `all` is the sentinel for every registered checker: it leaves nothing out.
        if !configuration.enabledCheckers.isEmpty, !registeredCheckers.isEmpty,
           !configuration.enabledCheckers.contains("all") {
            let enabled = Set(configuration.enabledCheckers)
            let left = registeredCheckers.filter { !enabled.contains($0) }.sorted()
            if !left.isEmpty {
                active.append(ActiveExclusion(
                    form: "enabledCheckers", entries: left,
                    detail: "lists \(registeredCheckers.count - left.count) of \(registeredCheckers.count) "
                        + "registered checkers; \(left.count) are not run"))
            }
        }
        if !configuration.excludedCheckers.isEmpty {
            active.append(ActiveExclusion(
                form: "excludedCheckers", entries: configuration.excludedCheckers,
                detail: "\(configuration.excludedCheckers.count) checker(s) are not run"))
        }

        let security = configuration.security
        let lists: [ListKey] = [
            ListKey(
                property: "vendorPaths", form: "vendorPaths",
                meaning: "findings under these paths are lowered to notes, and unreachable-code skips them",
                configured: configuration.vendorPaths, builtIn: defaults.vendorPaths),
            ListKey(
                property: "safetyExemptions", form: "safetyExemptions",
                meaning: "extra comment markers that silence safety, accessibility and test-quality findings",
                configured: configuration.safetyExemptions, builtIn: defaults.safetyExemptions),
            ListKey(
                property: "consistency.exemptions", form: "consistency.exemptions",
                meaning: "modules or paths the consistency audit does not score",
                configured: configuration.consistency.exemptions, builtIn: defaults.consistency.exemptions),
            ListKey(
                property: "concurrency.allowPreconcurrencyImports",
                form: "concurrency.allowPreconcurrencyImports",
                meaning: "`@preconcurrency import` of these modules is not reported",
                configured: configuration.concurrency.allowPreconcurrencyImports,
                builtIn: defaults.concurrency.allowPreconcurrencyImports),
            ListKey(
                property: "pointerEscape.allowedEscapeFunctions",
                form: "pointerEscape.allowedEscapeFunctions",
                meaning: "a borrowed pointer passed to these functions is not reported",
                configured: configuration.pointerEscape.allowedEscapeFunctions,
                builtIn: defaults.pointerEscape.allowedEscapeFunctions),
            ListKey(
                property: "security.enabledRules", form: "security.enabledRules",
                meaning: "an allow-list: a security rule that is not listed does not run",
                configured: security.enabledRules, builtIn: defaults.security.enabledRules),
            ListKey(
                property: "security.allowedHTTPHosts", form: "security.allowedHTTPHosts",
                meaning: "plain-http URLs to these hosts are not reported",
                configured: security.allowedHTTPHosts, builtIn: defaults.security.allowedHTTPHosts),
            ListKey(
                property: "security.atsAllowedInsecureDomains", form: "security.atsAllowedInsecureDomains",
                meaning: "ATS exceptions for these domains are not reported",
                configured: security.atsAllowedInsecureDomains,
                builtIn: defaults.security.atsAllowedInsecureDomains),
            ListKey(
                property: "security.containmentCheckers", form: "security.containmentCheckers",
                meaning: "a path passed through these functions is treated as contained",
                configured: security.containmentCheckers, builtIn: defaults.security.containmentCheckers),
            ListKey(
                property: "logging.allowedSilentTryFunctions", form: "logging.allowedSilentTryFunctions",
                meaning: "`try?` on these calls is not reported",
                configured: configuration.logging.allowedSilentTryFunctions,
                builtIn: defaults.logging.allowedSilentTryFunctions),
            ListKey(
                property: "dependencyAudit.allowBranchPins", form: "dependencyAudit.allowBranchPins",
                meaning: "branch pins on these packages are not reported",
                configured: configuration.dependencyAudit.allowBranchPins,
                builtIn: defaults.dependencyAudit.allowBranchPins),
            ListKey(
                property: "dependencyAudit.additionalKnownModules",
                form: "dependencyAudit.additionalKnownModules",
                meaning: "imports of these modules are treated as declared",
                configured: configuration.dependencyAudit.additionalKnownModules,
                builtIn: defaults.dependencyAudit.additionalKnownModules),
            ListKey(
                property: "submoduleAudit.allowedPackages", form: "submoduleAudit.allowedPackages",
                meaning: "these packages are not reported by the submodule audit",
                configured: configuration.submoduleAudit.allowedPackages,
                builtIn: defaults.submoduleAudit.allowedPackages),
            ListKey(
                property: "fpSafety.allowedFiles", form: "fpSafety.allowedFiles",
                meaning: "floating-point findings in these files are not reported",
                configured: configuration.fpSafety.allowedFiles, builtIn: defaults.fpSafety.allowedFiles),
            ListKey(
                property: "stochasticDeterminism.exemptFunctions",
                form: "stochasticDeterminism.exemptFunctions",
                meaning: "unseeded randomness inside these functions is not reported",
                configured: configuration.stochasticDeterminism.exemptFunctions,
                builtIn: defaults.stochasticDeterminism.exemptFunctions),
            ListKey(
                property: "stochasticDeterminism.exemptFiles", form: "stochasticDeterminism.exemptFiles",
                meaning: "unseeded randomness in these files is not reported",
                configured: configuration.stochasticDeterminism.exemptFiles,
                builtIn: defaults.stochasticDeterminism.exemptFiles),
            ListKey(
                property: "temporalDeterminism.exemptFunctions", form: "temporalDeterminism.exemptFunctions",
                meaning: "wall-clock use inside these functions is not reported",
                configured: configuration.temporalDeterminism.exemptFunctions,
                builtIn: defaults.temporalDeterminism.exemptFunctions),
            ListKey(
                property: "temporalDeterminism.exemptFiles", form: "temporalDeterminism.exemptFiles",
                meaning: "wall-clock use in these files is not reported",
                configured: configuration.temporalDeterminism.exemptFiles,
                builtIn: defaults.temporalDeterminism.exemptFiles),
            ListKey(
                property: "temporalDeterminism.exemptTypes", form: "temporalDeterminism.exemptTypes",
                meaning: "wall-clock use through these types is not reported",
                configured: configuration.temporalDeterminism.exemptTypes,
                builtIn: defaults.temporalDeterminism.exemptTypes),
            ListKey(
                property: "memoryLifecycle.exemptFiles", form: "memoryLifecycle.exemptFiles",
                meaning: "lifecycle findings in these files are not reported",
                configured: configuration.memoryLifecycle.exemptFiles,
                builtIn: defaults.memoryLifecycle.exemptFiles),
            ListKey(
                property: "memoryLifecycle.loopGrowthExemptPatterns",
                form: "memoryLifecycle.loopGrowthExemptPatterns",
                meaning: "loop growth matching these patterns is not reported",
                configured: configuration.memoryLifecycle.loopGrowthExemptPatterns,
                builtIn: defaults.memoryLifecycle.loopGrowthExemptPatterns),
            ListKey(
                property: "mcpReadiness.excludePaths", form: "mcpReadiness.excludePaths",
                meaning: "these paths are not audited for MCP readiness",
                configured: configuration.mcpReadiness.excludePaths,
                builtIn: defaults.mcpReadiness.excludePaths),
            ListKey(
                property: "appIntentsReadiness.excludePaths", form: "appIntentsReadiness.excludePaths",
                meaning: "these paths are not audited for App Intents readiness",
                configured: configuration.appIntentsReadiness.excludePaths,
                builtIn: defaults.appIntentsReadiness.excludePaths),
            ListKey(
                property: "legibility.exemptModules", form: "legibility.exemptModules",
                meaning: "these modules are not scored for legibility",
                configured: configuration.legibility.exemptModules.sorted(),
                builtIn: defaults.legibility.exemptModules.sorted()),
            ListKey(
                property: "legibility.exemptSymbols", form: "legibility.exemptSymbols",
                meaning: "these symbols are not scored for legibility",
                configured: configuration.legibility.exemptSymbols.sorted(),
                builtIn: defaults.legibility.exemptSymbols.sorted()),
            ListKey(
                property: "idiom.allowedShortIdentifiers", form: "idiom.allowedShortIdentifiers",
                meaning: "these short names are not reported by idiom.identifier-name",
                configured: configuration.idiom.allowedShortIdentifiers,
                builtIn: defaults.idiom.allowedShortIdentifiers),
            ListKey(
                property: "keychainSecrets.allowKeys", form: "keychain-secrets.allowKeys",
                meaning: "these keys are not reported by keychain-secrets",
                configured: configuration.keychainSecrets.allowKeys,
                builtIn: defaults.keychainSecrets.allowKeys),
        ]
        for key in lists {
            let builtIn = Set(key.builtIn)
            let added = key.configured.filter { !builtIn.contains($0) }
            guard !added.isEmpty else { continue }
            let noun = added.count == 1 ? "entry" : "entries"
            let count = key.builtIn.isEmpty ? "\(added.count) \(noun)" : "\(added.count) added \(noun)"
            active.append(ActiveExclusion(form: key.form, entries: added, detail: "\(count): \(key.meaning)"))
        }
        active += switches(in: configuration, defaults: defaults)
        return ordered(active)
    }

    /// The exclusions that are a setting rather than a list.
    private static func switches(in configuration: Configuration, defaults: Configuration) -> [ActiveExclusion] {
        var active: [ActiveExclusion] = []
        switch configuration.logging.projectType {
        case "cli":
            active.append(ActiveExclusion(
                form: "logging.projectType", entries: ["cli"],
                detail: "logging.print-statement and logging.no-os-logger-import are not checked"))
        case "library":
            active.append(ActiveExclusion(
                form: "logging.projectType", entries: ["library"],
                detail: "the logging checker examines nothing"))
        default:
            break
        }
        if !configuration.fpSafety.checkDivisionGuards, defaults.fpSafety.checkDivisionGuards {
            active.append(ActiveExclusion(
                form: "fpSafety.checkDivisionGuards", entries: ["false"],
                detail: "fp-division-unguarded is not checked"))
        }
        return active
    }

    /// The order exclusions are listed in: the order the schema's sections are documented.
    private static let formOrder: [String] = [
        "excludePatterns", "enabledCheckers", "excludedCheckers", "vendorPaths", "safetyExemptions",
        "consistency.exemptions", "concurrency.allowPreconcurrencyImports",
        "pointerEscape.allowedEscapeFunctions", "security.enabledRules", "security.allowedHTTPHosts",
        "security.atsAllowedInsecureDomains", "security.containmentCheckers", "logging.projectType",
        "logging.allowedSilentTryFunctions", "dependencyAudit.allowBranchPins",
        "dependencyAudit.additionalKnownModules", "submoduleAudit.allowedPackages",
        "fpSafety.allowedFiles", "fpSafety.checkDivisionGuards",
        "stochasticDeterminism.exemptFunctions", "stochasticDeterminism.exemptFiles",
        "temporalDeterminism.exemptFunctions", "temporalDeterminism.exemptFiles",
        "temporalDeterminism.exemptTypes",
        "memoryLifecycle.exemptFiles", "memoryLifecycle.loopGrowthExemptPatterns",
        "mcpReadiness.excludePaths", "appIntentsReadiness.excludePaths", "legibility.exemptModules",
        "legibility.exemptSymbols", "idiom.allowedShortIdentifiers", "keychain-secrets.allowKeys",
    ]

    private static func ordered(_ exclusions: [ActiveExclusion]) -> [ActiveExclusion] {
        let rank = Dictionary(uniqueKeysWithValues: formOrder.enumerated().map { ($1, $0) })
        return exclusions.sorted { (rank[$0.form] ?? formOrder.count) < (rank[$1.form] ?? formOrder.count) }
    }
}
