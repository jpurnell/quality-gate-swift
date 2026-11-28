import Foundation
import QualityGateCore

/// How a SIGTERM drain at the end of a soak went.
public struct SoakDrain: Sendable, Codable, Equatable {
    /// The server's exit status after SIGTERM; 0 is a clean drain.
    public let exitCode: Int
    /// Seconds from the signal to the exit.
    public let seconds: Double

    /// Creates a drain record.
    public init(exitCode: Int, seconds: Double) {
        self.exitCode = exitCode
        self.seconds = seconds
    }
}

/// A soak, sealed: what ran, against which source, what it measured, and what the sealer concluded.
///
/// The sealed evaluation is a record, never an input: the release path recomputes the verdict from `samples`.
public struct SoakResult: Sendable, Codable, Equatable {
    /// The schema this file was written in. A file in another schema is unreadable, not guessed at.
    public static let currentSchemaVersion = 1

    /// Where a sealed result lives, relative to the repository root. Gitignored: it belongs to a host's run.
    public static let path = ".soak/result.json"

    /// The encoder the sealer writes with: ISO-8601 dates, sorted keys, readable.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// The decoder the release path reads with, matching ``encoder()``.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The schema this file was written in.
    public let schemaVersion: Int
    /// The package soaked.
    public let package: String
    /// Hex SHA-256 over the sorted `(path, blob id)` pairs of the source soaked.
    public let sourceDigest: String
    /// When the soak began.
    public let startedAt: Date
    /// When the soak ended.
    public let endedAt: Date
    /// Seconds from start to end.
    public let durationSeconds: Int
    /// Free text: host name and OS.
    public let host: String
    /// The first line of `swift --version`.
    public let toolchain: String
    /// Seconds between samples.
    public let intervalSeconds: Int
    /// The host architecture the samples declared, or `nil` if they did not.
    public let architecture: String?
    /// The readings. At most ``SoakSamplesFile/maximumSamples``.
    public let samples: [SoakSample]
    /// The drain at the end, or `nil` if the package has none.
    public let drain: SoakDrain?
    /// Whether a certificate reload happened mid-run.
    public let reloaded: Bool
    /// What the sealer concluded. Recorded, never trusted.
    public let sealed: SoakEvaluation

    /// Creates a result.
    public init(
        schemaVersion: Int, package: String, sourceDigest: String, startedAt: Date, endedAt: Date, durationSeconds: Int,
        host: String, toolchain: String, intervalSeconds: Int, architecture: String?, samples: [SoakSample],
        drain: SoakDrain?, reloaded: Bool, sealed: SoakEvaluation
    ) {
        self.schemaVersion = schemaVersion
        self.package = package
        self.sourceDigest = sourceDigest
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.host = host
        self.toolchain = toolchain
        self.intervalSeconds = intervalSeconds
        self.architecture = architecture
        self.samples = samples
        self.drain = drain
        self.reloaded = reloaded
        self.sealed = sealed
    }
}

/// The class of a version tag, which decides whether a soak is required for it.
public enum SoakTagClass: String, Sendable, Codable, CaseIterable {
    /// `X.0.0`.
    case major
    /// `X.Y.0`, Y above 0.
    case minor
    /// `X.Y.Z`, Z above 0.
    case patch
    /// Anything with a `-suffix`: a beta or a release candidate.
    case prerelease

    /// Classifies a tag such as `v2.1.0` or `1.0.0-rc.2`, or returns `nil` if it is not a version.
    public init?(tag: String) {
        var text = tag
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard numbers.count == 3, let major = numbers[0], let minor = numbers[1], let patch = numbers[2],
              major >= 0, minor >= 0, patch >= 0
        else { return nil }
        if parts.count == 2 { self = .prerelease } else if minor == 0 && patch == 0 { self = .major } else if patch == 0 { self = .minor } else { self = .patch }
    }
}

/// A dated, versioned permission to skip a soak for a release that changed nothing the soak measures.
///
/// It names the version, so it cannot persist: the next version has no waiver. It is data in the configuration, not an
/// annotation, and it is printed on every run it is in force.
public struct SoakWaiver: Sendable, Codable, Equatable {
    /// The version it applies to, with or without a leading `v`.
    public let version: String
    /// Why no soak was needed.
    public let reason: String
    /// When it was granted.
    public let date: String

    /// Creates a waiver.
    public init(version: String, reason: String, date: String) {
        self.version = version
        self.reason = reason
        self.date = date
    }
}

/// What a release requires of its soak: the `soak:` block of the configuration.
public struct SoakRelease: Sendable, Equatable {
    /// The tag classes that cannot be pushed without a sound soak. Empty by default: nothing changes until a package opts in.
    public let requiredFor: Set<SoakTagClass>
    /// The shortest soak accepted, in seconds. At least the limits' pre-warm plus window to be judgeable.
    public let minSeconds: Int
    /// The oldest a soak may be, in days.
    public let maxAgeDays: Int
    /// Whether the soak must end with a clean SIGTERM drain.
    public let requireDrain: Bool
    /// The window and limits the verdict is recomputed with.
    public let limits: SoakLimits
    /// A waiver for one version, or `nil`.
    public let waiver: SoakWaiver?

    /// Creates a requirement.
    public init(requiredFor: Set<SoakTagClass>, minSeconds: Int, maxAgeDays: Int, requireDrain: Bool, limits: SoakLimits, waiver: SoakWaiver?) {
        self.requiredFor = requiredFor
        self.minSeconds = minSeconds
        self.maxAgeDays = maxAgeDays
        self.requireDrain = requireDrain
        self.limits = limits
        self.waiver = waiver
    }
}

/// What the soak looks like to a release: the findings that block it and the notes that do not.
public struct SoakReport: Sendable, Equatable {
    /// Findings that block a required tag.
    public let findings: [ReleasePreflight.Finding]
    /// Notes that never block: advised, waived, uncalibrated.
    public let notes: [ReleasePreflight.Finding]
}

extension SoakRelease {

    /// The requirement a validated `soak:` block states: tag-class names become ``SoakTagClass``, minutes become seconds.
    public init(config: SoakConfig) {
        self.init(
            requiredFor: Set(config.requiredFor.compactMap(SoakTagClass.init(rawValue:))),
            minSeconds: config.minSeconds, maxAgeDays: config.maxAgeDays, requireDrain: config.requireDrain,
            limits: SoakLimits(
                preWarmSeconds: config.preWarmMinutes * 60, windowSeconds: config.windowMinutes * 60,
                slopeLimitMBPerHour: config.slopeLimitMBPerHour, descriptorDriftLimit: config.descriptorDriftLimit),
            waiver: config.waiver.map { SoakWaiver(version: $0.version, reason: $0.reason, date: $0.date) })
    }
}
