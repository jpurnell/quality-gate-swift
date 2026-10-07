import Foundation
import QualityGateCore
#if canImport(FoundationNetworking)
// URLSession, URLRequest and URLResponse live in a separate module on Linux, where
// Foundation is split. Importing it unconditionally fails on Darwin — hence canImport.
import FoundationNetworking
#endif

/// One bounded HTTPS request to the advisory database.
///
/// The bounds are part of the request, not of the transport, so that a test can read them off
/// what was sent: a call with no deadline and no ceiling is a defect the type should not allow.
struct AdvisoryRequest: Sendable, Equatable {
    /// Where to send it. The live transport accepts OSV's two hosts and nothing else.
    let url: URL
    /// A JSON body to POST, or `nil` for a GET.
    let body: Data?
    /// How long the whole exchange may take.
    let timeoutSeconds: Double
    /// The most bytes of response that will be accepted.
    let maximumResponseBytes: Int

    /// The URL for an address this module wrote, or a thrown error if it is not one — the
    /// alternative to a force unwrap on a literal.
    static func url(_ address: String) throws -> URL {
        guard let url = URL(string: address) else { throw AdvisoryTransportError.hostNotAllowed(address) }
        return url
    }
}

/// Sends a request and returns the response body.
///
/// The seam every network call in this module goes through. The checkers and the refresh take
/// one as a value, so tests supply recorded responses and no test opens a connection.
protocol AdvisoryTransport: Sendable {
    /// The response body, or a thrown error for any failure — transport, status, or size.
    func send(_ request: AdvisoryRequest) async throws -> Data
}

/// Why a request was not answered.
enum AdvisoryTransportError: Error, Sendable, Equatable, LocalizedError {
    /// The URL is not HTTPS to one of OSV's hosts.
    case hostNotAllowed(String)
    /// The server answered with a status outside 200–299.
    case status(Int)
    /// The response exceeded the request's ceiling and was abandoned.
    case responseTooLarge(limit: Int)
    /// The response was not HTTP.
    case notHTTP

    var errorDescription: String? {
        switch self {
        case .hostNotAllowed(let url): return "\(url) is not an HTTPS URL on an allowed advisory host"
        case .status(let code): return "the advisory server answered HTTP \(code)"
        case .responseTooLarge(let limit): return "the response exceeded \(limit) bytes and was abandoned"
        case .notHTTP: return "the response was not HTTP"
        }
    }
}

/// The live transport: `URLSession`, with a host allow-list, a deadline, and a ceiling enforced
/// while the response arrives.
struct URLSessionAdvisoryTransport: AdvisoryTransport {

    /// The only hosts a request may name. The URLs are constants of this module, not input, but
    /// the host is constrained anyway so that no future caller can point the gate elsewhere.
    static let allowedHosts: Set<String> = ["api.osv.dev", "osv-vulnerabilities.storage.googleapis.com"]

    func send(_ request: AdvisoryRequest) async throws -> Data {
        guard request.url.scheme == "https", let host = request.url.host, Self.allowedHosts.contains(host) else {
            throw AdvisoryTransportError.hostNotAllowed(request.url.absoluteString)
        }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = request.timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = request.body {
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Ephemeral: no cookies, no cache, no credentials carried from anything else on the machine.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutSeconds
        configuration.timeoutIntervalForResource = request.timeoutSeconds
        let collector = BoundedResponseCollector(limit: request.maximumResponseBytes)
        let session = URLSession(configuration: configuration, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            collector.begin(continuation)
            session.dataTask(with: urlRequest).resume()
        }
    }
}

/// Accumulates a response body up to a ceiling, stopping the transfer the moment it is exceeded.
///
/// `URLSession.data(for:)` returns the whole body or nothing, so a ceiling checked afterwards is
/// a ceiling on what is kept, not on what is read. The delegate sees each chunk as it arrives.
///
/// The two delegate methods are one line each and call ``receive(_:)`` and
/// ``complete(response:error:)``, which hold the logic and are what the tests call — so the
/// bounds are tested without a socket. The status is read from the task's response at
/// completion rather than in a `didReceive response` callback, whose signature differs between
/// Darwin's Foundation and corelibs; a method that silently fails to match is never called.
// Justification: URLSession calls a delegate on its own serial queue, and every stored property is read and written only under `lock`.
final class BoundedResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    private let limit: Int
    private let lock = NSLock()
    private var body = Data()
    private var overflowed = false
    private var continuation: CheckedContinuation<Data, any Error>?

    init(limit: Int) {
        self.limit = limit
    }

    /// Records where the result goes. Called once, before the task is resumed.
    func begin(_ continuation: CheckedContinuation<Data, any Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Takes one chunk. Returns `false` when it would cross the ceiling — the transfer must then
    /// be cancelled, and nothing received so far will be returned.
    func receive(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed, body.count + data.count <= limit else {
            overflowed = true
            body = Data()
            return false
        }
        body.append(data)
        return true
    }

    /// Delivers the outcome: the ceiling if it was crossed, else the transport's error, else the
    /// status, else the body.
    func complete(response: URLResponse?, error: (any Error)?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let outcome: Result<Data, any Error>
        if overflowed {
            // The overflow is the cause; the cancellation error it produced is its symptom.
            outcome = .failure(AdvisoryTransportError.responseTooLarge(limit: limit))
        } else if let error {
            outcome = .failure(error)
        } else if let http = response as? HTTPURLResponse {
            outcome = (200...299).contains(http.statusCode)
                ? .success(body) : .failure(AdvisoryTransportError.status(http.statusCode))
        } else {
            outcome = .failure(AdvisoryTransportError.notHTTP)
        }
        lock.unlock()
        pending?.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !receive(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        complete(response: task.response, error: error)
    }
}

/// What the advisory checkers reach outside the tree for, gathered so that a test can replace
/// all of it.
struct AdvisoryEnvironment: Sendable {
    /// The snapshot shipped with the gate.
    var bundled: @Sendable () -> SnapshotCandidate?
    /// The current instant. Read only by the freshness and drift checkers.
    var now: @Sendable () -> Date
    /// The network. Used only by the drift checker.
    var transport: any AdvisoryTransport

    /// The real thing: the bundled resource, the system clock, `URLSession`.
    static let live = AdvisoryEnvironment(
        bundled: { AdvisorySnapshotStore.bundled() },
        now: { Date() },
        transport: URLSessionAdvisoryTransport())

    /// The snapshot a run uses: the newer of the bundled one and the one committed under
    /// `projectRoot`, ignoring any that does not verify. `dependency-advisory` reports those.
    func snapshot(
        projectRoot: URL, configuration: DependencyAuditorConfig
    ) -> (snapshot: AdvisorySnapshot, origin: SnapshotOrigin)? {
        let committed = AdvisorySnapshotStore.committed(
            projectRoot: projectRoot, relativePath: configuration.advisorySnapshotPath)
        var usable: [(snapshot: AdvisorySnapshot, origin: SnapshotOrigin)] = []
        for candidate in [committed, bundled()].compactMap({ $0 }) {
            if case .success(let snapshot) = candidate.decoded { usable.append((snapshot, candidate.origin)) }
        }
        return AdvisoryAudit.newer(usable)
    }
}
