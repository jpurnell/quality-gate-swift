import CorpusService
import Foundation
import SwiftCLIKit

/// The pending-review queue (Phase 3b §3): governed judgments awaiting a
/// distinct second identity. Approve is one keystroke; reject demands a
/// reason. Both decisions are recorded artifacts.
enum ReviewsTUIView {

    /// Renders the Reviews view.
    static func render(state: DashboardState, width: Int) -> String {
        var buf = ScreenBuffer(width: width)
        buf.appendLine(DashboardChrome.titleRule(" Pending Reviews ", width: width))
        buf.appendLine(boxRow("", width: width))

        if state.reviewRows.isEmpty {
            buf.appendLine(boxRow("  No judgments awaiting review.", width: width))
            buf.appendLine(boxRow("", width: width))
            buf.appendLine(boxRow("  Governed rules (review-policy.yml) hold their acknowledgments", width: width))
            buf.appendLine(boxRow("  here until a second identity approves or rejects them.", width: width))
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for (index, review) in state.reviewRows.enumerated() {
                let head = "  \(review.ruleId)  — submitted by \(review.submittedBy), \(formatter.string(from: review.submittedAt))"
                let body = "      \"\(review.justification)\""
                if index == state.selectedReviewIndex {
                    buf.appendLine(boxRow(ANSICodes.bold + ANSICodes.fg(.cyan) + head + ANSICodes.reset, width: width))
                    buf.appendLine(boxRow(ANSICodes.fg(.cyan) + body + ANSICodes.reset, width: width))
                } else {
                    buf.appendLine(boxRow(head, width: width))
                    buf.appendLine(boxRow(ANSICodes.dim + body + ANSICodes.reset, width: width))
                }
            }
        }
        buf.appendLine(boxRow("", width: width))
        buf.appendLine(DashboardChrome.sectionRule(width: width))

        if let prompt = state.textEntryPrompt {
            buf.appendLine(ANSICodes.bold + "  \(prompt): \(state.textEntryBuffer)█" + ANSICodes.reset)
        } else {
            buf.appendLine(ANSICodes.dim + "  \u{2191}/\u{2193} Select  a Approve  x Reject  Esc Back  q Quit" + ANSICodes.reset)
        }
        if let status = state.statusMessage {
            buf.appendLine(ANSICodes.fg(.green) + "  \(status)" + ANSICodes.reset)
        }
        return buf.raw
    }

    /// Renders one boxed content row (shared chrome helper shape).
    private static func boxRow(_ content: String, width: Int) -> String {
        DashboardChrome.contentRow(content, width: width)
    }
}
