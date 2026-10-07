import ArgumentParser
import DependencyAdvisory
import Foundation
import QualityGateLogging

/// `quality-gate advisories` — maintain the advisory snapshot `dependency-advisory` reads.
///
/// The lookup is split from the check. The check is hermetic and gates; this is the only thing
/// that reaches the network for advisories and the only thing that writes a snapshot, which is
/// why it is a subcommand and not a checker (`AnAdvisoryIsADatedFact.md` §4.7).
struct AdvisoriesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "advisories",
        abstract: "Maintain the advisory snapshot that `dependency-advisory` checks pins against.",
        subcommands: [Refresh.self]
    )

    /// `quality-gate advisories refresh` — download the OSV `SwiftURL` advisories into a snapshot.
    struct Refresh: AsyncParsableCommand {

        private static let logger = Logger(subsystem: "com.quality-gate", category: "AdvisoriesRefresh")

        static let configuration = CommandConfiguration(
            commandName: "refresh",
            abstract: "Download the OSV SwiftURL advisories and write a dated snapshot. Prints what arrived and what was withdrawn since the previous one."
        )

        @Option(name: .long, help: "Where to write the snapshot. A repository that commits its own keeps it here.")
        var output: String = ".quality-gate/advisories/swifturl.json"

        @Flag(name: .long, help: "Accept a snapshot with fewer records than the one it replaces. Advisories are withdrawn, not deleted, so a shrinking database is normally a failed download.")
        var allowShrink: Bool = false

        func run() async throws {
            let destination = URL(fileURLWithPath: output)
            let report: AdvisoryRefresh.Report
            do {
                report = try await AdvisoryRefresh.refresh(
                    previousData: Self.existing(at: destination), allowShrink: allowShrink, now: Date())
            } catch {
                // Nothing is written on any failure: a partial snapshot would be read as the
                // whole of what is known.
                print("Advisory snapshot NOT refreshed: \(error.localizedDescription)")
                print("\(output) was left as it was.")
                throw ExitCode(1)
            }

            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try report.encodedSnapshot().write(to: destination, options: .atomic)
            } catch {
                print("Advisory snapshot fetched but NOT written to \(output): \(error.localizedDescription)")
                throw ExitCode(1)
            }

            for line in report.summaryLines { print(line) }
            print("Wrote \(output).")
        }

        /// The snapshot file about to be replaced, when there is one.
        private static func existing(at url: URL) -> Data? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil } // SAFETY: read-only probe of the path the caller named
            do {
                return try Data(contentsOf: url)
            } catch {
                logger.warning("the snapshot at \(url.path, privacy: .public) could not be read and is treated as absent: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }
}
