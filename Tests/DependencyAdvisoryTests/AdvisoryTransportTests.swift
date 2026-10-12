import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import DependencyAdvisory

/// The bounds on the live transport, exercised without a connection.
///
/// `BoundedResponseCollector` is what `URLSession` hands each chunk to. Its two entry points are
/// called here directly, the way the delegate methods call them, so the ceiling and the status
/// check are tested and no socket is opened.
@Suite("advisory transport: bounds")
struct AdvisoryTransportTests {

    private func response(_ status: Int) throws -> URLResponse {
        let url = try #require(URL(string: "https://api.osv.dev/v1/querybatch"))
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil))
    }

    /// Feeds `chunks` to a collector with `limit`, then completes it.
    private func collect(
        limit: Int, chunks: [[UInt8]], status: Int = 200, error: (any Error)? = nil
    ) async throws -> (body: Data, cancelledAfter: Int?) {
        let collector = BoundedResponseCollector(limit: limit)
        let completion = try response(status)
        var cancelledAfter: Int?
        let body: Data = try await withCheckedThrowingContinuation { continuation in
            collector.begin(continuation)
            for (index, chunk) in chunks.enumerated() where cancelledAfter == nil {
                if !collector.receive(Data(chunk)) { cancelledAfter = index }
            }
            collector.complete(response: completion, error: error)
        }
        return (body, cancelledAfter)
    }

    @Test("chunks within the ceiling are returned whole, in order")
    func withinLimit() async throws {
        let result = try await collect(limit: 5, chunks: [[1, 2], [3], [4, 5]])
        #expect(result.body == Data([1, 2, 3, 4, 5]))
        #expect(result.cancelledAfter == nil)
    }

    @Test("the chunk that would cross the ceiling stops the transfer, and nothing is returned")
    func overLimit() async throws {
        let collector = BoundedResponseCollector(limit: 4)
        #expect(collector.receive(Data([1, 2, 3])))
        #expect(!collector.receive(Data([4, 5])))
        // Once over, it stays over: a later small chunk does not revive the transfer.
        #expect(!collector.receive(Data([6])))

        await #expect(throws: AdvisoryTransportError.responseTooLarge(limit: 4)) {
            _ = try await collect(limit: 4, chunks: [[1, 2, 3], [4, 5]])
        }
    }

    @Test("a status outside 200–299 is an error whatever the body says", arguments: [301, 404, 429, 500, 502])
    func badStatus(status: Int) async throws {
        await #expect(throws: AdvisoryTransportError.status(status)) {
            _ = try await collect(limit: 1_024, chunks: [Array(#"{"results":[]}"#.utf8)], status: status)
        }
    }

    @Test("a transport error is passed through as it was raised")
    func transportError() async throws {
        await #expect(throws: OfflineError.self) {
            _ = try await collect(limit: 1_024, chunks: [], error: OfflineError())
        }
    }

    /// The overflow is the cause; the cancellation error it produces is only its symptom.
    @Test("when the ceiling caused the cancellation, the ceiling is what is reported")
    func overflowOutranksCancellation() async throws {
        await #expect(throws: AdvisoryTransportError.responseTooLarge(limit: 2)) {
            _ = try await collect(limit: 2, chunks: [[1, 2, 3]], error: URLError(.cancelled))
        }
    }

    @Test("a response that is not HTTP is refused")
    func notHTTP() async throws {
        let collector = BoundedResponseCollector(limit: 16)
        let url = try #require(URL(string: "https://api.osv.dev/"))
        let plain = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        await #expect(throws: AdvisoryTransportError.notHTTP) {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                collector.begin(continuation)
                collector.complete(response: plain, error: nil)
            }
        }
    }

    @Test("the errors say what happened", arguments: [
        (AdvisoryTransportError.status(502), "the advisory server answered HTTP 502"),
        (AdvisoryTransportError.responseTooLarge(limit: 2_097_152), "the response exceeded 2097152 bytes and was abandoned"),
        (AdvisoryTransportError.notHTTP, "the response was not HTTP"),
        (AdvisoryTransportError.hostNotAllowed("http://x"), "http://x is not an HTTPS URL on an allowed advisory host"),
    ])
    func descriptions(error: AdvisoryTransportError, text: String) {
        #expect(error.localizedDescription == text)
    }

    // MARK: - The live transport's own guard

    @Test("the live transport refuses a host that is not OSV's, before any connection", arguments: [
        "https://example.com/v1/querybatch", "http://api.osv.dev/v1/querybatch", "https://api.osv.dev.evil.example/x",
        "file:///etc/passwd",
    ])
    func hostAllowList(url: String) async throws {
        let request = AdvisoryRequest(
            url: try #require(URL(string: url)), body: nil, timeoutSeconds: 1, maximumResponseBytes: 16)
        await #expect(throws: AdvisoryTransportError.hostNotAllowed(url)) {
            _ = try await URLSessionAdvisoryTransport().send(request)
        }
    }
}
