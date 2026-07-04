import Foundation
import Testing
@testable import QualityGateCore

// MARK: - Helpers

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("qg-cache-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeFile(_ content: String, in dir: URL, named name: String = UUID().uuidString) throws -> String {
    let url = dir.appendingPathComponent(name)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

// MARK: - CheckerFingerprint

@Suite("CheckerFingerprint")
struct CheckerFingerprintTests {

    @Test("Identical inputs produce an identical digest")
    func stableForIdenticalInputs() throws {
        let dir = try makeTempDir()
        let file = try writeFile("hello", in: dir)
        let inputs = CacheInputs(files: [file], salt: "s")
        let a = CheckerFingerprint.compute(checkerId: "c", inputs: inputs, gateHash: "g")
        let b = CheckerFingerprint.compute(checkerId: "c", inputs: inputs, gateHash: "g")
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test("A one-byte change in a file changes the digest")
    func contentChangeChangesDigest() throws {
        let dir = try makeTempDir()
        let file = try writeFile("hello", in: dir, named: "f.txt")
        let before = CheckerFingerprint.compute(checkerId: "c", inputs: CacheInputs(files: [file]), gateHash: "g")
        _ = try writeFile("hellp", in: dir, named: "f.txt")  // overwrite, one byte different
        let after = CheckerFingerprint.compute(checkerId: "c", inputs: CacheInputs(files: [file]), gateHash: "g")
        #expect(before != after)
    }

    @Test("File order does not affect the digest")
    func orderIndependent() throws {
        let dir = try makeTempDir()
        let f1 = try writeFile("one", in: dir)
        let f2 = try writeFile("two", in: dir)
        let a = CheckerFingerprint.compute(checkerId: "c", inputs: CacheInputs(files: [f1, f2]), gateHash: "g")
        let b = CheckerFingerprint.compute(checkerId: "c", inputs: CacheInputs(files: [f2, f1]), gateHash: "g")
        #expect(a == b)
    }

    @Test("Gate hash change invalidates the digest (new gate build)")
    func gateHashMatters() throws {
        let dir = try makeTempDir()
        let file = try writeFile("x", in: dir)
        let inputs = CacheInputs(files: [file])
        let a = CheckerFingerprint.compute(checkerId: "c", inputs: inputs, gateHash: "gate-v1")
        let b = CheckerFingerprint.compute(checkerId: "c", inputs: inputs, gateHash: "gate-v2")
        #expect(a != b)
    }

    @Test("Salt change (e.g. config) invalidates the digest")
    func saltMatters() throws {
        let dir = try makeTempDir()
        let file = try writeFile("x", in: dir)
        let a = CheckerFingerprint.compute(checkerId: "c", inputs: CacheInputs(files: [file], salt: "a"), gateHash: "g")
        let b = CheckerFingerprint.compute(checkerId: "c", inputs: CacheInputs(files: [file], salt: "b"), gateHash: "g")
        #expect(a != b)
    }

    @Test("A deleted input file changes the digest via the absent sentinel")
    func deletionChangesDigest() throws {
        let dir = try makeTempDir()
        let file = try writeFile("x", in: dir, named: "gone.txt")
        let before = CheckerFingerprint.compute(checkerId: "c", inputs: CacheInputs(files: [file]), gateHash: "g")
        try FileManager.default.removeItem(atPath: file)
        let after = CheckerFingerprint.compute(checkerId: "c", inputs: CacheInputs(files: [file]), gateHash: "g")
        #expect(before != after)
    }
}

// MARK: - ResultCache

@Suite("ResultCache")
struct ResultCacheTests {

    private func sampleResult(id: String = "safety") -> CheckResult {
        CheckResult(
            checkerId: id,
            status: .passed,
            diagnostics: [Diagnostic(severity: .warning, message: "note", ruleId: "r")],
            duration: .zero
        )
    }

    @Test("Store then load returns the same result")
    func roundTrip() throws {
        let dir = try makeTempDir()
        let cache = ResultCache(directory: dir)
        let result = sampleResult()
        cache.store(result, checkerId: "safety", fingerprint: "abc123")
        let loaded = cache.load(checkerId: "safety", fingerprint: "abc123")
        #expect(loaded?.checkerId == "safety")
        #expect(loaded?.status == .passed)
        #expect(loaded?.diagnostics.count == 1)
        #expect(loaded?.diagnostics.first?.ruleId == "r")
    }

    @Test("Load on an unknown key is a miss")
    func missOnUnknownKey() throws {
        let dir = try makeTempDir()
        let cache = ResultCache(directory: dir)
        #expect(cache.load(checkerId: "safety", fingerprint: "never-stored") == nil)
    }

    @Test("A different fingerprint does not hit a stored entry")
    func fingerprintScoped() throws {
        let dir = try makeTempDir()
        let cache = ResultCache(directory: dir)
        cache.store(sampleResult(), checkerId: "safety", fingerprint: "fp1")
        #expect(cache.load(checkerId: "safety", fingerprint: "fp2") == nil)
    }

    @Test("A corrupt entry is a miss, not a crash")
    func corruptEntryIsMiss() throws {
        let dir = try makeTempDir()
        let cache = ResultCache(directory: dir)
        // Write garbage where a valid entry would live.
        let bogus = dir.appendingPathComponent("safety-deadbeef.json")
        try "not json {{{".write(to: bogus, atomically: true, encoding: .utf8)
        #expect(cache.load(checkerId: "safety", fingerprint: "deadbeef") == nil)
    }
}
