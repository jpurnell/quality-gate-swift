import Foundation
import SwiftCLIKit

/// Copy-friendly terminal chrome for the dashboard TUI views.
///
/// Sections are set apart with full-width horizontal rules rather than a
/// four-sided box. Dropping the left and right vertical edges (`│`, U+2502)
/// means that selecting and copying multi-line content — the weekly narrative
/// especially — no longer picks up border characters that would otherwise have
/// to be stripped by hand before sharing.
///
/// Visual ordering is preserved through:
/// - a titled rule at the top of each view (`── Title ──────────`),
/// - plain full-width rules between sections (`──────────`),
/// - the existing two-space indentation and column alignment of content rows.
enum DashboardChrome {
    /// U+2500 BOX DRAWINGS LIGHT HORIZONTAL.
    static let horizontal = "\u{2500}"

    /// A full-width horizontal rule used to separate sections.
    ///
    /// - Parameter width: Total width in columns.
    /// - Returns: A rule exactly `width` columns wide, or an empty string for
    ///   non-positive widths.
    static func sectionRule(width: Int) -> String {
        guard width > 0 else { return "" }
        return String(repeating: horizontal, count: width)
    }

    /// A horizontal rule with a leading title, e.g. `── Title ──────────`.
    ///
    /// The title is trimmed of surrounding whitespace and truncated if it would
    /// not fit. The result is always exactly `width` columns wide so it aligns
    /// with `sectionRule(width:)`.
    ///
    /// - Parameters:
    ///   - title: The section title to embed.
    ///   - width: Total width in columns.
    /// - Returns: A titled rule, or an empty string for non-positive widths.
    static func titleRule(_ title: String, width: Int) -> String {
        guard width > 0 else { return "" }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let lead = width >= 3 ? horizontal + horizontal + " " : ""
        let leadLen = ANSIStringMetrics.visibleLength(lead)
        var titleSegment = trimmed.isEmpty ? "" : trimmed + " "
        let maxTitle = max(0, width - leadLen)
        if ANSIStringMetrics.visibleLength(titleSegment) > maxTitle {
            titleSegment = ANSIStringMetrics.truncateVisible(titleSegment, to: maxTitle)
        }
        let used = leadLen + ANSIStringMetrics.visibleLength(titleSegment)
        let remaining = max(0, width - used)
        return lead + titleSegment + String(repeating: horizontal, count: remaining)
    }

    /// A content row rendered without vertical frame edges.
    ///
    /// Content is emitted as-is — no leading/trailing `│` and no trailing
    /// padding — so copied text is clean. Over-wide content is truncated to
    /// `width` as a safety net; callers are expected to size content to fit.
    ///
    /// - Parameters:
    ///   - content: The pre-formatted (possibly ANSI-styled) row content.
    ///   - width: Total width in columns.
    /// - Returns: The content, truncated to `width` visible columns if needed.
    static func contentRow(_ content: String, width: Int) -> String {
        guard width > 0 else { return content }
        let visLen = ANSIStringMetrics.visibleLength(content)
        if visLen > width {
            return ANSIStringMetrics.truncateVisible(content, to: width)
        }
        return content
    }
}
