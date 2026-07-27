// Regression fixtures for the two false-positive classes the `unreachable`
// cross-module pass raised on legitimate downstream-consumed library API.

// A public Codable enum whose cases are never referenced anywhere inside the
// package. The cases are library API — downstream consumers construct and
// switch on them, and Codable synthesis (de)serializes them. They must NOT be
// flagged as unreachable even though the index sees no in-package reference.
public enum PublicSignalKind: String, Codable, Sendable {
    case publicSignalAlpha
    case publicSignalBeta
    case publicSignalGamma
    case publicSignalDelta
}

// A public protocol whose property requirement is implemented only by a
// conformer (a stored `let` witnessing a `{ get }` requirement — the exact
// shape of VersionedCorpusArtifact.schemaVersion). The requirement decl must
// NOT be flagged.
public protocol PublicVersionedArtifact {
    var publicSchemaVersion: Int { get }
}

// Conformer supplies the witness; nothing in-package references the
// requirement declaration directly.
public struct PublicVersionedThing: PublicVersionedArtifact {
    public init() {}
    public let publicSchemaVersion: Int = 1
}
