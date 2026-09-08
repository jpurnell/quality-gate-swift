import Foundation

/// How current the corpus's newest pulse is.
public enum PulseFreshness: Sendable, Equatable {
    /// A pulse exists and is within the staleness threshold.
    case current(ageInHours: Int)
    /// A pulse exists but predates the threshold — generation has likely stopped.
    case stale(ageInHours: Int, newest: String)
    /// The corpus is readable and contains no pulse at all.
    case noPulseEver
    /// The pulse directory could not be read.
    case unreadable(reason: String)
}

extension PulseFreshness {

    /// The freshness line for the corpus block, or nil when there is nothing to say.
    ///
    /// Deliberately states a fact — "no pulse since X" — rather than the inference "the
    /// pulse job is broken". The corpus is Dropbox- and git-synced, so a stale local pulse
    /// can equally mean the machine was off or sync is behind. Saying the job is broken
    /// would be wrong often enough to make the line ignorable, and an advisory that gets
    /// ignored is worth nothing.
    public func rendered() -> String? {
        switch self {
        case .current:
            return nil
        case .noPulseEver:
            // A brand-new corpus and a badly broken one look identical here, so this
            // reports what is observable and leaves the conclusion to the reader.
            return "The corpus contains no pulse yet. Nothing downstream has data to read."
        case .unreadable:
            // Registration already reports an unreadable corpus; repeating it would put
            // two lines in the block about one fact.
            return nil
        case .stale(let ageInHours, let newest):
            let age = ageInHours >= 48 ? "\(ageInHours / 24) days" : "\(ageInHours) hours"
            return """
                No pulse since \(newest) (\(age) ago). Generation is daily, so a gap this
                long means it has not run. Everything reading the corpus is working from
                data that old — the dashboard included, which keeps displaying the last
                pulse as though it were current.

                  quality-gate generate-pulse     # generate one now
                  launchctl list | grep ijs-pulse # check the scheduled job
                """
        }
    }
}

/// Reports how old the corpus's newest pulse is.
///
/// A backstop, not the primary defence. The four historical gaps in the pulse record —
/// the longest seven days — were caused by `generate-pulse.sh` marking a *failed* run as
/// generated, which suppressed that day's remaining retries; that is fixed at the source.
/// What remains uncovered is everything else that stops pulses appearing: a machine off for
/// days, a corpus that stops syncing, a launchd job that gets unloaded. All of them produce
/// the same observable — a newest pulse that is too old — and none of them announces itself.
///
/// The generator cannot report that it did not run, so the observer has to be something
/// that runs often, independently, and already touches the corpus. Every gated project is
/// exactly that.
public struct PulseFreshnessProbe: Sendable {

    /// Age of the newest `pulse/<date>/PULSE_<date>.json` in the corpus.
    ///
    /// - Parameters:
    ///   - corpusPath: root of the corpus.
    ///   - now: injected rather than read from the clock, so callers and tests are
    ///     deterministic — required by the project's temporal-determinism rule.
    ///   - staleAfterHours: ages beyond this are `.stale`. `0` disables the check, which
    ///     always reports `.current`. Default 36 — see `pulseStaleAfterHours`.
    /// - Returns: `.noPulseEver` and `.unreadable` are deliberately distinct. A brand-new
    ///   corpus and an unreachable one look identical from the caller's side and warrant
    ///   opposite messages.
    public static func probe(
        corpusPath: String,
        now: Date,
        staleAfterHours: Int
    ) -> PulseFreshness {
        let fm = FileManager.default
        let pulseRoot = URL(fileURLWithPath: corpusPath).appendingPathComponent("pulse")

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: pulseRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .unreadable(reason: "no pulse directory at \(pulseRoot.path)")
        }

        guard let entries = try? fm.contentsOfDirectory(atPath: pulseRoot.path) else { // silent: the failure is the answer — reported as .unreadable on the next line
            return .unreadable(reason: "pulse directory at \(pulseRoot.path) could not be listed")
        }

        // Only `YYYY-MM-DD` names count. The corpus also holds ISO-week directories
        // (`2026-W26`) from an older scheme, and a lexical sort would rank those above
        // every dated name — making the newest pulse look like a week label.
        // Each entry is (directory name, the pulse file, the date parsed from the name).
        // The parsed date orders them; the file supplies the timestamp.
        let dated = entries.compactMap { name -> (String, URL, Date)? in
            guard let parsed = Self.parseDate(name) else { return nil }
            let dir = pulseRoot.appendingPathComponent(name)
            let file = dir.appendingPathComponent("PULSE_\(name).json")
            guard fm.fileExists(atPath: file.path) else { return nil }
            return (name, file, parsed)
        }

        guard let newest = dated.max(by: { $0.2 < $1.2 }) else {
            return .noPulseEver
        }

        // Age comes from when the file was written, not from the directory's date. The
        // directory name resolves to midnight, but generation actually happens on the
        // first launchd slot after the machine wakes — 08:01 in practice. Measuring from
        // midnight overstates age by that much, which is invisible at a multi-day
        // threshold and dominates at a 36-hour one.
        // An unreadable timestamp falls back to the directory's date, which over-estimates
        // age: it can only make a fresh pulse look older, never a stale one look current.
        let values = try? newest.1.resourceValues(forKeys: [.contentModificationDateKey]) // silent: falls back to the directory date, which errs toward reporting staleness
        let stamp = values?.contentModificationDate ?? newest.2
        let age = max(0, Int(now.timeIntervalSince(stamp) / 3_600))

        guard staleAfterHours > 0 else { return .current(ageInHours: age) }
        return age > staleAfterHours
            ? .stale(ageInHours: age, newest: newest.0)
            : .current(ageInHours: age)
    }

    /// Parses `YYYY-MM-DD`, rejecting anything else including ISO-week labels.
    private static func parseDate(_ name: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        // DateFormatter is lenient about trailing content, so the round trip is what
        // actually rejects "2026-W26" and "2026-08-07-old".
        guard let parsed = fmt.date(from: name), fmt.string(from: parsed) == name else {
            return nil
        }
        return parsed
    }
}
