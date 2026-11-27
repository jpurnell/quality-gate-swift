import Foundation

/// One reading of a server under soak.
public struct SoakSample: Sendable, Codable, Equatable {
    /// Seconds since the soak began.
    public let t: Double
    /// Physical footprint in megabytes: the live figure, not the peak resident size, which never falls.
    public let footprintMB: Double
    /// Open file descriptors.
    public let descriptors: Int

    /// Creates a reading.
    public init(t: Double, footprintMB: Double, descriptors: Int) {
        self.t = t
        self.footprintMB = footprintMB
        self.descriptors = descriptors
    }
}

/// Where in a soak the verdict is taken, and how much growth fails it.
///
/// ``calibrated`` is the rule measured on the 2026-11 campaign (proposal `AReleaseNeedsItsSoak.md`, §4c and §4d):
/// clean servers were still warming for 30 to 90 minutes, so the first 30 are skipped; over the next 60 the fitted
/// footprint slope of a clean server stayed under 2 MB/h in all 24 runs, while leaks of 1 MB/h and more were found.
/// 24 clean runs bound the false-positive rate at about 12% (95% confidence), on `x86_64` only.
public struct SoakLimits: Sendable, Codable, Equatable {
    /// Seconds at the start that are not judged.
    public let preWarmSeconds: Double
    /// Seconds judged after the pre-warm period.
    public let windowSeconds: Double
    /// The fitted footprint slope, MB per hour, above which the soak fails.
    public let slopeLimitMBPerHour: Double
    /// How far the descriptor count's lower envelope may rise across the window before the soak fails.
    public let descriptorDriftLimit: Int
    /// The fraction of the window's expected samples that must be present for the soak to be judged.
    public let minimumCoverage: Double

    /// Creates limits.
    public init(
        preWarmSeconds: Double, windowSeconds: Double, slopeLimitMBPerHour: Double,
        descriptorDriftLimit: Int, minimumCoverage: Double = 0.9
    ) {
        self.preWarmSeconds = preWarmSeconds
        self.windowSeconds = windowSeconds
        self.slopeLimitMBPerHour = slopeLimitMBPerHour
        self.descriptorDriftLimit = descriptorDriftLimit
        self.minimumCoverage = minimumCoverage
    }

    /// 30 minutes pre-warm, a 60-minute window, 2 MB/h, descriptor drift of 8.
    public static let calibrated = SoakLimits(
        preWarmSeconds: 1800, windowSeconds: 3600, slopeLimitMBPerHour: 2, descriptorDriftLimit: 8)

    /// The architecture the calibration was measured on.
    public static let calibratedArchitecture = "x86_64"

    /// The shortest soak that can be judged: the pre-warm period plus the window.
    public var minimumDurationSeconds: Double { preWarmSeconds + windowSeconds }
}

/// What a soak concluded.
public enum SoakVerdict: Sendable, Codable, Equatable {
    /// The window was judged and nothing grew past a limit.
    case pass
    /// The window was judged and at least one limit was exceeded; each reason is a sentence.
    case fail(reasons: [String])
    /// The soak could not be judged: too short, too sparse, or unreadable. This is not a pass.
    case inconclusive(reason: String)
}

/// A verdict with the numbers behind it.
public struct SoakEvaluation: Sendable, Codable, Equatable {
    /// The conclusion.
    public let verdict: SoakVerdict
    /// The fitted footprint slope over the window, MB per hour; `nil` if the soak was not judged.
    public let slopeMBPerHour: Double?
    /// The rise of the descriptor lower envelope across the window; `nil` if the soak was not judged.
    public let descriptorDrift: Int?
    /// How many samples fell in the window.
    public let windowSamples: Int
    /// Caveats that do not change the verdict, such as a host the rule was not calibrated on.
    public let notes: [String]
}

/// The leak verdict: a fitted slope and a descriptor lower envelope over a window after warm-up.
///
/// Only a slope and a threshold, because the calibration found a confidence interval on the slope unusable: samples
/// are autocorrelated and the naive interval fired on every clean run. A pure function of its inputs: the clock is
/// not read, so a result judged today is judged the same way next year.
public enum SoakJudgement {

    /// Judges a soak from its samples.
    ///
    /// - Parameters:
    ///   - samples: The readings, in any order.
    ///   - architecture: The host the soak ran on, or `nil` if it was not recorded. A host other than
    ///     ``SoakLimits/calibratedArchitecture`` is noted, not refused.
    ///   - limits: The window and the limits.
    public static func judge(samples: [SoakSample], architecture: String?, limits: SoakLimits) -> SoakEvaluation {
        var notes: [String] = []
        if let architecture {
            if architecture != SoakLimits.calibratedArchitecture {
                notes.append("run on \(architecture); the rule was calibrated on \(SoakLimits.calibratedArchitecture) only")
            }
        } else {
            notes.append("architecture not recorded; the rule was calibrated on \(SoakLimits.calibratedArchitecture) only")
        }
        func unjudged(_ reason: String, count: Int = 0) -> SoakEvaluation {
            SoakEvaluation(verdict: .inconclusive(reason: reason), slopeMBPerHour: nil, descriptorDrift: nil,
                           windowSamples: count, notes: notes)
        }

        guard limits.preWarmSeconds.isFinite, limits.preWarmSeconds >= 0, limits.windowSeconds.isFinite,
              limits.windowSeconds > 0, limits.slopeLimitMBPerHour.isFinite, limits.minimumCoverage.isFinite
        else { return unjudged("the limits contain a value that is not a usable number") }
        guard samples.allSatisfy({ $0.t.isFinite && $0.footprintMB.isFinite }) else {
            return unjudged("a reading is not a finite number")
        }
        let ordered = samples.sorted { $0.t < $1.t }
        guard ordered.count >= 2 else { return unjudged("fewer than two samples") }

        let start = limits.preWarmSeconds
        let end = start + limits.windowSeconds
        let window = ordered.filter { $0.t >= start && $0.t < end }

        let gaps = zip(ordered, ordered.dropFirst()).map { $1.t - $0.t }.sorted()
        let interval = gaps[gaps.count / 2]
        guard interval > 0 else { return unjudged("samples share a timestamp", count: window.count) }
        let expected = (end - start) / interval
        guard window.count >= 8, Double(window.count) >= limits.minimumCoverage * expected else {
            let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).grouping(.never)
            return unjudged(
                "the window (\((start / 60).formatted(whole)) to \((end / 60).formatted(whole)) minutes) "
                    + "holds \(window.count) of about \(expected.formatted(whole)) expected samples",
                count: window.count)
        }

        guard let slope = slopePerHour(window) else { return unjudged("the window has no spread in time", count: window.count) }
        let drift = descriptorDrift(window.map(\.descriptors))

        var reasons: [String] = []
        if slope > limits.slopeLimitMBPerHour {
            let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)).grouping(.never)
            reasons.append("footprint grew \(slope.formatted(style)) MB/h over the window, above the "
                + "\(limits.slopeLimitMBPerHour.formatted(style)) MB/h limit")
        }
        if drift > limits.descriptorDriftLimit {
            reasons.append("descriptor lower envelope rose by \(drift) across the window, above the limit of \(limits.descriptorDriftLimit)")
        }
        return SoakEvaluation(
            verdict: reasons.isEmpty ? .pass : .fail(reasons: reasons),
            slopeMBPerHour: slope, descriptorDrift: drift, windowSamples: window.count, notes: notes)
    }

    /// The least-squares slope of footprint against time, per hour.
    static func slopePerHour(_ s: [SoakSample]) -> Double? {
        let n = Double(s.count)
        guard n >= 2 else { return nil }
        let hours = s.map { $0.t / 3600 }
        let meanT = hours.reduce(0, +) / n
        let meanY = s.map(\.footprintMB).reduce(0, +) / n
        var covariance = 0.0, variance = 0.0
        for (t, sample) in zip(hours, s) {
            covariance += (t - meanT) * (sample.footprintMB - meanY)
            variance += (t - meanT) * (t - meanT)
        }
        guard variance > 0 else { return nil }
        return covariance / variance
    }

    /// The lowest count in the last quarter minus the lowest in the first. A connection open at the instant of
    /// sampling raises one reading and not the minimum, so it is not drift.
    static func descriptorDrift(_ counts: [Int]) -> Int {
        let quarter = max(counts.count / 4, 3)
        guard counts.count >= 2 * quarter, let last = counts.suffix(quarter).min(), let first = counts.prefix(quarter).min() else {
            return 0
        }
        return last - first
    }
}

/// The samples file a harness writes and `quality-gate soak seal` reads: `t,footprintMB,descriptors`, further columns
/// ignored, with an optional first line `# architecture: <arch>`.
public enum SoakSamplesFile {

    /// The most samples a file may hold. A soak of days at 30 s is under this; more is a malformed file.
    public static let maximumSamples = 10_000

    /// Why a samples file could not be read.
    public enum ParseError: Error, Equatable, Sendable {
        /// A required column is not in the header.
        case missingColumn(String)
        /// A data row (1-based, counting the header) is short or not numeric.
        case badRow(line: Int)
        /// More than ``maximumSamples`` rows.
        case tooManySamples
    }

    /// The samples read, and the architecture the file declared, if any.
    public struct Parsed: Sendable, Equatable {
        /// The readings, in file order.
        public let samples: [SoakSample]
        /// The architecture the file declared, or `nil`.
        public let architecture: String?
    }

    private static let required = ["t", "footprintMB", "descriptors"]
    private static let marker = "# architecture:"

    /// Reads a samples file.
    ///
    /// - Throws: ``ParseError``.
    public static func parse(_ text: String) throws -> Parsed {
        var lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var architecture: String?
        var offset = 0
        if let first = lines.first, first.hasPrefix(marker) {
            architecture = first.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
            offset = 1
        }
        guard let header = lines.first else { throw ParseError.missingColumn(required[0]) }
        let names = header.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var index: [Int] = []
        for column in required {
            guard let at = names.firstIndex(of: column) else { throw ParseError.missingColumn(column) }
            index.append(at)
        }
        guard lines.count - 1 <= maximumSamples else { throw ParseError.tooManySamples }
        var samples: [SoakSample] = []
        samples.reserveCapacity(lines.count - 1)
        for (n, line) in lines.dropFirst().enumerated() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard index.allSatisfy({ $0 < fields.count }),
                  let t = Double(fields[index[0]]), let f = Double(fields[index[1]]),
                  let d = Int(fields[index[2]]), t.isFinite, f.isFinite
            else { throw ParseError.badRow(line: n + 2 + offset) }
            samples.append(SoakSample(t: t, footprintMB: f, descriptors: d))
        }
        return Parsed(samples: samples, architecture: architecture)
    }
}
