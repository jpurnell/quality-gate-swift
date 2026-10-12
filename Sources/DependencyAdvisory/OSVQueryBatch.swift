import Foundation
import QualityGateCore
import QualityGateLogging

/// The live comparison could not be made.
///
/// Thrown, not swallowed: `dependency-advisory-drift` is `.external`, and the runner turns a
/// throw from an external checker into `.skipped` carrying this description — so the report
/// says the pins were not checked, and how many, rather than showing a pass.
struct AdvisoryUnavailable: Error, Sendable, Equatable, LocalizedError {
    /// Why, and what that left unchecked.
    let reason: String

    var errorDescription: String? { reason }
}

/// OSV's batched query, as a body to send and a response to read.
///
/// Verified against the live API on 2026-10-06 (`Tests/DependencyAdvisoryTests/Fixtures/osv`):
/// the ecosystem is `SwiftURL`; the package name is the repository URL with no scheme and no
/// `.git`, **matched case-sensitively**; each result carries only `id` and `modified`.
enum OSVQueryBatch {

    private static let logger = Logger(subsystem: "com.quality-gate", category: "DependencyAdvisory")

    /// The endpoint.
    static let address = "https://api.osv.dev/v1/querybatch"

    /// The deadline for one batch.
    static let timeoutSeconds: Double = 10

    /// The ceiling on one batch's response. Each hit is an id and a timestamp — about 70 bytes —
    /// so this is room for tens of thousands.
    static let maximumResponseBytes = 2 * 1024 * 1024

    /// How much is asked in one run.
    ///
    /// OSV documents no batch limit; a 218-query batch was observed to succeed. These are this
    /// gate's own ceilings, chosen so that the run is bounded whatever the lockfiles hold.
    struct Limits: Sendable, Equatable {
        /// Queries in one request.
        let queriesPerBatch: Int
        /// Requests in one run.
        let batches: Int

        /// 500 queries a request, four requests: 2,000 distinct package versions.
        static let standard = Limits(queriesPerBatch: 500, batches: 4)

        /// The most queries one run sends.
        var total: Int { max(0, queriesPerBatch) * max(0, batches) }
    }

    /// One package at one version.
    struct Query: Sendable, Hashable {
        /// The package as OSV files it: `github.com/owner/repo`.
        let name: String
        /// The version as the lockfile writes it.
        let version: String
    }

    /// What OSV said about one query.
    struct Answer: Sendable, Equatable {
        /// The advisory ids, in OSV's order.
        let ids: [String]
        /// Whether OSV paginated the answer — the ids are then some of the list, not all of it.
        let truncated: Bool
    }

    /// The request body for `queries`.
    static func body(for queries: [Query]) throws -> Data {
        struct Body: Encodable {
            struct Entry: Encodable {
                struct Package: Encodable {
                    let ecosystem: String
                    let name: String
                }
                let package: Package
                let version: String
            }
            let queries: [Entry]
        }
        let entries = queries.map {
            Body.Entry(package: .init(ecosystem: Advisory.swiftEcosystem, name: $0.name), version: $0.version)
        }
        return try JSONEncoder().encode(Body(queries: entries))
    }

    /// Reads a response that must answer `count` queries, one result each, in order.
    ///
    /// A response with a different number of results cannot be aligned with what was asked, and
    /// a page that is not JSON at all — a proxy's error page, an empty body — is not "no
    /// advisories". Both throw.
    static func parse(_ data: Data, expecting count: Int) throws -> [Answer] {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            logger.warning("OSV querybatch response was not JSON: \(error.localizedDescription, privacy: .public)")
            throw AdvisoryUnavailable(reason: "live OSV answered with something that is not JSON")
        }
        guard case .array(let results)? = root["results"] else {
            throw AdvisoryUnavailable(reason: "live OSV answered without a `results` list")
        }
        guard results.count == count else {
            throw AdvisoryUnavailable(
                reason: "live OSV answered \(results.count) results for \(count) queries")
        }
        return results.map { result in
            Answer(
                ids: (result["vulns"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue },
                truncated: result["next_page_token"]?.stringValue.map { !$0.isEmpty } ?? false)
        }
    }
}
