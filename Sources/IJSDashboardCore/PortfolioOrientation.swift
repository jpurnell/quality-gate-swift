import Foundation
import IJSSensor

/// Computes each package's product-composition orientation by joining every
/// project's emitted ``OrientationReport`` across the corpus.
///
/// Each package emits what it is **built from** (`packageDependsOn`); this inverts
/// those edges to also give **relied on by**, and infers a portfolio role
/// (foundation library vs. top-level product). Only first-party edges — those
/// pointing at another package that is itself in the corpus — are kept, so
/// external OSS dependencies (swift-syntax, Yams, …) never appear.
public enum PortfolioOrientation {

    /// A package-level orientation card per project, keyed by project ID.
    public static func cards(from reports: [String: OrientationReport]) -> [String: ModuleOrientationCard] {
        let projects = Set(reports.keys)

        var builtFrom: [String: [String]] = [:]
        var reliedOnBy: [String: Set<String>] = [:]
        for (id, report) in reports {
            let firstParty = report.packageDependsOn.filter { projects.contains($0) }.sorted()
            builtFrom[id] = firstParty
            for dependency in firstParty {
                reliedOnBy[dependency, default: []].insert(id)
            }
        }

        var cards: [String: ModuleOrientationCard] = [:]
        for (id, report) in reports {
            let deps = builtFrom[id] ?? []
            let dependents = (reliedOnBy[id] ?? []).sorted()
            let role = portfolioRole(builtFromCount: deps.count, reliedOnByCount: dependents.count)
            cards[id] = ModuleOrientationCard(
                moduleID: id,
                whatItDoes: report.packageSummary,
                why: portfolioWhy(role: role, reliedOnByCount: dependents.count),
                dependsOn: deps,
                reliedOnBy: dependents,
                role: role,
                source: .template,
                generatedAt: report.timestamp
            )
        }
        return cards
    }

    /// The portfolio role of a package from its build-graph position.
    static func portfolioRole(builtFromCount: Int, reliedOnByCount: Int) -> String {
        if reliedOnByCount == 0 && builtFromCount == 0 { return "standalone" }
        if reliedOnByCount == 0 { return "product" }                 // top-level — nothing builds on it
        if builtFromCount == 0 { return "foundation library" }       // builds on nothing; others build on it
        if reliedOnByCount >= builtFromCount { return "shared library" }
        return "intermediate library"
    }

    /// A deterministic structural explanation of a package's portfolio role.
    static func portfolioWhy(role: String, reliedOnByCount: Int) -> String? {
        switch role {
        case "foundation library":
            return "A foundational library — \(reliedOnByCount) package\(reliedOnByCount == 1 ? "" : "s") build on it."
        case "product":
            return "A top-level product — composed of other packages; nothing builds on it."
        case "shared library":
            return "A shared library — \(reliedOnByCount) package\(reliedOnByCount == 1 ? "" : "s") rely on it."
        case "intermediate library":
            return "An intermediate library in the build graph."
        case "standalone":
            return "A standalone package with no first-party dependencies either way."
        default:
            return nil
        }
    }
}
