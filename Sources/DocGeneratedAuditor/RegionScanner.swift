import Foundation
import QualityGateCore

/// A delimited block of derived content inside a markdown document.
///
/// The convention is `<!-- generated:<id> -->` … `<!-- /generated:<id> -->`, each on its own
/// line. Everything strictly between the two lines belongs to the generator named by `id`;
/// everything outside belongs to the author.
///
/// The form is chosen over the line-suffix marker `MemoryBuilder` already emits because a
/// suffix cannot express deletion: a generated line that loses its marker becomes
/// indistinguishable from a hand-written one and therefore immortal. A region deletes by
/// being shorter.
public struct GeneratedRegion: Sendable, Equatable {

    /// The generator id named by both delimiters.
    public let id: String

    /// 1-based line number of the opening delimiter, in the governed file.
    public let openingLine: Int

    /// 1-based line number of the closing delimiter, in the governed file.
    public let closingLine: Int

    /// The bytes strictly between the delimiters, delimiters excluded.
    ///
    /// An empty region (delimiters on consecutive lines) yields `""`.
    public let body: String

    /// Creates a region.
    public init(id: String, openingLine: Int, closingLine: Int, body: String) {
        self.id = id
        self.openingLine = openingLine
        self.closingLine = closingLine
        self.body = body
    }
}

/// A malformed region: a delimiter the scanner could not pair, or a pairing that cannot mean
/// anything.
///
/// Every case is an error rather than a skip. Silence about a delimiter the tool did not
/// understand is indistinguishable from a region that passed.
public struct RegionDefect: Sendable, Equatable {

    /// What went wrong.
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// An opening delimiter with no matching close before end of file.
        case unterminated
        /// A closing delimiter with no opening delimiter before it.
        case unopened
        /// Two regions with the same id in one file, so "the" region is ambiguous.
        case duplicateID
        /// An opening delimiter encountered while another region is still open.
        case overlapping
        /// A closing delimiter whose id is not the id of the open region.
        case mismatchedClose
    }

    /// The defect's kind.
    public let kind: Kind

    /// The id named by the delimiter that produced the defect.
    public let id: String

    /// 1-based line of the delimiter that produced the defect.
    public let line: Int

    /// 1-based line of the related delimiter, when the defect is about a pair.
    public let relatedLine: Int?

    /// Creates a defect.
    public init(kind: Kind, id: String, line: Int, relatedLine: Int? = nil) {
        self.kind = kind
        self.id = id
        self.line = line
        self.relatedLine = relatedLine
    }

    /// The rule id reported to the gate, namespaced under the checker.
    public var ruleId: String {
        switch kind {
        case .unterminated: return "doc-generated.region-unterminated"
        case .unopened: return "doc-generated.region-unopened"
        case .duplicateID: return "doc-generated.region-duplicate-id"
        case .overlapping: return "doc-generated.region-overlapping"
        case .mismatchedClose: return "doc-generated.region-mismatched-close"
        }
    }

    /// A one-line description naming both ends of the problem where there are two.
    public var message: String {
        switch kind {
        case .unterminated:
            return "Region `\(id)` opens here and is never closed — add `<!-- /generated:\(id) -->`."
        case .unopened:
            return "Closing delimiter for region `\(id)` has no opening `<!-- generated:\(id) -->`."
        case .duplicateID:
            let first = relatedLine.map { " (first opened at line \($0))" } ?? ""
            return "Region `\(id)` appears twice in this file\(first) — a generator has one region per file."
        case .overlapping:
            let outer = relatedLine.map { " opened at line \($0)" } ?? ""
            return "Region `\(id)` opens inside a region\(outer) that is still open — regions do not nest."
        case .mismatchedClose:
            let outer = relatedLine.map { " (opened at line \($0))" } ?? ""
            return "Closing delimiter `\(id)` does not match the open region\(outer)."
        }
    }
}

/// Everything one pass over a document found: its regions, and the delimiters it could not
/// make sense of.
public struct RegionScan: Sendable, Equatable {

    /// Well-formed regions, in document order.
    public let regions: [GeneratedRegion]

    /// Malformed delimiters, in document order.
    public let defects: [RegionDefect]

    /// Creates a scan result.
    public init(regions: [GeneratedRegion], defects: [RegionDefect]) {
        self.regions = regions
        self.defects = defects
    }
}

/// Finds `<!-- generated:<id> -->` regions in markdown.
///
/// ## Fenced code is not markup
///
/// A delimiter inside a fenced code block is *documentation about the convention*, not an
/// instance of it — this proposal and three others in the tree show the delimiters in
/// fences, and a scanner that honoured them would open regions inside prose describing
/// regions. The fence state is tracked across the whole file, including inside a region
/// body, which is also what stops a region containing an example fence from closing early.
///
/// ## Delimiters own their line
///
/// A delimiter must be the entire line, modulo leading and trailing whitespace. That is what
/// keeps an inline code span such as `` `<!-- generated:x -->` `` in a bulleted list from
/// being read as a region, and it is the rule that lets this checker's own design document
/// sit in the tree without being flagged.
public enum RegionScanner {

    private static let openingPattern = #"^\s*<!--\s*generated:([A-Za-z0-9][A-Za-z0-9._-]*)\s*-->\s*$"#
    private static let closingPattern = #"^\s*<!--\s*/generated:([A-Za-z0-9][A-Za-z0-9._-]*)\s*-->\s*$"#

    /// Scans a document for regions and malformed delimiters.
    ///
    /// - Parameter content: The document's full text.
    /// - Returns: The regions found, in document order, and every defect encountered.
    public static func scan(_ content: String) -> RegionScan {
        let lines = content.lines
        var regions: [GeneratedRegion] = []
        var defects: [RegionDefect] = []
        var seenIDs: [String: Int] = [:]

        var fence: FenceState?
        var open: (id: String, line: Int, bodyStart: Int)?

        for (index, line) in lines.enumerated() {
            let number = index + 1

            if let current = fence {
                if current.closes(line) { fence = nil }
                continue
            }
            if let started = FenceState(opening: line) {
                fence = started
                continue
            }

            if let id = match(openingPattern, in: line) {
                if let outer = open {
                    defects.append(RegionDefect(
                        kind: .overlapping, id: id, line: number, relatedLine: outer.line))
                    continue
                }
                if let first = seenIDs[id] {
                    defects.append(RegionDefect(
                        kind: .duplicateID, id: id, line: number, relatedLine: first))
                    continue
                }
                seenIDs[id] = number
                open = (id: id, line: number, bodyStart: index + 1)
                continue
            }

            if let id = match(closingPattern, in: line) {
                guard let current = open else {
                    defects.append(RegionDefect(kind: .unopened, id: id, line: number))
                    continue
                }
                guard current.id == id else {
                    defects.append(RegionDefect(
                        kind: .mismatchedClose, id: id, line: number, relatedLine: current.line))
                    continue
                }
                let body = current.bodyStart < index
                    ? lines[current.bodyStart..<index].joined(separator: "\n")
                    : ""
                regions.append(GeneratedRegion(
                    id: id, openingLine: current.line, closingLine: number, body: body))
                open = nil
            }
        }

        if let dangling = open {
            defects.append(RegionDefect(
                kind: .unterminated, id: dangling.id, line: dangling.line))
        }

        return RegionScan(regions: regions, defects: defects.sorted { $0.line < $1.line })
    }

    private static func match(_ pattern: String, in line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { // silent: both patterns are compile-time constants, so a throw here is unreachable and a nil result is the correct degradation
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let hit = regex.firstMatch(in: line, range: range),
              hit.numberOfRanges > 1,
              let idRange = Range(hit.range(at: 1), in: line) else {
            return nil
        }
        return String(line[idRange])
    }

    /// An open fenced code block: which character opened it and how long the run was.
    ///
    /// CommonMark closes a fence with a run of the same character at least as long as the
    /// opener, which is what lets a four-backtick fence contain a three-backtick one.
    private struct FenceState {
        let marker: Character
        let length: Int

        init?(opening line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
            let run = trimmed.prefix { $0 == first }.count
            guard run >= 3 else { return nil }
            marker = first
            length = run
        }

        func closes(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == marker else { return false }
            let run = trimmed.prefix { $0 == marker }.count
            guard run >= length else { return false }
            return trimmed.dropFirst(run).allSatisfy { $0 == " " }
        }
    }
}
