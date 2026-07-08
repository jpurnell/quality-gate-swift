import Foundation

/// A per-module summary card: the "what relies on it / how exposed / what role"
/// view a reader or a dashboard consumes.
struct ModuleCard: Sendable, Codable, Equatable {
    /// The module's name.
    let moduleName: String
    /// Number of modules that rely on this one (unweighted fan-in).
    let fanIn: Int
    /// Reference-weighted fan-in.
    let weightedFanIn: Int
    /// Number of internal modules this one depends on.
    let fanOut: Int
    /// Whether the module has a conceptual overview (DocC landing page).
    let hasOrientationDoc: Bool
    /// Count of live-but-over-exposed public symbols in this module.
    let overPublicCount: Int
    /// A one-word role inferred from the module's position in the graph.
    let role: String

    /// Creates a module card.
    init(
        moduleName: String,
        fanIn: Int,
        weightedFanIn: Int,
        fanOut: Int,
        hasOrientationDoc: Bool,
        overPublicCount: Int,
        role: String
    ) {
        self.moduleName = moduleName
        self.fanIn = fanIn
        self.weightedFanIn = weightedFanIn
        self.fanOut = fanOut
        self.hasOrientationDoc = hasOrientationDoc
        self.overPublicCount = overPublicCount
        self.role = role
    }
}

/// The full legibility map artifact: a generated reading order, per-module cards,
/// and the structural findings. Designed to be the substrate for an `ONBOARDING`
/// document and the dashboard's module-orientation section — a derived artifact,
/// not diagnostics.
struct LegibilityMap: Sendable, Codable, Equatable {
    /// Fan-in-weighted reading order: study these modules in this order.
    let readingOrder: [String]
    /// Per-module cards, ordered to match ``readingOrder``.
    let cards: [ModuleCard]
    /// Dependency cycles (each a set of mutually-entangled modules).
    let cycles: [[String]]

    /// Creates a legibility map.
    init(readingOrder: [String], cards: [ModuleCard], cycles: [[String]]) {
        self.readingOrder = readingOrder
        self.cards = cards
        self.cycles = cycles
    }
}

/// Builds a ``LegibilityMap`` from the module graph and per-module facts.
enum LegibilityMapBuilder {

    /// Assembles the map. Cards are ordered by the reading order so the artifact
    /// reads top-to-bottom as an onboarding path.
    ///
    /// - Parameters:
    ///   - graph: The (semantic or declared) module graph.
    ///   - orientation: Per-module orientation-doc presence.
    ///   - overPublicByModule: Count of over-public symbols per module.
    static func build(
        graph: ModuleGraph,
        orientation: [ModuleOrientation],
        overPublicByModule: [String: Int]
    ) -> LegibilityMap {
        let orientationByModule = Dictionary(
            orientation.map { ($0.moduleName, $0.hasOrientationDoc) },
            uniquingKeysWith: { first, _ in first }
        )
        let readingOrder = graph.topologicalReadingOrder()

        let cards = readingOrder.map { module in
            let fanIn = graph.fanIn(module)
            let fanOut = graph.fanOut(module)
            return ModuleCard(
                moduleName: module,
                fanIn: fanIn,
                weightedFanIn: graph.weightedFanIn(module),
                fanOut: fanOut,
                hasOrientationDoc: orientationByModule[module] ?? false,
                overPublicCount: overPublicByModule[module] ?? 0,
                role: inferRole(fanIn: fanIn, fanOut: fanOut)
            )
        }

        return LegibilityMap(readingOrder: readingOrder, cards: cards, cycles: graph.cycles())
    }

    /// Infers a one-word structural role from fan-in and fan-out.
    static func inferRole(fanIn: Int, fanOut: Int) -> String {
        if fanIn == 0 && fanOut == 0 { return "isolated" }
        if fanOut == 0 { return "foundation" }         // depends on nothing internal
        if fanIn == 0 { return "entry-point" }         // nothing depends on it
        if fanIn >= fanOut * 2 { return "foundation" } // depended-on far more than it depends
        if fanOut >= fanIn * 2 { return "orchestrator" }
        return "intermediate"
    }
}

/// Renders a ``LegibilityMap`` to JSON or Markdown for downstream consumers.
enum LegibilityMapRenderer {

    /// Deterministic pretty JSON (sorted keys) suitable for a corpus artifact.
    static func json(_ map: LegibilityMap) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(map)
        return String(decoding: data, as: UTF8.self)
    }

    /// A human-readable Markdown rendering: reading order, module-card table, and
    /// a cycles section. This is the shape a generated `ONBOARDING.md` builds on.
    static func markdown(_ map: LegibilityMap) -> String {
        var lines: [String] = []
        lines.append("# Codebase Reading Order")
        lines.append("")
        lines.append("Study these modules in order — the most foundational first:")
        lines.append("")
        for (index, module) in map.readingOrder.enumerated() {
            lines.append("\(index + 1). \(module)")
        }
        lines.append("")
        lines.append("## Module Cards")
        lines.append("")
        lines.append("| Module | Role | Relied on by | Depends on | Oriented | Over-public |")
        lines.append("| --- | --- | ---: | ---: | :---: | ---: |")
        for card in map.cards {
            let oriented = card.hasOrientationDoc ? "✓" : "—"
            lines.append("| \(card.moduleName) | \(card.role) | \(card.fanIn) | \(card.fanOut) | \(oriented) | \(card.overPublicCount) |")
        }

        if !map.cycles.isEmpty {
            lines.append("")
            lines.append("## Dependency Cycles")
            lines.append("")
            lines.append("These modules cannot be read in isolation — break them for a clean order:")
            lines.append("")
            for cycle in map.cycles {
                lines.append("- \(cycle.sorted().joined(separator: " → "))")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }
}
