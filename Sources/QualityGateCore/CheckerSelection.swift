import Foundation

/// Resolves which checkers should run for a given invocation.
///
/// Extracted from the CLI so the selection rules are unit-testable and consistent
/// across entry points.
///
/// ## Maintenance checkers
///
/// Some checkers perform *destructive maintenance* — deleting build artifacts, running
/// `git gc` — rather than read-only quality analysis. These are **opt-in**: they are
/// excluded from `--check all` and from the default (no-argument) set, and run only when
/// named explicitly (e.g. `--check disk-clean`, or `--check all --check disk-clean`).
///
/// This keeps "run all checks" non-destructive and reproducible: it will not wipe the
/// `.build/` directory (and index store) that other checkers depend on, so consecutive
/// runs produce the same results.
public enum CheckerSelection {
    /// Checker ids that perform destructive maintenance rather than read-only analysis.
    public static let maintenanceCheckers: Set<String> = ["disk-clean"]

    /// Resolve the ordered list of checker ids to run.
    ///
    /// - Parameters:
    ///   - requested: Values from `--check`. May contain the sentinel `"all"` and/or
    ///     explicit checker ids.
    ///   - excluded: Values from `--exclude`.
    ///   - configuredEnabled: `Configuration.enabledCheckers` (from `.quality-gate.yml`).
    ///   - full: The `--full` flag; opts `xcode-build` back into the default set.
    ///   - allIDs: All registered checker ids, in registry (output) order.
    /// - Returns: The checker ids to run, preserving `allIDs` order where applicable.
    public static func resolve(
        requested: [String],
        excluded: [String],
        configuredEnabled: [String],
        full: Bool,
        allIDs: [String]
    ) -> [String] {
        let excludeSet = Set(excluded)

        if requested.contains("all") {
            let requestedSet = Set(requested)
            return allIDs.filter { id in
                if excludeSet.contains(id) { return false }
                // Maintenance checkers are opt-in even under "all": include only when the
                // caller also named them explicitly (e.g. --check all --check disk-clean).
                if maintenanceCheckers.contains(id) && !requestedSet.contains(id) { return false }
                return true
            }
        } else if !requested.isEmpty {
            // Explicit ids run as requested (maintenance checkers included on demand).
            return requested
        } else if !configuredEnabled.isEmpty {
            return configuredEnabled
        } else {
            // Default (no --check, no config): everything except opt-in checkers.
            var optOut: Set<String> = maintenanceCheckers.union(["xcode-build"])
            if full { optOut.remove("xcode-build") }
            return allIDs.filter { !optOut.contains($0) }
        }
    }
}
