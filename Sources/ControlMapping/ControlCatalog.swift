import Foundation

/// How much of a control is verifiable by static analysis.
///
/// Never `full` in practice for these frameworks — the whole design premise is
/// that a static analyzer sees only a technical slice. `partial` means a rule
/// enforces part of the control; `evidence` means the gate's own operation is
/// the evidence (e.g. change management); `none` means the control is out of
/// scope for static analysis and is reported as such, never hidden.
public enum Checkability: String, Sendable, Codable {
    case partial
    case evidence
    case none
}

/// One control within a framework catalog.
public struct Control: Sendable, Codable, Equatable {
    /// Framework-native identifier, e.g. `"164.312(e)(1)"` or `"CC6.6"`.
    public let id: String
    /// Short human-readable name.
    public let title: String
    /// Control text — verbatim for public law (HIPAA), our own paraphrase for
    /// copyrighted frameworks (SOC 2 / ISO), never their verbatim wording.
    public let text: String
    /// How much of this control static analysis can reach.
    public let checkability: Checkability

    /// Creates a control.
    public init(id: String, title: String, text: String, checkability: Checkability) {
        self.id = id
        self.title = title
        self.text = text
        self.checkability = checkability
    }
}

/// A framework's control catalog, version-stamped so drift is a dated,
/// gate-visible fact rather than silent staleness.
public struct ControlCatalog: Sendable, Codable, Equatable {
    /// Catalog identifier used in control references, e.g. `"hipaa-security-rule"`.
    public let framework: String
    /// Human version string, e.g. `"45 CFR 164 · 2013 Final Rule"`.
    public let version: String
    /// Where the catalog came from: `"ecfr"`, `"aicpa"`, `"iso"`.
    public let source: String
    /// Canonical URL/citation for the upstream text.
    public let sourceRef: String
    /// ISO date (`YYYY-MM-DD`) the upstream text was fetched.
    public let fetched: String
    /// SHA-256 of the upstream text at fetch time (drift detection anchor).
    public let contentHash: String
    /// Who last reconciled this catalog against the upstream.
    public let reviewedBy: String
    /// ISO date (`YYYY-MM-DD`) of that last review.
    public let reviewed: String
    /// Set by `standards-watch` when upstream drift is detected; forces the
    /// freshness check to fail until a human reconciles.
    public let superseded: Bool
    /// Hash of the **upstream source text** as last observed by `standards-watch`
    /// — distinct from `contentHash` (this catalog's own fingerprint). nil until
    /// first observed; drift is a change against it. Only fetchable sources
    /// (eCFR) carry one; copyrighted sources stay nil.
    public let upstreamHash: String?
    /// The controls this catalog defines.
    public let controls: [Control]

    /// Creates a catalog.
    public init(
        framework: String,
        version: String,
        source: String,
        sourceRef: String,
        fetched: String,
        contentHash: String,
        reviewedBy: String,
        reviewed: String,
        superseded: Bool = false,
        upstreamHash: String? = nil,
        controls: [Control]
    ) {
        self.framework = framework
        self.version = version
        self.source = source
        self.sourceRef = sourceRef
        self.fetched = fetched
        self.contentHash = contentHash
        self.reviewedBy = reviewedBy
        self.reviewed = reviewed
        self.superseded = superseded
        self.upstreamHash = upstreamHash
        self.controls = controls
    }

    /// The control with `id`, or nil if this catalog doesn't define it.
    public func control(id: String) -> Control? {
        controls.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey {
        case framework, version, source, sourceRef, fetched
        case contentHash, reviewedBy, reviewed, superseded, upstreamHash, controls
    }

    /// Decodes with `superseded` defaulting to false when absent.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        framework = try container.decode(String.self, forKey: .framework)
        version = try container.decode(String.self, forKey: .version)
        source = try container.decode(String.self, forKey: .source)
        sourceRef = try container.decode(String.self, forKey: .sourceRef)
        fetched = try container.decode(String.self, forKey: .fetched)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        reviewedBy = try container.decode(String.self, forKey: .reviewedBy)
        reviewed = try container.decode(String.self, forKey: .reviewed)
        superseded = try container.decodeIfPresent(Bool.self, forKey: .superseded) ?? false
        upstreamHash = try container.decodeIfPresent(String.self, forKey: .upstreamHash)
        controls = try container.decode([Control].self, forKey: .controls)
    }
}

/// A reference into a catalog — `framework/controlId`, e.g.
/// `"hipaa-security-rule/164.312(e)(1)"`. Codes to a single string in YAML/JSON.
public struct ControlRef: Sendable, Codable, Equatable {
    /// The catalog/framework identifier — the part before the first slash.
    public let framework: String
    /// The control identifier within the framework — everything after the slash.
    public let controlId: String

    /// Creates a reference from its framework and control id.
    public init(framework: String, controlId: String) {
        self.framework = framework
        self.controlId = controlId
    }

    /// Parses `"framework/controlId"`. The framework is everything before the
    /// first `/`; the control id (which may itself contain `/`) is the rest.
    public init?(_ string: String) {
        guard let slash = string.firstIndex(of: "/") else { return nil }
        let framework = String(string[string.startIndex..<slash])
        let controlId = String(string[string.index(after: slash)...])
        guard !framework.isEmpty, !controlId.isEmpty else { return nil }
        self.framework = framework
        self.controlId = controlId
    }

    /// The `framework/controlId` string form.
    public var stringValue: String { "\(framework)/\(controlId)" }

    /// Decodes from the `framework/controlId` string form.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = ControlRef(raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "control ref '\(raw)' is not 'framework/controlId'"))
        }
        self = parsed
    }

    /// Encodes to the `framework/controlId` string form.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

/// A quality-gate rule mapped to the controls it (partially) satisfies.
public struct RuleControlMapping: Sendable, Codable, Equatable {
    /// The rule/checker identifier that emits the enforcing findings.
    public let ruleId: String
    /// The controls this rule contributes to.
    public let satisfies: [ControlRef]
    /// The strength of the contribution.
    public let posture: Checkability

    /// Creates a mapping.
    public init(ruleId: String, satisfies: [ControlRef], posture: Checkability) {
        self.ruleId = ruleId
        self.satisfies = satisfies
        self.posture = posture
    }
}
