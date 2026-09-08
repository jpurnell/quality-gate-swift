import Foundation
#if canImport(os)
import os

private let logger = Logger(subsystem: "com.quality-gate.core", category: "CorpusPresenceProbe")
#endif

/// Answers whether a project has ever written telemetry to the corpus.
///
/// The single I/O boundary for `CorpusRegistrationAdvisor`. It reads
/// `telemetry/<projectID>/` and nothing else — in particular it does not read pulses, so
/// the advisory keeps working when pulse generation has stopped.
public struct CorpusPresenceProbe: Sendable {

    /// Reports whether `projectID` has emitted anything into the corpus at `corpusPath`.
    ///
    /// Distinguishing "this project has never emitted" from "the corpus could not be read"
    /// is the whole job: the two look identical from the project's side and want opposite
    /// messages. A registered project told to onboard because the corpus was offline is
    /// the false positive that makes an advisory ignorable.
    ///
    /// - Parameters:
    ///   - corpusPath: root of the corpus.
    ///   - projectID: the identifier telemetry is written under.
    /// - Returns: `.emitting` when at least one non-empty file exists for the project,
    ///   `.absent` when the corpus is readable and the project is not in it, and
    ///   `.unreadable` when the corpus itself cannot be inspected.
    public static func probe(corpusPath: String, projectID: String) -> CorpusPresence {
        let fm = FileManager.default
        let telemetryRoot = URL(fileURLWithPath: corpusPath).appendingPathComponent("telemetry")

        // The corpus, not the project, is what has to exist for `.absent` to be a truthful
        // answer. Without this check a mistyped or unsynced corpusPath would read as "this
        // project has never registered" for every project at once.
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: telemetryRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            #if canImport(os)
            logger.debug("corpus telemetry root not readable at \(telemetryRoot.path, privacy: .public)")
            #endif
            return .unreadable(reason: "no telemetry directory at \(telemetryRoot.path)")
        }

        let projectDirectory = telemetryRoot.appendingPathComponent(projectID)
        guard fm.fileExists(atPath: projectDirectory.path) else { return .absent }

        // A directory is not emission. An interrupted or misconfigured run can leave the
        // tree behind with nothing in it, and counting that as registered would hide
        // exactly the failure this is looking for.
        guard let walker = fm.enumerator(
            at: projectDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return .absent
        }

        for case let fileURL as URL in walker {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > 0 { return .emitting }
        }

        return .absent
    }
}
