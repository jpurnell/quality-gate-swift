import Foundation
import Testing
@testable import QualityGateCore

/// Configured exclusions are listed when — and only when — a repository has set them.
@Suite("ConfigurationExclusions")
struct ConfigurationExclusionsTests {

    @Test("A default configuration has no exclusions in force")
    func defaultIsEmpty() {
        #expect(ConfigurationExclusions.active(in: Configuration()) == [])
    }

    @Test("excludePatterns reports its patterns and the files they matched")
    func excludePatternsWithCount() throws {
        let config = try Configuration.from(yaml: """
            excludePatterns:
              - "**/Fixtures/**"
              - "Generated/"
            """)
        let active = ConfigurationExclusions.active(in: config, filesExcludedByPattern: 14)

        #expect(active == [
            ActiveExclusion(
                form: "excludePatterns", entries: ["**/Fixtures/**", "Generated/"], matchedFiles: 14,
                detail: "2 pattern(s) matched 14 .swift file(s); they were not audited")
        ])
    }

    @Test("Without a walk the file count is absent, not zero")
    func excludePatternsWithoutCount() throws {
        let config = try Configuration.from(yaml: "excludePatterns: [\"Vendor/\"]")
        let active = ConfigurationExclusions.active(in: config)

        #expect(active.count == 1)
        #expect(active[0].matchedFiles == nil)
        #expect(active[0].detail == "1 pattern(s); matching .swift files are not audited")
    }

    @Test("A list with a non-empty default reports only what the repository added")
    func addedEntriesOnly() throws {
        let config = try Configuration.from(yaml: """
            logging:
              allowedSilentTryFunctions: ["Task.sleep", "JSONEncoder", "myOwnHelper"]
            """)
        let active = ConfigurationExclusions.active(in: config)

        #expect(active == [
            ActiveExclusion(
                form: "logging.allowedSilentTryFunctions", entries: ["myOwnHelper"],
                detail: "1 added entry: `try?` on these calls is not reported")
        ])
    }

    @Test("A project type that switches rules off is an exclusion")
    func projectType() throws {
        let cli = try Configuration.from(yaml: "logging:\n  projectType: cli")
        #expect(ConfigurationExclusions.active(in: cli) == [
            ActiveExclusion(
                form: "logging.projectType", entries: ["cli"],
                detail: "logging.print-statement and logging.no-os-logger-import are not checked")
        ])
        let library = try Configuration.from(yaml: "logging:\n  projectType: library")
        #expect(ConfigurationExclusions.active(in: library).first?.detail
            == "the logging checker examines nothing")
    }

    @Test("Checker selection names the registered checkers the configuration leaves out")
    func checkerSelection() throws {
        let config = try Configuration.from(yaml: """
            enabledCheckers: [safety, logging]
            excludedCheckers: [recursion]
            """)
        let active = ConfigurationExclusions.active(
            in: config, registeredCheckers: ["safety", "logging", "recursion", "concurrency"])

        #expect(active == [
            ActiveExclusion(
                form: "enabledCheckers", entries: ["concurrency", "recursion"],
                detail: "lists 2 of 4 registered checkers; 2 are not run"),
            ActiveExclusion(
                form: "excludedCheckers", entries: ["recursion"],
                detail: "1 checker(s) are not run"),
        ])
    }

    @Test("`enabledCheckers: [all]` leaves nothing out and is not an exclusion")
    func enabledAllIsNotAnExclusion() throws {
        // Tools/SwiftZIP: the sentinel selects every registered checker.
        let config = try Configuration.from(yaml: "enabledCheckers:\n  - all\n")
        let active = ConfigurationExclusions.active(
            in: config, registeredCheckers: ["safety", "logging", "recursion"])
        #expect(active == [])
    }

    @Test("Without the registry — a run whose selection came from the command line — enabledCheckers is not reported")
    func enabledCheckersNeedsTheRegistry() throws {
        let config = try Configuration.from(yaml: "enabledCheckers: [safety]\nexcludedCheckers: [recursion]")
        let active = ConfigurationExclusions.active(in: config)
        #expect(active.map(\.form) == ["excludedCheckers"])
    }

    @Test("Each per-checker allow key is reported under its own configuration path")
    func perCheckerKeys() throws {
        let config = try Configuration.from(yaml: """
            vendorPaths: [ThirdParty]
            safetyExemptions: ["// SAFETY:", "// OK:"]
            concurrency:
              allowPreconcurrencyImports: [Dispatch]
            pointerEscape:
              allowedEscapeFunctions: [memcpy]
            security:
              allowedHTTPHosts: [intranet.test]
              atsAllowedInsecureDomains: [example.test]
              containmentCheckers: [Paths.isInside]
              enabledRules: [security.ssrf]
            dependencyAudit:
              allowBranchPins: [swift-lmdb]
              additionalKnownModules: [Bridging]
            submoduleAudit:
              allowedPackages: [Vendored]
            fpSafety:
              allowedFiles: [Tolerance.swift]
              checkDivisionGuards: false
            stochasticDeterminism:
              exemptFunctions: [jitter]
              exemptFiles: [Noise.swift]
            temporalDeterminism:
              exemptFunctions: [stamp]
              exemptFiles: [Clock.swift]
              exemptTypes: [Stopwatch]
            memoryLifecycle:
              exemptFiles: [Legacy.swift]
              loopGrowthExemptPatterns: [buffer]
            mcpReadiness:
              excludePaths: [Sources/Old]
            appIntentsReadiness:
              excludePaths: [Sources/Old]
            legibility:
              exemptModules: [Generated]
              exemptSymbols: [Foo.bar]
            idiom:
              allowedShortIdentifiers: [i, j, k, x, y, z, id, to, at, in, dx, dy, n]
            keychain-secrets:
              allowKeys: [theme]
            consistency:
              exemptions: ["Generated/**"]
            """)
        let forms = ConfigurationExclusions.active(in: config).map(\.form)

        #expect(forms == [
            "vendorPaths",
            "safetyExemptions",
            "consistency.exemptions",
            "concurrency.allowPreconcurrencyImports",
            "pointerEscape.allowedEscapeFunctions",
            "security.enabledRules",
            "security.allowedHTTPHosts",
            "security.atsAllowedInsecureDomains",
            "security.containmentCheckers",
            "dependencyAudit.allowBranchPins",
            "dependencyAudit.additionalKnownModules",
            "submoduleAudit.allowedPackages",
            "fpSafety.allowedFiles",
            "fpSafety.checkDivisionGuards",
            "stochasticDeterminism.exemptFunctions",
            "stochasticDeterminism.exemptFiles",
            "temporalDeterminism.exemptFunctions",
            "temporalDeterminism.exemptFiles",
            "temporalDeterminism.exemptTypes",
            "memoryLifecycle.exemptFiles",
            "memoryLifecycle.loopGrowthExemptPatterns",
            "mcpReadiness.excludePaths",
            "appIntentsReadiness.excludePaths",
            "legibility.exemptModules",
            "legibility.exemptSymbols",
            "idiom.allowedShortIdentifiers",
            "keychain-secrets.allowKeys",
        ])
        let idiom = ConfigurationExclusions.active(in: config).first { $0.form == "idiom.allowedShortIdentifiers" }
        #expect(idiom?.entries == ["n"])
        let extra = ConfigurationExclusions.active(in: config).first { $0.form == "safetyExemptions" }
        #expect(extra?.entries == ["// OK:"])
    }

    // MARK: - The table does not drift from the schema

    /// Property names that read like an exclusion.
    private static let exclusionShaped = "allow|exempt|exclud|ignore|skip|optout|vendor|enabled|disabled"

    private func exclusionShapedPaths(_ value: Any, prefix: String) -> [String] {
        var paths: [String] = []
        for child in Mirror(reflecting: value).children {
            guard let label = child.label else { continue }
            let path = prefix.isEmpty ? label : "\(prefix).\(label)"
            let childMirror = Mirror(reflecting: child.value)
            if childMirror.displayStyle == .struct, !(child.value is any Collection) {
                paths += exclusionShapedPaths(child.value, prefix: path)
            }
            if label.range(of: Self.exclusionShaped, options: [.regularExpression, .caseInsensitive]) != nil {
                paths.append(path)
            }
        }
        return paths
    }

    @Test("Every exclusion-shaped configuration property is either reported or explicitly declined")
    func tableCoversTheSchema() {
        let found = Set(exclusionShapedPaths(Configuration(), prefix: ""))
        let accounted = ConfigurationExclusions.reportedProperties
            .union(ConfigurationExclusions.declinedProperties.keys)

        #expect(found.subtracting(accounted) == [])
        // And nothing in either list names a property that no longer exists.
        #expect(accounted.subtracting(found) == [])
        // A property cannot be both.
        #expect(ConfigurationExclusions.reportedProperties
            .intersection(ConfigurationExclusions.declinedProperties.keys) == [])
    }
}
