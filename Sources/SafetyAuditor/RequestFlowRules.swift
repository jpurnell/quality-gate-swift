import Foundation
import QualityGateCore
import SwiftParser
import SwiftSyntax

/// `security.ssrf`: a URL built from non-literal input **that is requested**
/// (`AURLIsNotARequest.md`).
///
/// A package-wide question answered per site, like the server-surface rules. Whether
/// `MJPEGSession(url: u)` is a request depends on what `MJPEGSession` does with its `url`, two
/// files away; whether `httpClient.fetch(url: u)` is an *unchecked* one depends on whether
/// `fetch` asks about the host first. So each file contributes ``RequestFlowFileFacts`` and the
/// join here decides:
///
/// - a **requesting parameter** is one its function hands to a sink, to another requesting
///   parameter, or stores in a requesting property — unless it asks about the host first;
/// - a **requesting property** is one some method of its type hands to a sink or to a requesting
///   parameter;
/// - a **host validator** is a parameter whose function compares its host, or hands it to one
///   that does.
///
/// - a **producer** is a function that returns a URL it built — always, or from the string one
///   of its parameters holds, in which case each caller's argument says whether it is dynamic.
///
/// A finding is a *built* URL (or one traced to the network) that is requested, passed to a
/// requesting parameter, or stored in a requesting property, with no host question before it.
/// A URL that is displayed, compared, returned, or stored where nothing requests it produces no
/// finding — nothing was requested.
///
/// Calls are matched to declarations by **name and label**, not by type: a syntactic checker
/// has no types, and matching by name is what lets a call through a protocol existential reach
/// every implementation. Two unrelated functions with one name are one function to the join.
enum RequestFlowRules {

    static let rule = "security.ssrf"

    /// One finding, before it is reported against its file.
    struct Finding {
        let file: String
        let line: Int
        let column: Int
        let severity: Diagnostic.Severity
        let message: String
        let suggestedFix: String
    }

    /// Where a requesting parameter or property ends up: the calls it goes through, and the
    /// sink at the end.
    struct Reach: Sendable {
        /// `MJPEGStream(url:)`, `dataTask(with:)` — outermost first, the sink last.
        let path: [String]
        let file: String
        let line: Int
    }

    private struct Property: Hashable {
        /// The declaring type; empty for a global.
        let type: String
        let name: String
    }

    private struct Producer: Hashable {
        let function: String
        let signature: String
    }

    /// What a function returns: a URL it always builds, or one built from a parameter's string.
    private enum Produced: Hashable {
        case always(RequestOrigin, file: String)
        case fromParameter(label: String)
    }

    /// A flow's origin as a URL that was built — its own, or the one a producer returned.
    private struct Built {
        let origin: RequestOrigin
        /// The file the construction is in — the producer's, when it always builds.
        let file: String
        /// `parsed(_:)`, when the URL came back from a function.
        let producer: String?
    }

    /// Every finding the facts support.
    static func findings(in files: [RequestFlowFileFacts]) -> [Finding] {
        var join = Join(validators: hostValidators(files.flatMap(\.validators)))
        join.solve(files)
        return join.findings(files)
    }

    /// What the package's functions do with the URLs they are given, to a fixed point.
    private struct Join {
        let validators: Set<RequestSlot>
        var parameters: [RequestSlot: Reach] = [:]
        var properties: [Property: Reach] = [:]
        /// In the order found, which is the order of the files and of the flows in them — so
        /// two runs over one package say the same thing.
        var producers: [Producer: [Produced]] = [:]

        func isChecked(_ flow: RequestFlow) -> Bool {
            flow.hostAsked || flow.checkedBy.contains(where: validators.contains)
        }

        /// Where `flow`'s use ends up, if it ends at a request.
        func reach(of flow: RequestFlow, in file: String) -> Reach? {
            switch flow.use {
            case .requested(let sink):
                return Reach(path: [sink], file: file, line: flow.line)
            case .passed(let slot):
                // A written initialiser's parameter, or a memberwise one's property.
                guard let onward = parameters[slot]
                        ?? properties[Property(type: slot.function, name: slot.label)] else { return nil }
                return Reach(path: [slot.rendered] + onward.path, file: onward.file, line: onward.line)
            case .stored(let property):
                return properties[Property(type: flow.enclosingType ?? "", name: property)]
            case .returned:
                return nil
            }
        }

        /// Every URL a flow's origin may be. One for a URL built in place; one per function of
        /// that name and labels for a result, because two producers with one name are one to the
        /// join and each of their constructions is what was requested.
        func built(_ flow: RequestFlow, in file: String) -> [Built] {
            switch flow.origin {
            case .built, .external:
                return [Built(origin: flow.origin, file: file, producer: nil)]
            case .result(let function, let signature, let arguments, let line, let column):
                let rendered = "\(function)(\(signature))"
                let known = producers[Producer(function: function, signature: signature)] ?? []
                return known.compactMap { produced in
                    switch produced {
                    case .always(let origin, let home):
                        return Built(origin: origin, file: home, producer: rendered)
                    case .fromParameter(let label):
                        // The caller's argument is the string; a literal one builds nothing dynamic.
                        guard let argument = arguments.first(where: { $0.label == label }) else { return nil }
                        return Built(
                            origin: .built(input: argument.text, line: line, column: column, source: nil),
                            file: file, producer: rendered)
                    }
                }
            case .parameter, .property:
                return []
            }
        }

        /// Each pass can only add a parameter, a property or a producer, and there are finitely
        /// many; the bound is a guard against a defect here, not a tuning knob.
        mutating func solve(_ files: [RequestFlowFileFacts]) {
            var changed = true
            var passes = 0
            while changed && passes < 64 {
                changed = false
                passes += 1
                for file in files {
                    for flow in file.flows where !isChecked(flow) && learn(from: flow, in: file.file) {
                        changed = true
                    }
                }
            }
        }

        /// Records what `flow` shows about its function, and says whether that was new.
        private mutating func learn(from flow: RequestFlow, in file: String) -> Bool {
            if case .returned(let signature) = flow.use {
                guard let function = flow.function else { return false }
                return learnProducer(Producer(function: function, signature: signature), from: flow, in: file)
            }
            switch flow.origin {
            case .parameter(let label):
                guard let function = flow.function else { return false }
                let slot = RequestSlot(function: function, label: label)
                guard parameters[slot] == nil, let found = reach(of: flow, in: file) else { return false }
                parameters[slot] = found
                return true
            case .property(let name):
                let property = Property(type: flow.enclosingType ?? "", name: name)
                guard properties[property] == nil, let found = reach(of: flow, in: file) else { return false }
                properties[property] = found
                return true
            case .built, .external, .result:
                return false
            }
        }

        private mutating func learnProducer(_ producer: Producer, from flow: RequestFlow, in file: String) -> Bool {
            var learned = false
            for made in built(flow, in: file) {
                let produced: Produced
                if case .built = flow.origin, let label = flow.inputParameter {
                    produced = .fromParameter(label: label)
                } else {
                    produced = .always(made.origin, file: made.file)
                }
                guard producers[producer]?.contains(produced) != true else { continue }
                producers[producer, default: []].append(produced)
                learned = true
            }
            return learned
        }

        func findings(_ files: [RequestFlowFileFacts]) -> [Finding] {
            var found: [Finding] = []
            // One URL sent to two sinks is one defect: the first use, by position, speaks for it.
            var reported: Set<String> = []
            for file in files {
                let ordered = file.flows.sorted { ($0.line, $0.column) < ($1.line, $1.column) }
                for flow in ordered where !isChecked(flow) {
                    guard let reach = reach(of: flow, in: file.file) else { continue }
                    let made = built(flow, in: file.file).compactMap { finding(for: flow, built: $0, reach: reach) }
                    for finding in made
                    where reported.insert("\(finding.file):\(finding.line):\(finding.column)").inserted {
                        found.append(finding)
                    }
                }
            }
            return found
        }
    }

    /// The parameters that are host validators, to a fixed point over `handsTo`.
    static func hostValidators(_ candidates: [HostValidator]) -> Set<RequestSlot> {
        var validators = Set(candidates.filter(\.asksDirectly).map(\.slot))
        var changed = true
        var passes = 0
        while changed && passes < 64 {
            changed = false
            passes += 1
            for candidate in candidates where !validators.contains(candidate.slot)
                && candidate.handsTo.contains(where: validators.contains) {
                validators.insert(candidate.slot)
                changed = true
            }
        }
        return validators
    }

    private static func finding(for flow: RequestFlow, built: Built, reach: Reach) -> Finding? {
        let what: String
        let source: RequestInputSource?
        let line: Int
        let column: Int
        switch built.origin {
        case .built(let input, let builtLine, let builtColumn, let traced):
            let from = "`\(input)`" + (traced.map { " — \($0.phrase) (\($0.evidence)) —" } ?? "")
            if let producer = built.producer {
                what = "URL built from \(from) and returned by `\(producer)`"
            } else {
                what = "URL built from \(from)"
            }
            source = traced
            (line, column) = (builtLine, builtColumn)
        case .external(let traced):
            what = "URL from \(traced.phrase) (\(traced.evidence))"
            source = traced
            (line, column) = (flow.line, flow.column)
        case .parameter, .property, .result:
            return nil
        }

        let place = reach.file == built.file
            ? "line \(reach.line)" : "\((reach.file as NSString).lastPathComponent):\(reach.line)"
        let rendered = reach.path.map { "`\($0)`" }.joined(separator: " → ")
        let how: String
        switch flow.use {
        case .requested:
            how = "is requested by \(rendered) on \(place)"
        case .passed:
            how = "is passed to \(rendered), which requests it (\(place))"
        case .stored(let property):
            how = "is stored in `\(property)`, which \(rendered) requests (\(place))"
        case .returned:
            return nil
        }
        let who = source?.isNetwork == true
            ? "a remote party chooses where this process connects"
            : "whoever supplies that string chooses where this process connects"
        return Finding(
            file: built.file, line: line, column: column,
            severity: source?.isNetwork == true ? .error : .warning,
            message: "\(what) \(how) with no check on its host — \(who). \(SecurityVisitor.citation(rule))",
            suggestedFix: "Before the request, compare the URL's host with the hosts this code means to reach — "
                + "a literal or an allow-list — or pass it through a function that does. A URL that is only "
                + "displayed, stored, returned or written out is not reported.")
    }
}

extension SafetyAuditor {

    /// What `security.ssrf` produced for one package.
    struct RequestFlowOutcome {
        var diagnostics: [Diagnostic] = []
        var overrides: [DiagnosticOverride] = []
    }

    /// Whether `security.ssrf` runs under `security`.
    static func requestFlowEnabled(_ security: SecurityAuditorConfig) -> Bool {
        security.enabledRules.isEmpty || security.enabledRules.contains(RequestFlowRules.rule)
    }

    /// Joins `facts` and reports each finding through its file's `SecurityVisitor`, so a
    /// `// SECURITY:` acknowledgement is validated and recorded as it is for every other rule.
    ///
    /// - Parameters:
    ///   - facts: What each file contributed.
    ///   - configuration: The run's configuration.
    ///   - source: A file's text, by the name it was audited under; `nil` when unreadable.
    static func runRequestFlow(
        facts: [RequestFlowFileFacts],
        configuration: Configuration,
        source: (String) -> String?
    ) -> RequestFlowOutcome {
        var outcome = RequestFlowOutcome()
        let security = configuration.security
        guard requestFlowEnabled(security) else { return outcome }
        let found = RequestFlowRules.findings(in: facts)
        for (file, findings) in Dictionary(grouping: found, by: \.file).sorted(by: { $0.key < $1.key }) {
            guard let text = source(file) else { continue }
            let tree = Parser.parse(source: text)
            let visitor = SecurityVisitor(
                fileName: file, source: text,
                converter: SourceLocationConverter(fileName: file, tree: tree),
                configuration: security)
            for finding in findings.sorted(by: { ($0.line, $0.column) < ($1.line, $1.column) }) {
                visitor.report(Diagnostic(
                    severity: finding.severity, message: finding.message, filePath: file,
                    lineNumber: finding.line, columnNumber: finding.column,
                    ruleId: RequestFlowRules.rule, suggestedFix: finding.suggestedFix))
            }
            outcome.diagnostics += visitor.diagnostics
            outcome.overrides += visitor.overrides
        }
        return outcome
    }

    /// `security.ssrf` over in-memory sources. For tests and single-source audits.
    static func auditRequestFlow(
        sources: [(path: String, source: String)],
        configuration: Configuration
    ) -> RequestFlowOutcome {
        let texts = Dictionary(sources.map { ($0.path, $0.source) }, uniquingKeysWith: { first, _ in first })
        let facts = sources.map { file -> RequestFlowFileFacts in
            let tree = Parser.parse(source: file.source)
            return RequestFlowCollector.collect(
                from: tree, converter: SourceLocationConverter(fileName: file.path, tree: tree), fileName: file.path)
        }
        return runRequestFlow(facts: facts, configuration: configuration, source: { texts[$0] })
    }
}
