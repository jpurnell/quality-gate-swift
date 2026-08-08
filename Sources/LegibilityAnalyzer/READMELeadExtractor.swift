import Foundation

/// Extracts a package's one-paragraph lead from its README.
///
/// The last tier of the "what it does" chain (Phase 1 §3): on repos without
/// our description conventions — no `// legibility:description:` comment, no
/// Master Plan Mission — the README's first meaningful paragraph keeps
/// orientation output from being prose-empty. Structure is always computed;
/// prose degrades gracefully instead of vanishing.
enum READMELeadExtractor {
    /// Longest lead we'll emit; longer paragraphs truncate at a word boundary.
    static let maxLength = 240

    /// The first meaningful paragraph, cleaned of inline markdown.
    ///
    /// Skips headings, badges, images, HTML, and horizontal rules; joins the
    /// wrapped lines of the first real paragraph; strips links/emphasis/code
    /// spans; truncates to ``maxLength`` at a word boundary with an ellipsis.
    ///
    /// - Parameter content: Raw README markdown.
    /// - Returns: The lead paragraph, or nil when the README holds no prose.
    static func lead(from content: String) -> String? {
        var paragraph: [String] = []
        for rawLine in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isNoise(line) {
                if paragraph.isEmpty { continue }
                break // the first prose paragraph has ended
            }
            paragraph.append(line)
        }
        guard !paragraph.isEmpty else { return nil }
        let cleaned = strippingInlineMarkdown(paragraph.joined(separator: " "))
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return truncated(cleaned)
    }

    /// Lines that are structure or decoration, never the lead.
    private static func isNoise(_ line: String) -> Bool {
        line.hasPrefix("#")        // headings
            || line.hasPrefix("[![") // linked badges
            || line.hasPrefix("![")  // images
            || line.hasPrefix("<")   // raw HTML, comments, <img>
            || line.hasPrefix("---") // rules / frontmatter fences
            || line.hasPrefix("===")
    }

    /// Strips links, emphasis, and code spans, keeping their display text.
    private static func strippingInlineMarkdown(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\*([^*]+)\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "`", with: "")
        return result
    }

    /// Cuts overlong text back to the last word boundary and appends `…`.
    private static func truncated(_ text: String) -> String {
        guard text.count > maxLength else { return text }
        let head = String(text.prefix(maxLength - 1))
        guard let lastSpace = head.lastIndex(of: " ") else { return head + "…" }
        return String(head[..<lastSpace]) + "…"
    }
}
