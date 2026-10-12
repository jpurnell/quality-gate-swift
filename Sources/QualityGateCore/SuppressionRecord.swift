import Foundation

/// One finding that did not gate because something told the gate not to raise it.
///
/// ## Why two kinds
///
/// *Acknowledgements are not suppressions.* A marker whose reason the gate checked — at
/// least eight words, not a stock phrase, not pasted down the file — is a decision somebody
/// made and wrote down, and the gate can show it to a reviewer. A marker nobody checked is a
/// finding switched off. For as long as the two were counted together, or not counted at
/// all, a repository holding a thousand bare `// silent:` comments printed the same summary
/// as one holding none.
///
/// So every record states which it is, and why:
///
/// - ``Kind/acknowledged`` — the reason was validated, and ``validator`` names by what.
/// - ``Kind/suppressed`` — it was not, and ``rejection`` says what was missing.
///
/// ## Why this rides inside `DiagnosticOverride`
///
/// `CheckResult` and `DiagnosticOverride` are published types in `quality-gate-types`, shared
/// with the corpus and with plugins; `overrides` is the one channel a checker has that
/// survives the result cache, the reporters and telemetry. `DiagnosticOverride` has four
/// fields and no room for a kind, a form or a second line number, so the record is carried in
/// its `justification` as a bracketed prefix a person can still read:
///
/// ```
/// [suppressed; form=// silent:; marker=41; rejected=2 words, 8 required] best effort
/// ```
///
/// An override that arrives without the prefix — a plugin built against the published types
/// — is not dropped and not guessed at: it is a ``Kind/suppressed`` record of form
/// ``unclassifiedForm``. Unknown must not read as validated.
public struct SuppressionRecord: Sendable, Codable, Equatable {

    /// Whether the gate validated the reason for silencing a finding.
    public enum Kind: String, Sendable, Codable, Equatable {
        /// The reason was checked; ``SuppressionRecord/validator`` names the check.
        case acknowledged
        /// The reason was not checked, was absent, or failed the check.
        case suppressed
    }

    /// Where the silencing was written.
    public enum Source: String, Sendable, Codable, Equatable {
        /// A comment in the source, beside the finding.
        case marker
        /// An entry in `.quality-gate.yml`.
        case configuration
        /// Not stated — an override recorded without an envelope.
        case unclassified
    }

    /// The validator applied to forms that carry no validation of their own.
    ///
    /// The rules are ``JustificationValidator``'s: at least eight words, not on the low-effort
    /// denylist, and — judged when records are gathered per file, see ``SuppressionLedger`` —
    /// not the same sentence as another marker in the same file.
    public static let reasonQualityValidator = "reason-quality"

    /// The validator named by a form whose checker enforces ``JustificationValidator``
    /// itself: a reason that fails leaves the finding standing, so every record of such a
    /// form is an acknowledgement.
    public static let enforcedValidator = "justification-validator"

    /// The form of an override recorded without saying what it was.
    public static let unclassifiedForm = "unclassified"

    /// Whether the reason was validated.
    public let kind: Kind
    /// Whether the silencing is a comment or a configuration entry.
    public let source: Source
    /// The marker or configuration key that did the silencing, e.g. `// silent:` or
    /// `config overrides: off`.
    public let form: String
    /// What validated the reason. `nil` exactly when ``kind`` is ``Kind/suppressed``.
    public let validator: String?
    /// Why the reason did not validate. `nil` exactly when ``kind`` is ``Kind/acknowledged``.
    public let rejection: String?
    /// The rule whose finding was silenced.
    public let ruleId: String
    /// The file of the silenced finding.
    public let filePath: String?
    /// The 1-based line of the silenced finding.
    public let lineNumber: Int?
    /// The 1-based line of the marker, when the silencing was an inline comment.
    public let markerLine: Int?
    /// The reason as written, without the marker.
    public let reason: String
    /// How many findings this record accounts for. One for an inline marker.
    public let hidden: Int
    /// Whether this record is written to the judgement corpus as an override.
    ///
    /// `false` for every form that began recording when recording became complete. The corpus
    /// turns each override it receives into a calibration record and deducts from a
    /// repository's consistency score for a rule carrying two or more — so forwarding a
    /// thousand newly visible markers on one deploy would move scores and fill review queues
    /// for a change in *reporting*, not in the code. That is a decision about the corpus and
    /// is left to be made there; until it is, what the corpus receives is what it received
    /// before, and the reports here are complete.
    public let forwardedToCorpus: Bool

    /// Creates a record.
    public init(
        kind: Kind, source: Source = .marker, form: String, validator: String?, rejection: String?,
        ruleId: String, filePath: String?, lineNumber: Int?, markerLine: Int?, reason: String,
        hidden: Int = 1, forwardedToCorpus: Bool = true
    ) {
        self.kind = kind
        self.source = source
        self.form = form
        self.validator = validator
        self.rejection = rejection
        self.ruleId = ruleId
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.markerLine = markerLine
        self.reason = reason
        self.hidden = hidden
        self.forwardedToCorpus = forwardedToCorpus
    }

    /// Reads the record an override carries.
    ///
    /// - Parameter override: An override from a ``CheckResult``.
    public init(_ override: DiagnosticOverride) {
        guard let envelope = Envelope.parse(override.justification) else {
            self.init(
                kind: .suppressed, source: .unclassified, form: Self.unclassifiedForm, validator: nil,
                rejection: "recorded without a validated reason", ruleId: override.ruleId,
                filePath: override.filePath, lineNumber: override.lineNumber, markerLine: nil,
                reason: override.justification)
            return
        }
        self.init(
            kind: envelope.kind, source: envelope.source, form: envelope.form, validator: envelope.validator,
            rejection: envelope.rejection, ruleId: override.ruleId, filePath: override.filePath,
            lineNumber: override.lineNumber, markerLine: envelope.markerLine,
            reason: envelope.reason, hidden: envelope.hidden,
            forwardedToCorpus: !envelope.reportOnly)
    }

    /// This record with its kind lowered to a suppression for the stated cause.
    ///
    /// - Parameter rejection: What was wrong with the reason.
    /// - Returns: A ``Kind/suppressed`` copy; every other field is unchanged.
    public func rejected(because rejection: String) -> SuppressionRecord {
        SuppressionRecord(
            kind: .suppressed, source: source, form: form, validator: nil, rejection: rejection,
            ruleId: ruleId, filePath: filePath, lineNumber: lineNumber, markerLine: markerLine, reason: reason,
            hidden: hidden, forwardedToCorpus: forwardedToCorpus)
    }

    /// The override that carries this record.
    public var asOverride: DiagnosticOverride {
        DiagnosticOverride(
            ruleId: ruleId,
            justification: Envelope(
                kind: kind, source: source, form: form, validator: validator, rejection: rejection,
                markerLine: markerLine, hidden: hidden, reportOnly: !forwardedToCorpus,
                reason: reason).rendered,
            filePath: filePath,
            lineNumber: lineNumber)
    }

    /// The override as the judgement corpus is sent it: the published four fields, with the
    /// marker and its reason as plain text and no envelope.
    ///
    /// The corpus classifies an override by keywords in its justification — "validated" is
    /// one of them — so the envelope, which is made of exactly such words, must not reach it.
    public var corpusOverride: DiagnosticOverride {
        let text: String
        switch source {
        case .marker: text = reason.isEmpty ? form : "\(form) \(reason)"
        case .configuration, .unclassified: text = reason.isEmpty ? form : reason
        }
        return DiagnosticOverride(
            ruleId: ruleId, justification: text, filePath: filePath, lineNumber: lineNumber)
    }
}

// MARK: - The envelope

/// The bracketed prefix that carries a ``SuppressionRecord`` inside a justification string.
///
/// `[kind; form=…; source=config; validator=…; marker=N; hidden=N; scope=report; rejected=…] reason`. Field values have
/// `]` and `;` replaced on the way in, so the first `]` always ends the prefix and a
/// configurable keyword cannot forge a field. The reason follows the prefix verbatim and may
/// contain anything.
struct Envelope: Equatable {
    let kind: SuppressionRecord.Kind
    let source: SuppressionRecord.Source
    let form: String
    let validator: String?
    let rejection: String?
    let markerLine: Int?
    let hidden: Int
    let reportOnly: Bool
    let reason: String

    /// A field value with the two characters the grammar reserves replaced.
    static func sanitised(_ value: String) -> String {
        value.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: ";", with: ",")
    }

    var rendered: String {
        var fields = [kind.rawValue, "form=\(Self.sanitised(form))"]
        if source == .configuration { fields.append("source=config") }
        if let validator { fields.append("validator=\(Self.sanitised(validator))") }
        if let markerLine { fields.append("marker=\(markerLine)") }
        if hidden != 1 { fields.append("hidden=\(hidden)") }
        if reportOnly { fields.append("scope=report") }
        if let rejection { fields.append("rejected=\(Self.sanitised(rejection))") }
        let prefix = "[" + fields.joined(separator: "; ") + "]"
        return reason.isEmpty ? prefix : prefix + " " + reason
    }

    /// Parses a justification, or returns `nil` when it carries no envelope.
    ///
    /// Strict about its opening — `[acknowledged; form=` or `[suppressed; form=` — so prose
    /// that merely begins with a bracket is left alone.
    static func parse(_ justification: String) -> Envelope? {
        guard justification.hasPrefix("["), let close = justification.firstIndex(of: "]") else {
            return nil
        }
        let inside = justification[justification.index(after: justification.startIndex)..<close]
        let fields = inside.components(separatedBy: "; ")
        guard let first = fields.first, let kind = SuppressionRecord.Kind(rawValue: first) else {
            return nil
        }
        var values: [String: String] = [:]
        for field in fields.dropFirst() {
            guard let equals = field.firstIndex(of: "=") else { return nil }
            values[String(field[..<equals])] = String(field[field.index(after: equals)...])
        }
        guard let form = values["form"] else { return nil }
        let rest = justification[justification.index(after: close)...]
        return Envelope(
            kind: kind,
            source: values["source"] == "config" ? .configuration : .marker,
            form: form,
            validator: values["validator"],
            rejection: values["rejected"],
            markerLine: values["marker"].flatMap(Int.init),
            hidden: values["hidden"].flatMap(Int.init) ?? 1,
            reportOnly: values["scope"] == "report",
            reason: rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest))
    }
}

// MARK: - Recording

extension DiagnosticOverride {

    /// Records a finding silenced by an inline marker.
    ///
    /// Call this at the point a checker decides *not* to raise a finding because of a comment.
    /// A marker that silences without a record is the thing this type exists to end.
    ///
    /// - Parameters:
    ///   - form: The marker as documented, e.g. `// silent:`.
    ///   - ruleId: The rule whose finding the marker silenced.
    ///   - filePath: The file holding the finding.
    ///   - findingLine: The line the finding would have been reported at.
    ///   - markerLine: The line the marker is written on.
    ///   - comment: The text carrying the marker — the whole source line is fine; everything
    ///     up to and including the marker is discarded to leave the reason.
    ///   - validatedBy: The name of the validator, when the checker enforces one itself and
    ///     has already accepted this reason. `nil` — the default — has the reason judged here
    ///     by ``JustificationValidator``.
    ///   - reportOnly: `true` for a site that did not record before recording became
    ///     complete — see ``SuppressionRecord/forwardedToCorpus``.
    /// - Returns: An override carrying a ``SuppressionRecord``.
    public static func inlineMarker(
        form: String,
        ruleId: String,
        filePath: String?,
        findingLine: Int?,
        markerLine: Int?,
        comment: String,
        validatedBy: String? = nil,
        reportOnly: Bool = false
    ) -> DiagnosticOverride {
        let reason = InlineMarker.reason(in: comment, after: form)
        let kind: SuppressionRecord.Kind
        let validator: String?
        let rejection: String?
        if let validatedBy {
            (kind, validator, rejection) = (.acknowledged, validatedBy, nil)
        } else if let failure = InlineMarker.rejection(of: reason) {
            (kind, validator, rejection) = (.suppressed, nil, failure)
        } else {
            (kind, validator, rejection) = (.acknowledged, SuppressionRecord.reasonQualityValidator, nil)
        }
        return SuppressionRecord(
            kind: kind, form: form, validator: validator, rejection: rejection, ruleId: ruleId,
            filePath: filePath, lineNumber: findingLine, markerLine: markerLine, reason: reason,
            forwardedToCorpus: !reportOnly
        ).asOverride
    }

    /// Records a finding silenced or downgraded by configuration.
    ///
    /// - Parameters:
    ///   - form: The configuration key, e.g. `config overrides: off`.
    ///   - ruleId: The rule whose finding was silenced or downgraded.
    ///   - filePath: The file holding the finding, when it has one.
    ///   - findingLine: The finding's line, when it has one.
    ///   - entry: The configuration entry responsible, as a person would look for it.
    ///   - validatedBy: The validator that accepted the entry's reason, for the few
    ///     configuration forms that require one. `nil` records a suppression.
    ///   - reportOnly: `true` for a site that did not record before recording became
    ///     complete — see ``SuppressionRecord/forwardedToCorpus``.
    /// - Returns: An override carrying a ``SuppressionRecord``.
    public static func configuration(
        form: String,
        ruleId: String,
        filePath: String?,
        findingLine: Int?,
        entry: String,
        validatedBy: String? = nil,
        reportOnly: Bool = false
    ) -> DiagnosticOverride {
        SuppressionRecord(
            kind: validatedBy == nil ? .suppressed : .acknowledged,
            source: .configuration,
            form: form,
            validator: validatedBy,
            rejection: validatedBy == nil ? "configuration carries no validated reason" : nil,
            ruleId: ruleId, filePath: filePath, lineNumber: findingLine, markerLine: nil,
            reason: entry, forwardedToCorpus: !reportOnly
        ).asOverride
    }
}

extension DiagnosticOverride {

    /// Re-records an override that arrived without an envelope, when its marker can be named.
    ///
    /// Some rules run from libraries built against the published types — `VigilKit`'s
    /// cancellation and wall-clock scans are two — and return a plain override whose
    /// justification is the marker, or the line it was written on. The checker that composes
    /// such a rule knows which markers it honours, so it says so here rather than leaving
    /// the record as ``SuppressionRecord/unclassifiedForm``.
    ///
    /// - Parameter forms: The markers the rule honours, most specific first.
    /// - Returns: A typed record when the justification carries one of `forms`; the override
    ///   unchanged when it carries none, or already has an envelope.
    public func classified(among forms: [String]) -> DiagnosticOverride {
        guard Envelope.parse(justification) == nil,
              let form = forms.first(where: { justification.contains($0) }) else {
            return self
        }
        return .inlineMarker(
            form: form, ruleId: ruleId, filePath: filePath, findingLine: lineNumber,
            markerLine: nil, comment: justification)
    }
}

// MARK: - Inline markers

/// Locating an inline marker and reading the reason written after it.
public enum InlineMarker {

    /// A marker found in source.
    public struct Location: Sendable, Equatable {
        /// The 1-based line the marker is on.
        public let line: Int
        /// The whole text of that line.
        public let text: String

        /// Creates a location.
        public init(line: Int, text: String) {
            self.line = line
            self.text = text
        }
    }

    /// Finds `form` on a finding's own line or on the line directly above it.
    ///
    /// The own line is preferred: a trailing comment is about the code it trails, and a marker
    /// above may have been written for the line above.
    ///
    /// - Parameters:
    ///   - form: The marker text to look for.
    ///   - line: The 1-based line of the finding.
    ///   - lines: The file's lines.
    /// - Returns: Where the marker is, or `nil` when neither line carries it.
    public static func find(_ form: String, nearLine line: Int, in lines: [String]) -> Location? {
        for candidate in [line, line - 1] where candidate >= 1 && candidate <= lines.count {
            let text = lines[candidate - 1]
            if text.contains(form) { return Location(line: candidate, text: text) }
        }
        return nil
    }

    /// The reason written after a marker, without the punctuation that joins the two.
    ///
    /// - Parameters:
    ///   - comment: Text containing the marker; the whole source line is fine.
    ///   - form: The marker.
    /// - Returns: What follows the marker, trimmed of whitespace and of a leading dash or colon.
    public static func reason(in comment: String, after form: String) -> String {
        let tail: Substring
        if let range = comment.range(of: form) {
            tail = comment[range.upperBound...]
        } else {
            tail = Substring(comment)
        }
        // Leading only: a reason may legitimately end in a dash or a colon, and may not begin
        // with the punctuation that merely joined it to its marker.
        let joiners: Set<Character> = [" ", "\t", "—", "–", "-", ":"]
        return String(tail.drop(while: { joiners.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Why a reason does not validate, or `nil` when it does.
    ///
    /// - Parameter reason: The reason, without its marker.
    /// - Returns: A short statement of what is wrong, suitable for a report.
    public static func rejection(of reason: String) -> String? {
        guard !reason.isEmpty else { return "no reason given" }
        switch JustificationValidator().validate(reason, keyword: "\u{0}") {
        case .valid:
            return nil
        case .tooShort(let wordCount):
            return "\(wordCount) word\(wordCount == 1 ? "" : "s"), 8 required"
        case .generic(let matchedPhrase):
            return "'\(matchedPhrase)' is not a reason"
        case .duplicate:
            return "repeats another marker's reason in this file"
        }
    }
}
