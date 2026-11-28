import Foundation

/// What a release requires of its soak: the `soak:` block.
///
/// ```yaml
/// soak:
///   requiredFor: [major, minor]   # tag classes that cannot be pushed without a sound soak; empty by default
///   minSeconds: 5400              # at least preWarmMinutes + windowMinutes
///   maxAgeDays: 14
///   intervalSeconds: 30
///   requireDrain: true
///   sources: ["Sources/**", "Package.swift", "Package.resolved"]
///   preWarmMinutes: 30
///   windowMinutes: 60
///   slopeLimitMBPerHour: 2
///   descriptorDriftLimit: 8
///   waiver: { version: "1.2.0", reason: "docs only", date: "2026-12-01" }
/// ```
///
/// The window and limits are the calibrated rule (proposal `AReleaseNeedsItsSoak.md`, §4c and §4d); change them only
/// with a calibration behind the change.
///
/// ## Why every mistake is refused
///
/// A block that is written down and then ignored drops the requirement it states: a misspelt `requiredFor`, a tag
/// class that does not exist, a minimum too short for the window to be judged. Every other key decodes with a default,
/// so each of these would be accepted and the release would go out unchecked. They stop the run at startup instead.
public struct SoakConfig: Sendable, Equatable {

    /// The tag classes a soak can be required for.
    public static let tagClasses = ["major", "minor", "patch", "prerelease"]

    /// A dated, versioned permission to skip a soak for one release. It names the version, so it cannot persist.
    public struct Waiver: Sendable, Codable, Equatable {
        /// The version it applies to.
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

    /// The largest pre-warm period or window accepted, in minutes: a year. Past this a figure is a mistake, and an
    /// unbounded one would overflow the conversion to whole seconds.
    public static let maximumMinutes: Double = 525_600

    /// A `soak:` entry the gate will not act on.
    public enum Invalid: Error, Equatable, LocalizedError {
        /// A key the block does not have.
        case unknownKey(String)
        /// A tag class that does not exist.
        case unknownTagClass(String)
        /// A figure that must be a positive finite number is not.
        case notPositive(key: String, value: Double)
        /// A duration in minutes is larger than ``SoakConfig/maximumMinutes``.
        case outOfRange(key: String, value: Double, maximum: Double)
        /// `minSeconds` is shorter than the pre-warm period plus the window, so no soak that short could be judged.
        case minSecondsBelowWindow(minSeconds: Int, needed: Int)
        /// `sources` is empty, which would select nothing to digest.
        case noSources

        /// What is wrong, and what would be accepted.
        public var errorDescription: String? {
            switch self {
            case .unknownKey(let key):
                return "`soak.\(key)` is not a key of the soak block. A misspelt key would leave the requirement it names "
                    + "unenforced. Keys: " + SoakConfig.keys.joined(separator: ", ") + "."
            case .unknownTagClass(let name):
                return "`soak.requiredFor` names `\(name)`, which is not a tag class. Classes: "
                    + SoakConfig.tagClasses.joined(separator: ", ") + "."
            case .notPositive(let key, let value):
                return "`soak.\(key)` is \(value); it must be a finite number greater than zero."
            case .outOfRange(let key, let value, let maximum):
                return "`soak.\(key)` is \(value) minutes; no more than \(maximum) (a year) is accepted."
            case .minSecondsBelowWindow(let minSeconds, let needed):
                return "`soak.minSeconds` is \(minSeconds), but the pre-warm period and the window need \(needed): "
                    + "a soak shorter than that cannot be judged."
            case .noSources:
                return "`soak.sources` is empty, so there would be no source to tie a soak to."
            }
        }
    }

    static let keys = [
        "requiredFor", "minSeconds", "maxAgeDays", "intervalSeconds", "requireDrain", "sources",
        "preWarmMinutes", "windowMinutes", "slopeLimitMBPerHour", "descriptorDriftLimit", "waiver",
    ]

    /// Tag classes that cannot be pushed without a sound soak. Empty: nothing is required until a package opts in.
    public let requiredFor: [String]
    /// The shortest soak accepted, in seconds.
    public let minSeconds: Int
    /// The oldest a soak may be, in days.
    public let maxAgeDays: Int
    /// Seconds between samples a harness is expected to take.
    public let intervalSeconds: Int
    /// Whether the soak must end with a clean SIGTERM drain.
    public let requireDrain: Bool
    /// Globs of the committed files a soak is tied to.
    public let sources: [String]
    /// Minutes at the start of a soak that are not judged.
    public let preWarmMinutes: Double
    /// Minutes judged after the pre-warm period.
    public let windowMinutes: Double
    /// The fitted footprint slope, MB per hour, above which the soak fails.
    public let slopeLimitMBPerHour: Double
    /// How far the descriptor lower envelope may rise across the window.
    public let descriptorDriftLimit: Int
    /// A waiver for one version, or `nil`.
    public let waiver: Waiver?

    /// Nothing required; the calibrated window and limits.
    public static let `default` = SoakConfig(unchecked: [], minSeconds: 5400, maxAgeDays: 14, intervalSeconds: 30, requireDrain: true,
        sources: ["Sources/**", "Package.swift", "Package.resolved"], preWarmMinutes: 30, windowMinutes: 60,
        slopeLimitMBPerHour: 2, descriptorDriftLimit: 8, waiver: nil)

    private init(
        unchecked requiredFor: [String], minSeconds: Int, maxAgeDays: Int, intervalSeconds: Int, requireDrain: Bool,
        sources: [String], preWarmMinutes: Double, windowMinutes: Double, slopeLimitMBPerHour: Double,
        descriptorDriftLimit: Int, waiver: Waiver?
    ) {
        self.requiredFor = requiredFor
        self.minSeconds = minSeconds
        self.maxAgeDays = maxAgeDays
        self.intervalSeconds = intervalSeconds
        self.requireDrain = requireDrain
        self.sources = sources
        self.preWarmMinutes = preWarmMinutes
        self.windowMinutes = windowMinutes
        self.slopeLimitMBPerHour = slopeLimitMBPerHour
        self.descriptorDriftLimit = descriptorDriftLimit
        self.waiver = waiver
    }

    /// Creates a validated block. Anything not given takes the calibrated default.
    ///
    /// - Throws: ``Invalid``.
    public init(
        requiredFor: [String] = [], minSeconds: Int? = nil, maxAgeDays: Int = 14, intervalSeconds: Int = 30,
        requireDrain: Bool = true, sources: [String] = SoakConfig.default.sources, preWarmMinutes: Double = 30,
        windowMinutes: Double = 60, slopeLimitMBPerHour: Double = 2, descriptorDriftLimit: Int = 8, waiver: Waiver? = nil
    ) throws {
        for name in requiredFor where !Self.tagClasses.contains(name) { throw Invalid.unknownTagClass(name) }
        guard preWarmMinutes.isFinite, preWarmMinutes >= 0 else { throw Invalid.notPositive(key: "preWarmMinutes", value: preWarmMinutes) }
        for (key, value) in [("windowMinutes", windowMinutes), ("slopeLimitMBPerHour", slopeLimitMBPerHour),
                             ("maxAgeDays", Double(maxAgeDays)), ("intervalSeconds", Double(intervalSeconds))]
        where !(value.isFinite && value > 0) {
            throw Invalid.notPositive(key: key, value: value)
        }
        for (key, value) in [("preWarmMinutes", preWarmMinutes), ("windowMinutes", windowMinutes)] where value > Self.maximumMinutes {
            throw Invalid.outOfRange(key: key, value: value, maximum: Self.maximumMinutes)
        }
        guard descriptorDriftLimit >= 0 else { throw Invalid.notPositive(key: "descriptorDriftLimit", value: Double(descriptorDriftLimit)) }
        guard !sources.isEmpty else { throw Invalid.noSources }
        // The bound above keeps this finite and small; `Int(exactly:)` makes the conversion refuse rather than trap anyway.
        guard let needed = Int(exactly: ((preWarmMinutes + windowMinutes) * 60).rounded(.up)) else {
            throw Invalid.outOfRange(key: "windowMinutes", value: windowMinutes, maximum: Self.maximumMinutes)
        }
        let minimum = minSeconds ?? needed
        guard minimum >= needed else { throw Invalid.minSecondsBelowWindow(minSeconds: minimum, needed: needed) }
        self.init(
            unchecked: requiredFor, minSeconds: minimum, maxAgeDays: maxAgeDays, intervalSeconds: intervalSeconds,
            requireDrain: requireDrain, sources: sources, preWarmMinutes: preWarmMinutes, windowMinutes: windowMinutes,
            slopeLimitMBPerHour: slopeLimitMBPerHour, descriptorDriftLimit: descriptorDriftLimit, waiver: waiver)
    }
}

extension SoakConfig: Codable {

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum Key: String, CodingKey {
        case requiredFor, minSeconds, maxAgeDays, intervalSeconds, requireDrain, sources
        case preWarmMinutes, windowMinutes, slopeLimitMBPerHour, descriptorDriftLimit, waiver
    }

    /// Decodes the block, refusing a key it does not have and any value that is not usable.
    public init(from decoder: Decoder) throws {
        let present = try decoder.container(keyedBy: AnyKey.self)
        for key in present.allKeys where !Self.keys.contains(key.stringValue) { throw Invalid.unknownKey(key.stringValue) }
        let c = try decoder.container(keyedBy: Key.self)
        try self.init(
            requiredFor: try c.decodeIfPresent([String].self, forKey: .requiredFor) ?? [],
            minSeconds: try c.decodeIfPresent(Int.self, forKey: .minSeconds),
            maxAgeDays: try c.decodeIfPresent(Int.self, forKey: .maxAgeDays) ?? 14,
            intervalSeconds: try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 30,
            requireDrain: try c.decodeIfPresent(Bool.self, forKey: .requireDrain) ?? true,
            sources: try c.decodeIfPresent([String].self, forKey: .sources) ?? Self.default.sources,
            preWarmMinutes: try c.decodeIfPresent(Double.self, forKey: .preWarmMinutes) ?? 30,
            windowMinutes: try c.decodeIfPresent(Double.self, forKey: .windowMinutes) ?? 60,
            slopeLimitMBPerHour: try c.decodeIfPresent(Double.self, forKey: .slopeLimitMBPerHour) ?? 2,
            descriptorDriftLimit: try c.decodeIfPresent(Int.self, forKey: .descriptorDriftLimit) ?? 8,
            waiver: try c.decodeIfPresent(Waiver.self, forKey: .waiver))
    }

    /// Encodes every key, so a written configuration reads back as the same block.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(requiredFor, forKey: .requiredFor)
        try c.encode(minSeconds, forKey: .minSeconds)
        try c.encode(maxAgeDays, forKey: .maxAgeDays)
        try c.encode(intervalSeconds, forKey: .intervalSeconds)
        try c.encode(requireDrain, forKey: .requireDrain)
        try c.encode(sources, forKey: .sources)
        try c.encode(preWarmMinutes, forKey: .preWarmMinutes)
        try c.encode(windowMinutes, forKey: .windowMinutes)
        try c.encode(slopeLimitMBPerHour, forKey: .slopeLimitMBPerHour)
        try c.encode(descriptorDriftLimit, forKey: .descriptorDriftLimit)
        try c.encodeIfPresent(waiver, forKey: .waiver)
    }
}
