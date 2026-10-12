import Foundation

/// Finds what a marker silenced by asking what the analysis reports without it.
///
/// Some checkers consult their marker *before* they know whether there is a finding: a
/// property carrying `lifecycle:exempt` is skipped while members are still being collected,
/// and the rule that might have fired is decided a hundred lines later from what was
/// collected. Recording at the point of the skip would count every marker, including the
/// ones that silence nothing — and a count that cannot tell a decorative marker from a
/// working one is the count this reporting exists to replace.
///
/// So the question is put directly. The file is analysed twice, once as written and once
/// with the marker's text blanked, and a finding present only in the second run is a finding
/// the marker silenced. The second run happens only for a file that contains the marker.
public enum MarkerShadow {

    /// `source` with every occurrence of each marker overwritten by text of the same length.
    ///
    /// Same length, so no line or column moves and a finding from the shadow run can be
    /// reported at the location it has in the real file.
    ///
    /// - Parameters:
    ///   - source: The file's text.
    ///   - markers: The marker spellings to blank.
    /// - Returns: The text with the markers neutralised, or `nil` when it contains none.
    public static func neutralised(_ source: String, markers: [String]) -> String? {
        guard markers.contains(where: { !$0.isEmpty && source.contains($0) }) else { return nil }
        var shadow = source
        for marker in markers where !marker.isEmpty {
            shadow = shadow.replacingOccurrences(
                of: marker, with: String(repeating: "_", count: marker.count))
        }
        return shadow
    }

    /// The records for findings the shadow run raised and the real run did not.
    ///
    /// - Parameters:
    ///   - real: Findings from the file as written.
    ///   - shadow: Findings from the file with its markers neutralised.
    ///   - form: The marker, as documented.
    ///   - sourceLines: The real file's lines, to locate the marker and read its reason.
    ///   - filePath: The file.
    ///   - reach: How many lines above a finding the marker may sit.
    ///   - reportOnly: See ``SuppressionRecord/forwardedToCorpus``.
    /// - Returns: One record per silenced finding, in the shadow run's order.
    public static func silenced(
        real: [Diagnostic],
        shadow: [Diagnostic],
        form: String,
        sourceLines: [String],
        filePath: String,
        reach: Int = 1,
        reportOnly: Bool = true
    ) -> [DiagnosticOverride] {
        var remaining: [Key: Int] = [:]
        for diagnostic in real { remaining[Key(diagnostic), default: 0] += 1 }

        var records: [DiagnosticOverride] = []
        for diagnostic in shadow {
            let key = Key(diagnostic)
            if let count = remaining[key], count > 0 {
                remaining[key] = count - 1
                continue
            }
            guard let ruleId = diagnostic.ruleId, let line = diagnostic.lineNumber else { continue }
            let marker = nearestMarker(form, atOrAbove: line, reach: reach, in: sourceLines)
            records.append(.inlineMarker(
                form: form, ruleId: ruleId, filePath: filePath, findingLine: line,
                markerLine: marker?.line, comment: marker?.text ?? form, reportOnly: reportOnly))
        }
        return records
    }

    /// The marker on `line` or within `reach` lines above it, nearest first.
    static func nearestMarker(
        _ form: String, atOrAbove line: Int, reach: Int, in lines: [String]
    ) -> InlineMarker.Location? {
        for offset in 0...max(0, reach) {
            let candidate = line - offset
            guard candidate >= 1, candidate <= lines.count else { continue }
            let text = lines[candidate - 1]
            if text.contains(form) { return InlineMarker.Location(line: candidate, text: text) }
        }
        return nil
    }

    private struct Key: Hashable {
        let ruleId: String?
        let line: Int?
        let column: Int?
        let message: String

        init(_ diagnostic: Diagnostic) {
            ruleId = diagnostic.ruleId
            line = diagnostic.lineNumber
            column = diagnostic.columnNumber
            message = diagnostic.message
        }
    }
}
