import Foundation
import QualityGateCore

/// Validates the rule→control mapping against reality, so the map can never
/// silently drift from the rules it claims or the catalogs it cites.
///
/// Same shape as the dependency-audit / hallucinated-import guarantee: every
/// mapped rule must exist, every referenced control must resolve, and every
/// catalog must be fresh. Structural drift is an error; staleness ages from a
/// warning. This validator asserts *integrity of the mapping* — it never
/// asserts "compliant."
public struct ControlMappingValidator: QualityChecker, Sendable {

    /// The checker identifier.
    public let id = "control-mapping"
    /// The human-readable name.
    public let name = "Control Mapping Validator"

    /// One sentence: what this checker finds. The README's description column.
    public let summary = "Integrity of the SOC 2 / ISO 27001 / HIPAA technical-control mapping — phantom-rule / phantom-control / superseded-catalog errors, catalog-staleness warning"

    /// The README section this checker is documented under.
    public let category = CheckerCategory.specialty

    /// What this checker's findings are about — see `CheckerKind`.
    public let kind = CheckerKind.code

    /// What this checker leaves behind — see `CheckerEffect`.
    public let effect = CheckerEffect.readOnly

    /// Analyses source without running it — safe to point at a stranger's package.
    public let executesProjectCode = false
    /// Days a catalog may go un-reviewed before staleness warns.
    let freshnessHorizonDays: Int

    /// Creates the validator.
    ///
    /// - Parameter freshnessHorizonDays: days a catalog may go un-reviewed
    ///   before staleness warns (default 180).
    public init(freshnessHorizonDays: Int = 180) {
        self.freshnessHorizonDays = freshnessHorizonDays
    }

    /// Loads the bundled mapping, catalogs, and rule registry and validates
    /// their integrity. Skips when no mapping is configured.
    public func check(configuration: Configuration) async throws -> CheckResult {
        let startTime = ContinuousClock.now

        let mappings = ControlMappingResources.mappings()
        guard !mappings.isEmpty else {
            return CheckResult(
                checkerId: id, status: .skipped, diagnostics: [],
                duration: ContinuousClock.now - startTime)
        }

        let diagnostics = Self.validate(
            mappings: mappings,
            catalogs: ControlMappingResources.catalogs(),
            knownRuleIds: ControlMappingResources.registryRuleIds(),
            freshnessHorizonDays: freshnessHorizonDays,
            today: Self.todayISO())

        let status: CheckResult.Status
        if diagnostics.contains(where: { $0.severity == .error }) {
            status = .failed
        } else if diagnostics.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .passed
        }
        return CheckResult(
            checkerId: id, status: status, diagnostics: diagnostics,
            duration: ContinuousClock.now - startTime)
    }

    /// Today's date as an ISO `YYYY-MM-DD` string in UTC — the reference point
    /// for the catalog freshness check.
    static func todayISO() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.string(from: Date())
    }

    // MARK: - Engine (pure over its inputs; internal for tests)

    /// Every integrity finding for a mapping set against its catalogs.
    ///
    /// - A mapping to a rule not in `knownRuleIds` is an error (phantom rule).
    /// - A control ref that no catalog resolves is an error (phantom control).
    /// - A `superseded` catalog is an error (upstream drift, awaiting reconcile).
    /// - A catalog reviewed longer than the horizon ago is a warning.
    ///
    /// - Parameters:
    ///   - mappings: the rule→control mappings under audit.
    ///   - catalogs: the framework catalogs the mappings reference.
    ///   - knownRuleIds: rule/checker ids that actually exist in the gate.
    ///   - freshnessHorizonDays: staleness threshold in days.
    ///   - today: ISO `YYYY-MM-DD` reference date (injected for determinism).
    static func validate(
        mappings: [RuleControlMapping],
        catalogs: [ControlCatalog],
        knownRuleIds: Set<String>,
        freshnessHorizonDays: Int,
        today: String
    ) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        var catalogByFramework: [String: ControlCatalog] = [:]
        for catalog in catalogs { catalogByFramework[catalog.framework] = catalog }

        for mapping in mappings {
            if !knownRuleIds.contains(mapping.ruleId) {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "control mapping references unknown rule '\(mapping.ruleId)' — no such checker/rule emits it",
                    ruleId: "control-mapping.unknown-rule"))
            }
            for ref in mapping.satisfies where catalogByFramework[ref.framework]?.control(id: ref.controlId) == nil {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "control mapping references unknown control '\(ref.stringValue)' — no catalog defines it",
                    ruleId: "control-mapping.unknown-control"))
            }
        }

        for catalog in catalogs {
            if catalog.superseded {
                diagnostics.append(Diagnostic(
                    severity: .error,
                    message: "catalog '\(catalog.framework)' was superseded by detected upstream drift — reconcile the mapping before trusting it",
                    ruleId: "control-mapping.superseded"))
                continue
            }
            if let days = daysBetween(catalog.reviewed, today), days > freshnessHorizonDays {
                diagnostics.append(Diagnostic(
                    severity: .warning,
                    message: "catalog '\(catalog.framework)' last reviewed \(catalog.reviewed) (\(days) days ago, horizon \(freshnessHorizonDays)) — re-verify against the upstream standard",
                    ruleId: "control-mapping.stale"))
            }
        }

        return diagnostics
    }

    /// Whole days from `earlier` to `later` (both ISO `YYYY-MM-DD`), or nil if
    /// either fails to parse. Pure over its inputs — no wall-clock read.
    static func daysBetween(_ earlier: String, _ later: String) -> Int? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        guard let start = formatter.date(from: earlier),
              let end = formatter.date(from: later) else { return nil }
        let seconds = Int(end.timeIntervalSince1970 - start.timeIntervalSince1970)
        return seconds / 86_400
    }
}
