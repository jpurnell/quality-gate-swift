import Foundation
import CorpusKit
import QualityGateCore

/// Resolves the corpus projectID for this run (Phase 0.4).
///
/// With `consistency.useRemoteIdentity` off (the default for one release),
/// this preserves the historical behavior: explicit config, else the working
/// directory basename. With it on, the full resolution chain applies —
/// explicit config → normalized git remote slug → basename fallback with a
/// logged weak-identity notice.
enum EffectiveProjectID {
    /// Returns the projectID telemetry should write under.
    static func resolve(consistency: ConsistencyCheckerConfig) -> String {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        guard consistency.useRemoteIdentity else {
            return consistency.projectID ?? cwd.lastPathComponent
        }
        return ProjectIdentity.resolve(cwd: cwd, explicitID: consistency.projectID).id
    }
}
