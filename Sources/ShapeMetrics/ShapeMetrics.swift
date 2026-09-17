import Foundation
import ComplexityAnalyzer
import QualityGateCore
import SwiftParser
import SwiftSyntax

// MARK: - What a rule contributes

/// One region a rule objected to, reduced to what the metric needs.
public struct FlaggedRegion: Sendable, Equatable {
    /// The rule that produced it.
    public let ruleId: String
    /// Absolute path of the file it lies in.
    public let filePath: String
    /// The inclusive line region, as the rule reported it.
    public let span: ClosedRange<Int>

    /// Creates a flagged region.
    public init(ruleId: String, filePath: String, span: ClosedRange<Int>) {
        self.ruleId = ruleId
        self.filePath = filePath
        self.span = span
    }

    /// Every flagged region a checker's diagnostics describe, and the rules that described none.
    ///
    /// A diagnostic reporting no span is not counted as one line. It is named, so the caller can
    /// say what it could not measure — examined nothing must not look like found nothing.
    ///
    /// - Parameter diagnostics: One checker's findings.
    /// - Returns: The regions, and the rule ids that reported no usable span.
    public static func extract(
        from diagnostics: [Diagnostic]
    ) -> (regions: [FlaggedRegion], rulesWithoutSpan: Set<String>) {
        var regions: [FlaggedRegion] = []
        var without: Set<String> = []
        for diagnostic in diagnostics {
            let ruleId = diagnostic.ruleId ?? "?"
            guard let path = diagnostic.filePath, let span = diagnostic.lineSpan else {
                without.insert(ruleId)
                continue
            }
            regions.append(FlaggedRegion(ruleId: ruleId, filePath: path, span: span))
        }
        return (regions, without)
    }
}

// MARK: - The denominator

/// Which lines of one file are source lines.
///
/// A line counts when it carries at least one token. Comments and documentation are trivia and
/// so are excluded by construction, as are blank lines — which is deliberate rather than
/// incidental: this codebase documents heavily, and counting comment lines in the denominator
/// would let a package improve its ratio by writing more prose.
public struct SLOCProfile: Sendable, Equatable {
    /// 1-based line numbers carrying at least one token.
    public let codeLines: Set<Int>

    /// Creates a profile from an explicit line set.
    public init(codeLines: Set<Int>) {
        self.codeLines = codeLines
    }

    /// Profiles one Swift source.
    ///
    /// - Parameter source: Swift source text.
    /// - Returns: The set of 1-based lines carrying a token.
    public static func profile(source: String) -> SLOCProfile {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        var lines: Set<Int> = []
        for token in tree.tokens(viewMode: .sourceAccurate) where token.tokenKind != .endOfFile {
            let start = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            let end = converter.location(for: token.endPositionBeforeTrailingTrivia).line
            guard end >= start else { continue }
            // A multi-line string literal is one token across many lines, and every one of them
            // is source.
            for line in start...end { lines.insert(line) }
        }
        return SLOCProfile(codeLines: lines)
    }
}

// MARK: - Configuration

/// Which rules contribute to the verbosity numerator.
public struct ShapeConfig: Sendable, Equatable {
    /// Rules whose findings are *size claims* rather than verbose lines.
    ///
    /// These are excluded from the headline numerator by default, and the decision is the one
    /// judgement in this metric worth arguing with, so it is configuration rather than a
    /// constant.
    ///
    /// The reasoning: verbosity is meant to count lines that could have been written shorter or
    /// not at all. `smell.type-length` does not say its 400 lines are *redundant* — it says
    /// there are a lot of them, which is a claim about size, and the lines themselves may each
    /// be necessary. Folding those spans in would make the ratio mostly a function of the
    /// long-declaration rules and would let one 400-line type flag a whole file.
    ///
    /// Every such rule is still measured and reported as its own component, so nothing is lost
    /// by excluding it — only the headline changes, and a reader who disagrees can see both.
    public var sizeRules: Set<String>

    /// The default exclusion set: every rule that reports "this is large" rather than "this is
    /// redundant".
    public static let defaultSizeRules: Set<String> = [
        "idiom.file-length",
        "idiom.function-body-length",
        "smell.type-length",
        "smell.closure-length",
        "smell.god-object",
        "smell.parameter-count",
        "smell.nesting-depth",
    ]

    /// Creates a configuration.
    public init(sizeRules: Set<String> = ShapeConfig.defaultSizeRules) {
        self.sizeRules = sizeRules
    }
}

// MARK: - The report

/// Verbosity and its components, each a fraction of SLOC.
public struct VerbosityReport: Sendable, Equatable {
    /// `|union of contributing regions ∩ SLOC| / SLOC` — the headline.
    public let verbosity: Double
    /// The idiom rules' share, size rules excluded.
    public let idiom: Double
    /// The smell rules' share, size rules excluded.
    public let smell: Double
    /// The clone share.
    public let clone: Double
    /// The share excluded from the headline as size claims, reported rather than discarded.
    public let sizeClaims: Double
    /// `(Σ components − union) / SLOC`: how much of the flagged set was flagged twice.
    ///
    /// The one term that cannot be reconstructed from the others, and the most diagnostic: high
    /// overlap means the clone blocks *are* the idiom violations — copy-pasted boilerplate —
    /// while near-zero overlap means two independent problems.
    public let overlap: Double
    /// Each contributing rule's own share, so a headline can be resolved to its causes.
    public let byRule: [String: Double]
    /// Total source lines considered.
    public let sloc: Int
}

/// Erosion and the decomposition that makes it interpretable.
public struct ErosionReport: Sendable, Equatable {
    /// `Σ(f: CC(f) > threshold) mass(f) / Σ(f) mass(f)` — the headline, mass-weighted.
    public let erosion: Double
    /// `|{f: CC(f) > threshold}| / |{f}|` — unweighted.
    ///
    /// The gap between this and ``erosion`` is what separates "a few enormous functions" from
    /// "many medium ones". The headline alone conflates them, and they call for different work.
    public let countShare: Double
    /// The share of total mass held by the heaviest tenth of functions.
    public let concentration: Double
    /// `Σ(f) mass(f)` — scale, not shape. Reported so two ratios are not compared across
    /// codebases of wildly different size without anyone noticing.
    public let totalMass: Double
    /// Functions measured.
    public let functionCount: Int
    /// Functions over the threshold.
    public let functionsOverThreshold: Int
    /// The cyclomatic threshold applied.
    public let threshold: Int
}

/// What the metrics could and could not see.
public struct ShapeCoverage: Sendable, Equatable {
    /// Contributing checkers that did not run.
    public let missingCheckers: [String]
    /// Rules that ran but reported no usable span, and so contributed nothing.
    public let rulesWithoutSpan: [String]
    /// Whether the headline verbosity is trustworthy — false when a contributor is missing.
    public var isComplete: Bool { missingCheckers.isEmpty }

    /// Creates a coverage note.
    public init(missingCheckers: [String], rulesWithoutSpan: [String]) {
        self.missingCheckers = missingCheckers.sorted()
        self.rulesWithoutSpan = rulesWithoutSpan.sorted()
    }

    /// A sentence naming what was and was not measured. Computed, never written: a checker's
    /// scope belongs in its own output, where it cannot go stale.
    public var summary: String {
        var parts: [String] = []
        if missingCheckers.isEmpty {
            parts.append("every contributing checker ran")
        } else {
            parts.append("verbosity withheld — \(missingCheckers.joined(separator: ", ")) did not run")
        }
        if !rulesWithoutSpan.isEmpty {
            parts.append("excluded for reporting no region: \(rulesWithoutSpan.joined(separator: ", "))")
        }
        return parts.joined(separator: "; ")
    }
}

/// Both ratios, their components, and what was measured to get them.
public struct ShapeReport: Sendable, Equatable {
    /// Verbosity, or `nil` when a contributing checker did not run.
    ///
    /// Withheld rather than computed over a partial union: a two-of-three union reported as if
    /// it were the ratio is the failure this exists to prevent.
    public let verbosity: VerbosityReport?
    /// Erosion, or `nil` when no function was measured. "No functions" is not "no erosion".
    public let erosion: ErosionReport?
    /// What was and was not visible.
    public let coverage: ShapeCoverage
}

// MARK: - The computation

/// Aggregates findings four checkers already produce into two codebase-shape ratios.
///
/// Not a checker: it needs the *union* of line sets from three checkers that cannot see each
/// other, which no single checker could obtain without redoing all three analyses. Advisory by
/// construction — it emits no diagnostic and fails nothing.
///
/// See `ARatioNeedsAPopulation.md` in the companion for why the ratios are shaped this way, and
/// for the baseline work that has to happen before either number means anything.
public enum ShapeMetrics {

    /// The checkers whose findings the verbosity union is built from.
    public static let contributingCheckers = ["idiom", "smells", "duplication"]

    /// Computes both ratios.
    ///
    /// - Parameters:
    ///   - regions: Flagged regions from every contributing checker that ran.
    ///   - sloc: Source-line profiles, keyed by absolute file path.
    ///   - functions: Per-function complexity records.
    ///   - missingCheckers: Contributing checkers that did not run.
    ///   - rulesWithoutSpan: Rules that ran but reported no region.
    ///   - threshold: The cyclomatic threshold above which a function erodes.
    ///   - config: Which rules count as size claims.
    /// - Returns: Both ratios with their components, and a coverage note.
    public static func compute(
        regions: [FlaggedRegion],
        sloc: [String: SLOCProfile],
        functions: [FunctionComplexityRecord],
        missingCheckers: [String] = [],
        rulesWithoutSpan: [String] = [],
        threshold: Int = 10,
        config: ShapeConfig = ShapeConfig()
    ) -> ShapeReport {
        let coverage = ShapeCoverage(
            missingCheckers: missingCheckers,
            rulesWithoutSpan: rulesWithoutSpan
        )
        return ShapeReport(
            verbosity: coverage.isComplete
                ? verbosity(regions: regions, sloc: sloc, config: config)
                : nil,
            erosion: erosion(functions: functions, threshold: threshold),
            coverage: coverage
        )
    }

    // MARK: Verbosity

    /// The verbosity ratio and its components, or `nil` when there is no source to divide by.
    static func verbosity(
        regions: [FlaggedRegion],
        sloc: [String: SLOCProfile],
        config: ShapeConfig
    ) -> VerbosityReport? {
        let total = sloc.values.reduce(0) { $0 + $1.codeLines.count }
        // An empty package has no verbosity, which is not the same as a verbosity of zero — and
        // the division would be by zero either way.
        guard total > 0 else { return nil }

        /// Flagged lines that are actually source lines, keyed by file.
        func codeLines(of region: FlaggedRegion) -> Set<Int> {
            guard let profile = sloc[region.filePath] else { return [] }
            // Intersecting with the source lines is what keeps a span covering blank or comment
            // lines from pushing the ratio above 1.
            return profile.codeLines.intersection(region.span)
        }

        var union: Set<FileLine> = []
        var perSource: [String: Set<FileLine>] = ["idiom": [], "smell": [], "clone": [], "size": []]
        var perRule: [String: Set<FileLine>] = [:]

        for region in regions {
            let lines = codeLines(of: region).map { FileLine(path: region.filePath, line: $0) }
            guard !lines.isEmpty else { continue }
            perRule[region.ruleId, default: []].formUnion(lines)

            let bucket = config.sizeRules.contains(region.ruleId) ? "size" : source(of: region.ruleId)
            perSource[bucket, default: []].formUnion(lines)
            if bucket != "size" {
                union.formUnion(lines)
            }
        }

        let contributing = ["idiom", "smell", "clone"].reduce(0) { $0 + (perSource[$1]?.count ?? 0) }

        /// A count as a fraction of the source lines.
        ///
        /// The guard is here, at the division, rather than only at the `total > 0` check above.
        /// A zero denominator is unreachable by that check, but a reader — and the fp-safety
        /// auditor — should not have to trace the control flow to know it.
        func share(_ count: Int) -> Double {
            let denominator = Double(total)
            guard denominator > .ulpOfOne else { return 0 }
            return Double(count) / denominator
        }

        return VerbosityReport(
            verbosity: share(union.count),
            idiom: share(perSource["idiom"]?.count ?? 0),
            smell: share(perSource["smell"]?.count ?? 0),
            clone: share(perSource["clone"]?.count ?? 0),
            sizeClaims: share(perSource["size"]?.count ?? 0),
            overlap: share(contributing - union.count),
            byRule: perRule.mapValues { share($0.count) },
            sloc: total
        )
    }

    /// Which checker a rule id belongs to, by its prefix.
    private static func source(of ruleId: String) -> String {
        if ruleId.hasPrefix("idiom.") { return "idiom" }
        if ruleId.hasPrefix("smell.") { return "smell" }
        if ruleId.hasPrefix("duplication.") { return "clone" }
        return "idiom"
    }

    // MARK: Erosion

    /// `mass(f) = CC(f)·√SLOC(f)` — the weight a function carries in the erosion ratio.
    ///
    /// The square root is what keeps a very long function from dominating on length alone: mass
    /// grows with size, but sub-linearly, so complexity stays the leading term.
    static func mass(of record: FunctionComplexityRecord) -> Double {
        let lines = max(1, record.endLine - record.startLine + 1)
        return Double(record.cyclomaticComplexity) * Double(lines).squareRoot()
    }

    /// The erosion ratio and its decomposition, or `nil` when nothing was measured.
    static func erosion(functions: [FunctionComplexityRecord], threshold: Int) -> ErosionReport? {
        // No functions is not zero erosion: there is nothing to be eroded, and the ratio has no
        // denominator. Reporting 0.0 would put an empty package at the healthy end of a scale it
        // is not on.
        guard !functions.isEmpty else { return nil }

        let masses = functions.map(mass)
        let totalMass = masses.reduce(0, +)
        guard totalMass > .ulpOfOne else { return nil }

        let over = zip(functions, masses).filter { $0.0.cyclomaticComplexity > threshold }
        let overMass = over.reduce(0.0) { $0 + $1.1 }

        let sorted = masses.sorted(by: >)
        let topDecileCount = max(1, sorted.count / 10)
        let topDecileMass = sorted.prefix(topDecileCount).reduce(0, +)

        /// A mass as a fraction of the total. Guarded at the division, though `totalMass` was
        /// already checked above — the reader should not have to trace back to know it.
        func massShare(_ part: Double) -> Double {
            guard totalMass > .ulpOfOne else { return 0 }
            return part / totalMass
        }

        let functionCount = Double(functions.count)
        guard functionCount > .ulpOfOne else { return nil }

        return ErosionReport(
            erosion: massShare(overMass),
            countShare: Double(over.count) / functionCount,
            concentration: massShare(topDecileMass),
            totalMass: totalMass,
            functionCount: functions.count,
            functionsOverThreshold: over.count,
            threshold: threshold
        )
    }
}

/// One line of one file — the unit the verbosity union is taken over.
///
/// Line numbers alone would collide across files, merging line 12 of every file into one
/// element and undercounting the union.
struct FileLine: Hashable, Sendable {
    let path: String
    let line: Int
}
