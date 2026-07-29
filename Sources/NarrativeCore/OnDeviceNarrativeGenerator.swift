import Foundation

/// A single on-device generation call: instructions + prompt → text. Abstracted
/// so the map-reduce orchestration can be tested deterministically without the
/// real model, and so the framework-backed implementation can be compiled out on
/// platforms that lack Foundation Models (e.g. the x86_64 build server).
public protocol OnDeviceNarrativeGenerator: Sendable {
    /// Whether the on-device model is ready right now.
    var isAvailable: Bool { get }
    /// Produces text for one instruction/prompt pair (one map leaf or the reduce).
    func generate(instructions: String, prompt: String) async throws -> String
}

/// One project's generated narrative — the reusable leaf. The daily portfolio
/// narrative is one reduce over these; a corpus-understanding document or a
/// family rollup are additional reduce targets over the same leaves.
public struct ProjectNarrative: Sendable, Equatable {
    /// The project this narrative describes.
    public let projectID: String
    /// The generated per-project narrative text.
    public let text: String

    /// Creates a per-project narrative.
    public init(projectID: String, text: String) {
        self.projectID = projectID
        self.text = text
    }
}
