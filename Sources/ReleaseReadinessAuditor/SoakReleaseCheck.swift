import Foundation
import QualityGateCore
import QualityGateLogging

/// The soak check as the release path runs it: read the sealed result from the repository, take the digest of the
/// commit being tagged, and let ``ReleasePreflight/soak(result:currentDigest:tag:release:now:)`` decide.
///
/// A package that has not opted in (no `requiredFor`, no waiver) is not spoken to at all: the soak is advisory
/// machinery, and a project that never configured it must see no new output.
public enum SoakReleaseCheck {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "SoakReleaseCheck")

    private enum Loaded {
        case absent
        case unreadable
        case result(SoakResult)
    }

    /// Checks the soak for one tag.
    ///
    /// - Parameters:
    ///   - repository: The repository root.
    ///   - tag: The version being cut, such as `v2.1.0`. Its source is digested if the tag exists, else `HEAD`'s.
    ///   - soak: The validated `soak:` block.
    ///   - now: The current time, passed in.
    public static func evaluate(repository: String, tag: String, soak: SoakConfig, now: Date) -> SoakReport {
        guard !soak.requiredFor.isEmpty || soak.waiver != nil else { return SoakReport(findings: [], notes: []) }
        let release = SoakRelease(config: soak)
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if let waiver = soak.waiver, waiver.version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")) == version {
            return ReleasePreflight.soak(result: nil, currentDigest: "", tag: tag, release: release, now: now)
        }
        let required = SoakTagClass(tag: tag).map(release.requiredFor.contains) ?? false

        switch load(repository: repository) {
        case .absent:
            return ReleasePreflight.soak(result: nil, currentDigest: "", tag: tag, release: release, now: now)
        case .unreadable:
            guard required else { return ReleasePreflight.soak(result: nil, currentDigest: "", tag: tag, release: release, now: now) }
            return SoakReport(findings: [ReleasePreflight.Finding(
                ruleId: "release.soak-unreadable",
                message: "The soak result at \(SoakResult.path) could not be read as a sealed result.",
                remedy: "Seal the soak again with `quality-gate soak seal`; a result file is only ever written by it.")], notes: [])
        case .result(let result):
            let digest = SoakSourceDigest.digest(repository: repository, revision: tag, sources: soak.sources)
                ?? SoakSourceDigest.digest(repository: repository, sources: soak.sources)
            guard let digest else {
                guard required else { return ReleasePreflight.soak(result: result, currentDigest: "", tag: tag, release: release, now: now) }
                return SoakReport(findings: [ReleasePreflight.Finding(
                    ruleId: "release.soak-no-digest",
                    message: "`soak.sources` matches no committed file, so there is no source to tie the soak to.",
                    remedy: "Fix `soak.sources` in .quality-gate.yml so it names the code the soak measures.")], notes: [])
            }
            return ReleasePreflight.soak(result: result, currentDigest: digest, tag: tag, release: release, now: now)
        }
    }

    /// The diagnostics for a push: findings of every tag being published are errors, notes are notes. Branch updates and
    /// deletions are ignored, and outside a push (`pushedRefs` is `nil`) nothing is checked.
    public static func diagnostics(repository: String, pushedRefs: [PushedRef]?, soak: SoakConfig, now: Date) -> [Diagnostic] {
        guard let pushedRefs else { return [] }
        var diagnostics: [Diagnostic] = []
        for ref in pushedRefs where !ref.isDeletion {
            guard let tag = ref.tagName else { continue }
            let report = evaluate(repository: repository, tag: tag, soak: soak, now: now)
            diagnostics += report.findings.map {
                Diagnostic(severity: .error, message: "\(tag): \($0.message)", ruleId: $0.ruleId, suggestedFix: $0.remedy)
            }
            diagnostics += report.notes.map {
                Diagnostic(severity: .note, message: "\(tag): \($0.message)", ruleId: $0.ruleId, suggestedFix: $0.remedy)
            }
        }
        return diagnostics
    }

    private static func load(repository: String) -> Loaded {
        let path = (repository as NSString).appendingPathComponent(SoakResult.path)
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return .result(try SoakResult.decoder().decode(SoakResult.self, from: data))
        } catch {
            logger.warning("soak result could not be read: \(error.localizedDescription, privacy: .public)")
            return .unreadable
        }
    }
}
