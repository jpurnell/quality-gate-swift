import Foundation

/// Formats per-project work-logs into the "Recent Work" section of the narrative
/// prompt, so the LLM can attribute metric movements to the commits and notes
/// that actually produced them.
///
/// This is the consumption half of work-attributed telemetry: Phase 1 records a
/// ``WorkEvent`` stream per project; this formatter surfaces the in-window events
/// as the causal record the narrative reasons over. The attribution *rules*
/// (only link on date/SHA alignment; "coincides with", not "caused by") live in
/// the narrative system prompt — this type only presents the data.
public enum WorkLogFormatter {
    /// Builds the "Recent Work" section from per-project work-logs, including only
    /// events whose ``WorkEvent/date`` falls within `[windowStart, windowEnd]`.
    ///
    /// - Parameters:
    ///   - workLogsByProject: Work-events keyed by project identifier.
    ///   - windowStart: Inclusive start of the pulse window.
    ///   - windowEnd: Inclusive end of the pulse window.
    /// - Returns: The formatted markdown section, or `nil` when no in-window
    ///   events exist, so the caller can omit the section entirely.
    public static func recentWorkSection(
        workLogsByProject: [String: [WorkEvent]],
        windowStart: Date,
        windowEnd: Date
    ) -> String? {
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone = TimeZone(identifier: "UTC")
        dateFmt.locale = Locale(identifier: "en_US_POSIX")

        var lines: [String] = []
        for project in workLogsByProject.keys.sorted() {
            let events = (workLogsByProject[project] ?? [])
                .filter { $0.date >= windowStart && $0.date <= windowEnd }
                .sorted { $0.date < $1.date }
            for event in events {
                var line = "- \(project) — \(dateFmt.string(from: event.date))"
                if let sha = event.commitSHA, !sha.isEmpty {
                    line += " @\(String(sha.prefix(8)))"
                }
                let subjects = event.commitSubjects.filter { !$0.isEmpty }
                if !subjects.isEmpty {
                    line += ": " + subjects.joined(separator: "; ")
                }
                if event.sessionSummary != nil {
                    line += " [session summary present]"
                }
                lines.append(line)
            }
        }

        guard !lines.isEmpty else { return nil }

        let header = """
            ## Recent Work (per-project work-logs, within window)
            These are the commits and notes behind this window's changes — the causal \
            record for attribution. Per the attribution rules in the system prompt: link a \
            metric movement to an entry only when their dates (and commit SHAs) align, and \
            phrase it as "coincides with" / "following", not "caused by", unless a note \
            explicitly claims the fix.
            """
        return header + "\n" + lines.joined(separator: "\n")
    }
}
