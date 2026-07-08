import Foundation

/// Reads human-authored descriptions from a project's Master Plan markdown, so
/// "what a module/package does" can come from an authoritative source rather than
/// a generic template.
///
/// Two things are extracted:
/// - **Module descriptions** — the text after `— ` on a `- [x] Name — description`
///   checklist line (the "What's Working" list).
/// - **Mission** — the first paragraph under a `### Mission` heading, used as the
///   package-level "what it does".
enum MasterPlanReader {

    /// Module name → its checklist description.
    static func descriptions(markdown: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard let boxRange = line.range(of: #"^\s*-\s*\[[ xX]\]\s*"#, options: .regularExpression) else {
                continue
            }
            let rest = String(line[boxRange.upperBound...])
            // Descriptions are separated from the name by an em dash with spaces.
            guard let dashRange = rest.range(of: " — ") else { continue }
            let name = String(rest[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let description = String(rest[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !description.isEmpty {
                result[name] = description
            }
        }
        return result
    }

    /// The first paragraph under a `### Mission` heading, whitespace-collapsed.
    static func mission(markdown: String) -> String? {
        guard let heading = markdown.range(of: #"#{2,3}\s*Mission\s*\n"#, options: .regularExpression) else {
            return nil
        }
        let after = String(markdown[heading.upperBound...])
        for paragraph in after.components(separatedBy: "\n\n") {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.hasPrefix("#") { continue }
            return text.replacingOccurrences(of: "\n", with: " ")
        }
        return nil
    }
}
