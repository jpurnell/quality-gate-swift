import Crypto
import Foundation

/// The outcome of checking one catalog against its upstream standard.
public enum CatalogWatchState: String, Sendable, Codable {
    /// Upstream text matches the last-observed hash — no drift.
    case unchanged
    /// Upstream text changed since last observed — a human must reconcile the
    /// catalog and mapping. **The alarm.**
    case drifted
    /// First observation — the upstream hash was seeded, nothing to compare yet.
    case seeded
    /// The source is copyrighted and cannot be fetched (SOC 2 / ISO) — the
    /// review is manual; freshness is the only automatable signal.
    case manualReviewOnly
    /// A fetchable source could not be reached this run.
    case unreachable
}

/// One catalog's watch result.
public struct CatalogWatchResult: Sendable, Equatable {
    /// The catalog's framework identifier.
    public let framework: String
    /// The watch outcome.
    public let state: CatalogWatchState
    /// Human-readable detail (what to do next).
    public let detail: String

    /// Creates a watch result.
    public init(framework: String, state: CatalogWatchState, detail: String) {
        self.framework = framework
        self.state = state
        self.detail = detail
    }
}

/// Supplies the current upstream text for a catalog, or nil when the source
/// cannot be fetched (copyrighted). Injectable so the drift logic is tested
/// without touching the network.
public protocol StandardsSource: Sendable {
    /// The current upstream text for `catalog`, or nil if this source cannot
    /// fetch it (a copyrighted framework).
    func fetchUpstream(for catalog: ControlCatalog) async throws -> String?
}

/// Detects upstream drift in the control catalogs — **detect and alert only**.
/// It never edits a catalog; a human reconciles and re-stamps. Its whole job is
/// to turn silent drift into a dated, visible alert.
public enum StandardsWatch {

    /// Sources whose text can be fetched and hashed. Everything else is
    /// copyrighted and reviewed manually.
    static let fetchableSources: Set<String> = ["ecfr", "federal-register"]

    /// Classifies one catalog given the upstream text fetched for it (or nil).
    /// Pure and deterministic — the testable heart.
    public static func classify(catalog: ControlCatalog, fetched: String?) -> CatalogWatchResult {
        guard fetchableSources.contains(catalog.source) else {
            return CatalogWatchResult(
                framework: catalog.framework, state: .manualReviewOnly,
                detail: "Source '\(catalog.source)' is copyrighted and not machine-readable — re-verify manually against \(catalog.sourceRef).")
        }

        guard let fetched else {
            return CatalogWatchResult(
                framework: catalog.framework, state: .unreachable,
                detail: "Could not fetch upstream text from \(catalog.sourceRef).")
        }

        let hash = sha256Hex(fetched)
        guard let stored = catalog.upstreamHash else {
            return CatalogWatchResult(
                framework: catalog.framework, state: .seeded,
                detail: "First observation — record upstreamHash \(hash.prefix(16))… in the catalog to enable drift detection.")
        }

        if hash == stored {
            return CatalogWatchResult(
                framework: catalog.framework, state: .unchanged,
                detail: "Upstream unchanged since \(catalog.reviewed).")
        }
        return CatalogWatchResult(
            framework: catalog.framework, state: .drifted,
            detail: "UPSTREAM CHANGED at \(catalog.sourceRef) — reconcile the catalog + mapping, then re-stamp. Mark the catalog superseded until then.")
    }

    /// Runs the watch over every catalog using `source`, one classification each.
    /// A source that throws for a catalog yields `.unreachable` rather than
    /// failing the whole run.
    public static func run(
        catalogs: [ControlCatalog],
        source: StandardsSource
    ) async -> [CatalogWatchResult] {
        var results: [CatalogWatchResult] = []
        for catalog in catalogs {
            let fetched: String?
            do {
                fetched = try await source.fetchUpstream(for: catalog)
            } catch {
                results.append(CatalogWatchResult(
                    framework: catalog.framework, state: .unreachable,
                    detail: "Fetch failed for \(catalog.sourceRef): \(error.localizedDescription)"))
                continue
            }
            results.append(classify(catalog: catalog, fetched: fetched))
        }
        return results
    }

    /// Lowercase hex SHA-256 of a string (no `String(format:)` — that API is
    /// banned repo-wide).
    static func sha256Hex(_ text: String) -> String {
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        let hexDigits = Array("0123456789abcdef")
        var out = ""
        out.reserveCapacity(digest.count * 2)
        for byte in digest {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }
}
