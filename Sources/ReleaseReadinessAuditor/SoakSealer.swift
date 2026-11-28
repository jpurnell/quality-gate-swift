import Foundation
import QualityGateCore

/// Seals a soak: turns a run's samples into the one file the release path trusts, `.soak/result.json`.
///
/// It records what ran, the digest of the source it ran against, and its own verdict. The verdict is a record, not an
/// input: the release path recomputes it from the samples. A soak that grew is sealed too, so a release can say why it
/// is blocked; refusing to seal it would leave only "missing".
///
/// A soak of source nobody committed cannot be tied to a release, so a tree with uncommitted changes to the soaked
/// source is refused.
public enum SoakSealer {

    /// Why a soak was not sealed.
    public enum Refusal: Error, Equatable, LocalizedError {
        /// Soaked source differs from `HEAD`; the paths are listed.
        case uncommittedChanges([String])
        /// Git could not be asked, so there is no commit to tie the soak to.
        case gitUnavailable
        /// `soak.sources` matches no committed file.
        case noSourceDigest
        /// Fewer than two samples.
        case tooFewSamples
        /// The samples are unusable for the stated reason.
        case badSamples(String)

        /// What is wrong and what to do.
        public var errorDescription: String? {
            switch self {
            case .uncommittedChanges(let paths):
                return "Not sealed: the soaked source has uncommitted changes (\(paths.joined(separator: ", "))). "
                    + "Commit them and soak that commit, so the result names source that exists."
            case .gitUnavailable:
                return "Not sealed: git could not describe this directory, so there is no commit to tie the soak to."
            case .noSourceDigest:
                return "Not sealed: `soak.sources` matches no committed file, so there is no source to tie the soak to."
            case .tooFewSamples:
                return "Not sealed: a soak needs at least two samples."
            case .badSamples(let reason):
                return "Not sealed: the samples are unusable: \(reason)."
            }
        }
    }

    /// Seals a soak.
    ///
    /// - Parameters:
    ///   - repository: The repository root; the soak is tied to `HEAD`'s source.
    ///   - samples: The readings and the architecture they declared.
    ///   - soak: The `soak:` block, for the source globs and the window and limits the verdict is judged with.
    ///   - package: The package soaked.
    ///   - host: Free text describing the host.
    ///   - toolchain: The first line of `swift --version`.
    ///   - endedAt: When the soak ended.
    ///   - drain: How the SIGTERM drain went, or `nil` if there was none.
    ///   - reloaded: Whether a certificate reload happened mid-run.
    /// - Throws: ``Refusal``.
    public static func seal(
        repository: String, samples: SoakSamplesFile.Parsed, soak: SoakConfig, package: String, host: String,
        toolchain: String, endedAt: Date, drain: SoakDrain?, reloaded: Bool
    ) throws -> SoakResult {
        guard samples.samples.count >= 2 else { throw Refusal.tooFewSamples }
        let times = samples.samples.map(\.t)
        guard let first = times.min(), let last = times.max() else { throw Refusal.tooFewSamples }
        guard first >= 0 else { throw Refusal.badSamples("a sample time is negative") }
        guard let duration = Int(exactly: last.rounded(.up)) else {
            throw Refusal.badSamples("a sample time is too large to be a duration")
        }
        let gaps = zip(times.sorted(), times.sorted().dropFirst()).map { $1 - $0 }.sorted()
        guard let interval = Int(exactly: gaps[gaps.count / 2].rounded()), interval >= 1 else {
            throw Refusal.badSamples("the sampling interval is under a second")
        }

        guard let changed = SoakSourceDigest.uncommittedChanges(repository: repository, sources: soak.sources) else {
            throw Refusal.gitUnavailable
        }
        guard changed.isEmpty else { throw Refusal.uncommittedChanges(changed) }
        guard let digest = SoakSourceDigest.digest(repository: repository, sources: soak.sources) else {
            throw Refusal.noSourceDigest
        }

        let limits = SoakRelease(config: soak).limits
        return SoakResult(
            schemaVersion: SoakResult.currentSchemaVersion, package: package, sourceDigest: digest,
            startedAt: endedAt.addingTimeInterval(-Double(duration)), endedAt: endedAt, durationSeconds: duration,
            host: host, toolchain: toolchain, intervalSeconds: interval, architecture: samples.architecture,
            samples: samples.samples, drain: drain, reloaded: reloaded,
            sealed: SoakJudgement.judge(samples: samples.samples, architecture: samples.architecture, limits: limits))
    }

    /// Writes a sealed result to `.soak/result.json` under the repository, creating the directory.
    public static func write(_ result: SoakResult, repository: String) throws {
        let folder = URL(fileURLWithPath: repository).appendingPathComponent(".soak")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SoakResult.encoder().encode(result).write(to: folder.appendingPathComponent("result.json"), options: .atomic)
    }
}
