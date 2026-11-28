import ArgumentParser
import Foundation
import QualityGateCore
import QualityGateLogging
import ReleaseReadinessAuditor

/// `quality-gate soak` — the soak a release can require.
///
/// A package's own harness drives its traffic and writes samples; `soak seal` turns them into the one file the release
/// path trusts. See the proposal `AReleaseNeedsItsSoak.md` (§3, §4d).
struct Soak: AsyncParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "soak",
        abstract: "Seal a soak run so a release can require it.",
        subcommands: [Seal.self])

    /// `quality-gate soak seal --samples soak/samples.csv`
    struct Seal: AsyncParsableCommand {

        private static let logger = Logger(subsystem: "com.quality-gate", category: "SoakSeal")

        static let configuration = CommandConfiguration(
            commandName: "seal",
            abstract: "Judge a soak's samples and write .soak/result.json, tied to the committed source it ran against.",
            discussion: """
                The samples file is `t,footprintMB,descriptors` (further columns ignored), with an optional first line \
                `# architecture: x86_64`. The judged window is minutes 30 to 90 of the run, so a soak shorter than 90 minutes \
                cannot be judged. Uncommitted changes to the soaked source are refused. A soak that grew is sealed too: the \
                release then reports why it is blocked.
                """)

        @Option(name: .long, help: "The samples file the harness wrote.")
        var samples: String

        @Option(name: .long, help: "The server's exit status after the SIGTERM drain at the end; leave out if the package has no drain.")
        var drainExit: Int?

        @Option(name: .long, help: "Seconds the drain took.")
        var drainSeconds: Double = 0

        @Flag(name: .long, help: "A certificate reload happened mid-run.")
        var reloaded: Bool = false

        @Option(name: .long, help: "The package name to record; defaults to the directory's.")
        var package: String?

        @Option(name: .long, help: "Path to the configuration file.")
        var config: String = ".quality-gate.yml"

        func run() async throws {
            let root = FileManager.default.currentDirectoryPath
            // Not defaulted on failure: a soak block that will not load is the requirement not being known.
            let configuration = try Configuration.load(from: config)

            let text: String
            do {
                text = try String(contentsOfFile: samples, encoding: .utf8)
            } catch {
                Self.logger.error("samples could not be read: \(error.localizedDescription, privacy: .public)")
                print("❌ Not sealed: cannot read \(samples).")
                throw ExitCode(2)
            }
            let parsed: SoakSamplesFile.Parsed
            do {
                parsed = try SoakSamplesFile.parse(text)
            } catch {
                Self.logger.error("samples could not be parsed: \(String(describing: error), privacy: .public)")
                print("❌ Not sealed: \(samples) is not a samples file (\(error)).")
                throw ExitCode(2)
            }

            let result: SoakResult
            do {
                result = try SoakSealer.seal(
                    repository: root, samples: parsed, soak: configuration.soak,
                    package: package ?? URL(fileURLWithPath: root).lastPathComponent, host: Self.host(), toolchain: Self.toolchain(),
                    endedAt: Self.modified(samples) ?? Date(),
                    drain: drainExit.map { SoakDrain(exitCode: $0, seconds: drainSeconds) }, reloaded: reloaded)
                try SoakSealer.write(result, repository: root)
            } catch let refusal as SoakSealer.Refusal {
                Self.logger.error("soak not sealed: \(String(describing: refusal), privacy: .public)")
                print("❌ \(refusal.localizedDescription)")
                throw ExitCode(2)
            }

            let evaluation = result.sealed
            print("Sealed \(SoakResult.path): \(result.package), \(result.durationSeconds / 60) min, \(result.samples.count) samples, source \(result.sourceDigest.prefix(12)).")
            if let slope = evaluation.slopeMBPerHour, let drift = evaluation.descriptorDrift {
                let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(2)).grouping(.never)
                print("  footprint slope \(slope.formatted(style)) MB/h, descriptor drift \(drift), \(evaluation.windowSamples) samples in the judged window")
            }
            for note in evaluation.notes { print("  ℹ️  \(note)") }
            switch evaluation.verdict {
            case .pass:
                print("✅ The soak held: nothing grew past a limit.")
            case .fail(let reasons):
                for reason in reasons { print("  ❌ \(reason)") }
                print("❌ The soak grew. It is sealed so a release can say why it is blocked.")
                throw ExitCode(1)
            case .inconclusive(let reason):
                print("  ❌ \(reason)")
                print("❌ The soak could not be judged, which is not a pass. It is sealed as inconclusive.")
                throw ExitCode(1)
            }
        }

        private static func host() -> String {
            "\(ProcessInfo.processInfo.hostName) \(ProcessInfo.processInfo.operatingSystemVersionString)"
        }

        private static func toolchain() -> String {
            do {
                let out = try ProcessRunner.run("/usr/bin/env", arguments: ["swift", "--version"], timeout: 60)
                return out.stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? "unknown"
            } catch {
                logger.debug("swift --version could not run: \(error.localizedDescription, privacy: .public)")
                return "unknown"
            }
        }

        private static func modified(_ path: String) -> Date? {
            do {
                return try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
            } catch {
                logger.debug("modification date unavailable: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
