import Foundation

/// Whether a project's telemetry has reached the corpus.
///
/// Presence is deliberately *emission*, not membership of the newest pulse. Pulse
/// membership is the more meaningful signal — it is what the dashboard reads — but it
/// makes this advisory depend on the pulse job still running. When that job stops, no
/// project appears in a current pulse, every project reads as absent, and the advisory
/// either nudges the whole portfolio or goes silent across it. A mechanism built to catch
/// silent failure must not contain one.
///
/// The cost is a real blind spot: a project emitting telemetry that never reaches a pulse
/// is invisible here. That gap belongs to the pulse generator, which is the only thing
/// that sees both sides.
public enum CorpusPresence: Sendable, Equatable {
    /// At least one non-empty telemetry file exists for this project.
    case emitting
    /// The corpus is readable and this project has never written to it.
    case absent
    /// The corpus could not be read at all.
    case unreadable(reason: String)
}

/// What the gate has to say about a project's corpus participation.
public enum CorpusAdvisory: Sendable, Equatable {
    /// Emitting, opted out, or the gate did not pass. Print nothing.
    case silent
    /// No `consistency.corpusPath` at all — never configured.
    case unconfigured
    /// Configured, corpus readable, this project has never emitted.
    case configuredButSilent(projectID: String)
    /// Configured, but the corpus could not be read. Never a nudge: a registered project
    /// told to onboard because the corpus was unavailable is the false positive that
    /// costs an advisory its credibility.
    case corpusUnreachable(path: String, reason: String)
}

extension CorpusAdvisory {

    /// The advisory as terminal text, or nil when there is nothing to say.
    ///
    /// Rendered as its own delimited block rather than as a diagnostic note. A clean run
    /// already prints a dozen or more notes, and a permanent, repeating note inside that
    /// stream is the original invisibility rebuilt at lower volume — the failure this
    /// advisory exists to prevent. Being outside the diagnostic list also means it cannot
    /// alter the error or warning counts, so `--strict` is unaffected by construction
    /// rather than by choosing a severity.
    public func rendered() -> String? {
        switch self {
        case .silent:
            return nil

        case .unconfigured:
            return Self.block("""
                This project passes clean and writes no telemetry to the corpus.
                Nothing is wrong. Projects are deliberately left out until they are
                worth measuring — this is only asking whether that is still true.

                  quality-gate onboard-corpus     # config and a seeding run, in one step

                Not yet:  consistency: { optOut: "<reason>" }
                """)

        case .configuredButSilent(let projectID):
            return Self.block("""
                \(projectID) is configured for the corpus but has never written to it.
                Nothing is wrong. The configuration alone does not register a project;
                the gate has to run once for the first telemetry to land.

                  quality-gate onboard-corpus     # config and a seeding run, in one step

                Not yet:  consistency: { optOut: "<reason>" }
                """)

        case .corpusUnreachable(let path, let reason):
            // Deliberately no onboarding command. The project may be perfectly
            // registered; what failed is reading the corpus, and telling someone to
            // onboard an already-onboarded project is how an advisory loses its
            // credibility on first contact.
            return Self.block("""
                The corpus at \(path) could not be read (\(reason)).
                Corpus participation could not be checked. This says nothing about
                whether this project is registered.
                """)
        }
    }

    private static func block(_ body: String) -> String {
        let rule = String(repeating: "─", count: 42)
        return "\n── Corpus \(rule.prefix(32))\n\(body)\n"
    }
}

/// Decides whether the gate should ask about corpus registration, and what to ask.
///
/// Deliberately stateless. Firing only on the *first* clean pass would require knowing
/// which pass was first, and there is nowhere honest to keep that: the corpus is the
/// natural home and the project is not in it yet, while a local marker re-fires on a fresh
/// clone and can be deleted without a decision being made. Repeating needs no state — the
/// condition is computable from configuration and the corpus on every run, so nothing is
/// remembered because nothing needs to be.
///
/// It is self-terminating in the only two ways that should end it: the project registers,
/// or it records a decision not to.
public struct CorpusRegistrationAdvisor: Sendable {

    /// Decides what, if anything, to say about this project's corpus participation.
    ///
    /// - Parameters:
    ///   - config: the project's `consistency:` settings.
    ///   - presence: the result of probing the corpus, or `nil` when no `corpusPath` is
    ///     configured and there is therefore nothing to probe.
    ///   - gatePassed: whether every checker passed. A red gate is always `.silent` — a
    ///     project being told to register while its gate is failing is being told the
    ///     wrong thing.
    /// - Returns: the advisory to render, which is `.silent` whenever the question has
    ///   been answered or is not worth asking yet.
    public static func advise(
        config: ConsistencyCheckerConfig,
        presence: CorpusPresence?,
        gatePassed: Bool
    ) -> CorpusAdvisory {
        // The notice is attached to success. Anything else is an interruption during a
        // failure the reader is already dealing with.
        guard gatePassed else { return .silent }

        // A recorded decision not to participate is an answer, and answers end the
        // question. Whitespace is not an answer: `optOut: ""` is indistinguishable from
        // someone making the message stop, and a reason that cannot be re-read and judged
        // in three months is the thing this field exists to prevent.
        if let reason = config.optOut, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .silent
        }

        guard let corpusPath = config.corpusPath, let presence else {
            return .unconfigured
        }

        switch presence {
        case .emitting:
            return .silent
        case .unreadable(let reason):
            return .corpusUnreachable(path: corpusPath, reason: reason)
        case .absent:
            return .configuredButSilent(projectID: config.projectID ?? "")
        }
    }
}
